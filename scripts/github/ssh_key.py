#!/usr/bin/env python3
"""Add or remove this Sprite's SSH key as a GitHub deploy key, through the
Sprites GitHub connector gateway.

The connector id is discovered automatically from the gateway list endpoint
(the connection whose provider is "github"). The GitHub token never enters 
the Sprite — the gateway authenticates the calling Sprite via Fly's request
signature and attaches the stored credential, so there is no Authorization
header here.

Usage:
    python3 ssh_key.py [owner/repo]            # add (clone + push)
    python3 ssh_key.py --remove [owner/repo]   # remove this machine's key
    (omit owner/repo and you'll be prompted)

The key's title is always "<user>@<host>", so removal only needs the repo:
it deletes whichever key on that repo belongs to this machine.

Knobs (env vars):
    GITHUB_GATEWAY   full gateway base url, skips discovery (optional override)
    GITHUB_USER      pick a specific connector when several GitHub accounts exist
    SSH_KEY          key path            (default: ~/.ssh/id_ed25519)
    READ_ONLY        "true" = clone only (default: false -> clone + push)
"""
from __future__ import annotations
 
import argparse
import json
import os
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from getpass import getuser
from pathlib import Path
 
LIST_URL = "https://api.sprites.dev/v1/gateway/list"
KEY = Path(os.environ.get("SSH_KEY", Path.home() / ".ssh" / "id_ed25519"))
READ_ONLY = os.environ.get("READ_ONLY", "false").lower() == "true"
GATEWAY: str = ""  # resolved at runtime by discover_gateway()
 
 
def _maybe_json(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text
 
 
def _request(method: str, url: str, payload: dict | None = None):
    """Low-level request against an absolute URL. Returns (status, body)."""
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Accept": "application/vnd.github+json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, _maybe_json(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, _maybe_json(e.read().decode())
    except urllib.error.URLError as e:
        sys.exit(f"Could not reach the gateway ({e.reason}). "
                 "Note: gateway calls only work from inside a running Sprite.")
 
 
def gh(method: str, path: str, payload: dict | None = None):
    """Call the GitHub REST API through the resolved gateway base url."""
    return _request(method, f"{GATEWAY}/{path}", payload)
 
 
def discover_gateway() -> str:
    """Find the GitHub connector's gateway_base_url from the list endpoint."""
    override = os.environ.get("GITHUB_GATEWAY")
    if override:
        return override.rstrip("/")
 
    status, body = _request("GET", LIST_URL)
    if status != 200 or not isinstance(body, dict):
        sys.exit(f"Could not list connectors (HTTP {status}): {body}")
 
    conns = [c for c in body.get("connections", []) if c.get("provider") == "github"]
    if not conns:
        sys.exit("No GitHub connector is set up. Add one in the Sprites dashboard, "
                 "grant this Sprite access, then re-run.")
 
    want = os.environ.get("GITHUB_USER")
    if want:
        conns = [c for c in conns
                 if want in (c.get("username"), c.get("provider_account_name"))] or conns
    if len(conns) > 1:
        names = ", ".join(c.get("username", "?") for c in conns)
        print(f"Multiple GitHub connectors ({names}); using the first. "
              "Set GITHUB_USER to choose.", file=sys.stderr)
 
    conn = conns[0]
    base = conn.get("gateway_base_url") \
        or f"https://api.sprites.dev/v1/gateway/github/{conn['id']}"
    print(f"Using GitHub connector: {conn.get('username')}")
    return base.rstrip("/")
 
 
def machine_title() -> str:
    return f"{getuser()}@{socket.gethostname()}"
 
 
def local_pub_body() -> str | None:
    """Base64 body of the local public key, or None if it isn't on disk."""
    pub_path = Path(str(KEY) + ".pub")
    return pub_path.read_text().split()[1] if pub_path.exists() else None
 
 
def list_keys(repo: str):
    status, body = gh("GET", f"repos/{repo}/keys")
    if status != 200:
        sys.exit(f"Could not list keys (HTTP {status}): {body}")
    return body if isinstance(body, list) else []
 
 
def ensure_key() -> tuple[str, str, str]:
    pub_path = Path(str(KEY) + ".pub")
    title = machine_title()
    if not pub_path.exists():
        KEY.parent.mkdir(parents=True, exist_ok=True)
        KEY.parent.chmod(0o700)
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", str(KEY),
                        "-N", "", "-C", title], check=True)
        print(f"Generated new key: {KEY}")
    else:
        print(f"Using existing key: {KEY}")
    pub = pub_path.read_text().strip()
    return title, pub, pub.split()[1]
 
 
def add(repo: str) -> None:
    title, pub, pub_body = ensure_key()
    if any(pub_body in k.get("key", "") for k in list_keys(repo)):
        print(f"This key is already registered on {repo} — nothing to do.")
    else:
        status, body = gh("POST", f"repos/{repo}/keys",
                          {"title": title, "key": pub, "read_only": READ_ONLY})
        if status == 201:
            print(f"Deploy key added to {repo} (read_only={READ_ONLY}, title={title}).")
        elif status == 403:
            sys.exit("403 — the connector lacks scope to manage deploy keys.\n"
                     "Add the scope on the connector's detail page, then re-run.\n"
                     f"{body}")
        elif status == 422:
            sys.exit("422 — GitHub rejected the key, usually 'key is already in use'.\n"
                     "A deploy key can belong to only ONE repo across all of GitHub;\n"
                     "use a separate key per repo (set SSH_KEY) if you need more.\n"
                     f"{body}")
        else:
            sys.exit(f"Unexpected response (HTTP {status}): {body}")
    trust_github()
    print(f"\ngit will use {KEY} automatically for github.com:\n"
          f"  git clone git@github.com:{repo}.git")
 
 
def remove(repo: str) -> None:
    pub_body = local_pub_body()
    keys = list_keys(repo)
    if pub_body:
        matches = [k for k in keys if pub_body in k.get("key", "")]
        who = "this key"
    else:
        # no key on disk: fall back to the title, which is NOT unique
        # (e.g. sprite@my-sprite is a common default), so warn.
        title = machine_title()
        matches = [k for k in keys if k.get("title") == title]
        who = f"title {title!r}"
        if matches:
            print(f"No local key file — matching on {who} only, which can hit "
                  "another machine's key if titles collide.", file=sys.stderr)
    if not matches:
        print(f"No deploy key matching {who} found on {repo} — nothing to remove.")
        return
    for k in matches:
        status, body = gh("DELETE", f"repos/{repo}/keys/{k['id']}")
        if status == 204:
            print(f"Removed deploy key id={k['id']} ({k.get('title')}) from {repo}.")
        else:
            print(f"Failed to remove id={k['id']} (HTTP {status}): {body}")
    print("(local key files left in place — they may be in use by other repos)")
 
 
def trust_github() -> None:
    kh = Path.home() / ".ssh" / "known_hosts"
    kh.parent.mkdir(parents=True, exist_ok=True)
    if "github.com" not in (kh.read_text() if kh.exists() else ""):
        scan = subprocess.run(["ssh-keyscan", "-t", "ed25519", "github.com"],
                              capture_output=True, text=True)
        with kh.open("a") as f:
            f.write(scan.stdout)
 
 
def main() -> None:
    global GATEWAY
    p = argparse.ArgumentParser(description="Manage this Sprite's GitHub deploy key.")
    p.add_argument("repo", nargs="?", help="owner/repo (prompted if omitted)")
    p.add_argument("--remove", action="store_true",
                   help="remove this machine's deploy key from the repo")
    args = p.parse_args()
 
    repo = (args.repo or input("Which repo? (owner/repo): ")).strip()
    if "/" not in repo:
        sys.exit(f"Expected owner/repo, got: {repo!r}")
 
    GATEWAY = discover_gateway()
    remove(repo) if args.remove else add(repo)
 
 
if __name__ == "__main__":
    main()