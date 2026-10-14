# sprites-scripts

Tools and helper scripts for provisioning, connecting to, and managing Fly.io **Sprites** — including a full XFCE GUI desktop over `xrdp` (with clipboard sharing & local folder mounting), bounded keepalive timers, GitHub repo deploy keys via Connectors, and Forge agent setup.

---

## Quick Start (Remote Desktop Workspace)

```bash
# 1. Create a brand new Sprite with SSH, XFCE desktop, xrdp, Firefox, and a "clean" checkpoint
./new-workspace.sh my-box

# 2. Connect to the desktop (auto-starts proxy, mounts ~/Documents, enables clipboard, auto-cleans up on close)
./connect-desktop.sh my-box

# 3. (Optional) Keep the Sprite running in the background while disconnected (up to 8h max)
./keepalive.sh my-box 2h

# 4. (Optional) Roll the Sprite back to its initial "clean" checkpoint
./reset-workspace.sh my-box
```

---

## Scripts Overview

| Script | Runs On | Description |
| :--- | :--- | :--- |
| [`new-workspace.sh`](./new-workspace.sh) | Host | Creates a new Sprite, installs `openssh-server` with your SSH public key (`~/.ssh/id_ed25519.pub` or `$SSH_PUBKEY`), runs `setup-desktop.sh`, saves a random RDP password to `~/.config/sprites/<name>.pass`, and creates a `"clean"` checkpoint. |
| [`setup-desktop.sh`](./setup-desktop.sh) | Host | Installs XFCE (`xfce4`, `xfce4-terminal`), `xrdp` (`127.0.0.1:3389`), `fuse3` (for shared folders), and Mozilla's `.deb` `firefox` onto an existing Sprite, and registers `xrdp-sesman` and `xrdp` as supervised Sprite services. |
| [`connect-desktop.sh`](./connect-desktop.sh) | Host | Starts `sprite proxy` in the background, waits for the Sprite to wake, launches `xfreerdp` with clipboard sharing, folder mounting, and dynamic resolution, and **automatically kills the proxy** when you close the RDP window. |
| [`keepalive.sh`](./keepalive.sh) | Host | Keeps a Sprite awake when you are disconnected using the Sprite Tasks API, with a **strict 8-hour maximum cap** (`8h`) so a forgotten Sprite never bills indefinitely. |
| [`reset-workspace.sh`](./reset-workspace.sh) | Host | Restores the Sprite to the `"clean"` checkpoint created by `new-workspace.sh` and re-syncs your saved RDP password from `~/.config/sprites/<name>.pass`. |
| [`forge-sprite.sh`](./forge-sprite.sh) | Host | Installs or updates Forge's `pi-go-agent` release binary on the Sprite as a supervised service on port `7346`. |
| [`scripts/github/ssh_key.py`](./scripts/github/ssh_key.py) | Inside Sprite | Registers or removes a machine-specific GitHub deploy key on `OWNER/REPO` through the Sprites GitHub Connector gateway (no GitHub token stored on the Sprite). |

---

## Detailed Usage

### 1. Connecting to the GUI (`connect-desktop.sh`)

```bash
# Default: shares ~/Documents -> ~/thinclient_drives/Documents inside the Sprite
./connect-desktop.sh <sprite-name>

# Share a custom local directory:
./connect-desktop.sh <sprite-name> ~/Documents/my-project
```

**What's enabled automatically:**
- **Passwordless Login:** Reads `~/.config/sprites/<sprite-name>.pass` (or `$SPRITE_RDP_PASS`). If no password file exists yet for an existing Sprite, `connect-desktop.sh` automatically generates one, sets it on the Sprite via `chpasswd`, and saves it locally.
- **Bidirectional Clipboard:** Copy and paste text, images, and files between your local machine and the remote Sprite desktop (`/clipboard:direction-to:all,files-to:all`).
- **Shared Folder Mount:** Your local directory is mounted via FUSE inside the Sprite at `~/thinclient_drives/<folder-name>` and appears on the XFCE desktop and in the Thunar file manager sidebar.
- **Dynamic Resolution:** Resize the local FreeRDP window and the remote XFCE display automatically resizes to match (`+dynamic-resolution`).
- **Auto-Stop Tunnel:** Closing the FreeRDP window or pressing `Ctrl-C` stops the background `sprite proxy` process so the Sprite can go back to sleep (unless a `keepalive.sh` timer is active).

**Environment overrides:**
- `LOCAL_PORT=13390 ./connect-desktop.sh <name>` — use a different local port (default `13389`).
- `SHARE_DIR=/path/to/dir ./connect-desktop.sh <name>` — override the default shared folder.
- `SPRITE_RDP_PASS=secret ./connect-desktop.sh <name>` — pass an explicit RDP password.

---

### 2. Keeping a Sprite Running While Disconnected (`keepalive.sh`)

By default, a Sprite suspends (`warm` then `cold`) shortly after all active connections (`sprite proxy`, SSH, HTTP requests) close. Use `keepalive.sh` when you want long-running GUI apps, builds, or agents inside the Sprite to keep running after you close your RDP window:

```bash
# Keep awake for 1 hour (default)
./keepalive.sh <sprite-name>

# Keep awake for a custom duration (supports s, m, h; hard maximum is 8h)
./keepalive.sh <sprite-name> 30m
./keepalive.sh <sprite-name> 4h
./keepalive.sh <sprite-name> 8h

# Check remaining time and active Tasks API lease
./keepalive.sh <sprite-name> status

# Cancel early so the Sprite can sleep immediately when idle
./keepalive.sh <sprite-name> off
```

---

### 3. GitHub Repo Key Access (`scripts/github/ssh_key.py`)

Works inside a running Sprite when you have configured [Sprites Connectors](https://docs.sprites.dev/concepts/connectors/). The GitHub token never enters the Sprite — the connector gateway authenticates the Sprite and manages the repo deploy key (`<user>@<host>`).

**Set up read/write access to a repo (default):**
```bash
curl -s "https://raw.githubusercontent.com/peterw22/sprites-scripts/refs/heads/main/scripts/github/ssh_key.py" | python3 - OWNER/REPO
```

**Set up read-only access to a repo:**
```bash
curl -s "https://raw.githubusercontent.com/peterw22/sprites-scripts/refs/heads/main/scripts/github/ssh_key.py" \
  | READ_ONLY=true python3 - OWNER/REPO
```

**Remove access to a repo (clean up deploy key):**
```bash
curl -s "https://raw.githubusercontent.com/peterw22/sprites-scripts/refs/heads/main/scripts/github/ssh_key.py" | python3 - --remove OWNER/REPO
```

*(You can also trigger this from your host machine via `sprite exec -s <sprite-name> -- ...`.)*

---

### 4. Provisioning & Resetting Workspaces

```bash
# Create a new workspace Sprite from scratch
./new-workspace.sh <sprite-name>

# Add XFCE + xrdp to an already-existing Sprite
./setup-desktop.sh <sprite-name>

# Wipe all changes made since setup and roll back to the "clean" checkpoint
./reset-workspace.sh <sprite-name>
```

---

### 5. Installing Forge Agent (`forge-sprite.sh`)

```bash
# Install default release tag (or pass a specific tag as the 2nd argument)
./forge-sprite.sh <sprite-name>
./forge-sprite.sh <sprite-name> app-v1.0.1-rc28
```

---

## Reference Notes & Assets

- `xrdp_remote_sprites.md` / `xrdp_remote_sprites.html`: Blog post write-up detailing the architecture and Ubuntu/Sprite workarounds (`SessionSockdirGroup=xrdp`, Mozilla APT repo pinning, `sprite-env services`, and `/run/xrdp` socket setup).
- `xrdp_remote_sprites/desktop.png` & `xrdp_remote_sprites/firefox.png`: Screenshots of the XFCE session and Firefox running inside a Sprite.
