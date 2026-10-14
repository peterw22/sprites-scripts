#!/usr/bin/env bash
# Opens a `sprite proxy` tunnel in the background, waits for it to be ready,
# connects FreeRDP with clipboard + folder sharing + dynamic resolution enabled,
# and automatically kills the proxy when the RDP window closes.
#
# Usage: ./connect-desktop.sh <sprite-name> [local-shared-dir]
set -euo pipefail

name="${1:?usage: connect-desktop.sh <sprite-name> [local-shared-dir]}"
share_dir="${2:-${SHARE_DIR:-$HOME/Documents}}"
port="${LOCAL_PORT:-13389}"
pass_file="${SPRITE_PASS_FILE:-$HOME/.config/sprites/$name.pass}"

if [ ! -d "$share_dir" ]; then
  echo "Warning: shared directory '$share_dir' does not exist; creating it..." >&2
  mkdir -p "$share_dir"
fi
share_dir="$(cd "$share_dir" && pwd)"
share_name="$(basename "$share_dir")"

proxy_pid=""
cleanup() {
  if [ -n "$proxy_pid" ] && kill -0 "$proxy_pid" 2>/dev/null; then
    echo "Stopping sprite proxy (PID $proxy_pid)..."
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting sprite proxy for '$name' on 127.0.0.1:$port..."
sprite proxy -s "$name" "${port}:3389" >/dev/null 2>&1 &
proxy_pid=$!

# Wait for the local proxy port to begin listening (up to 30s for cold wake).
echo -n "Waiting for tunnel and Sprite to wake"
for _ in $(seq 1 60); do
  if ! kill -0 "$proxy_pid" 2>/dev/null; then
    echo
    echo "Error: sprite proxy exited prematurely. Is port $port already in use?" >&2
    exit 1
  fi
  if bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
    echo " ready!"
    break
  fi
  echo -n "."
  sleep 0.5
done

if [ -n "${SPRITE_RDP_PASS:-}" ]; then
  rdp_pass="$SPRITE_RDP_PASS"
elif [ -f "$pass_file" ]; then
  rdp_pass="$(<"$pass_file")"
else
  echo "No saved password found for '$name'; generating and setting one on the Sprite..."
  rdp_pass="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
  printf 'sprite:%s\n' "$rdp_pass" | sprite exec -s "$name" -- sudo chpasswd
  install -d -m700 "$(dirname "$pass_file")"
  printf '%s' "$rdp_pass" > "$pass_file"
  chmod 600 "$pass_file"
fi

rdp_args=(
  "/v:127.0.0.1:${port}"
  "/u:sprite"
  "/d:"
  "/p:${rdp_pass}"
  "/title:Sprite - ${name}"
  "/cert:ignore"
  "+dynamic-resolution"
  "/clipboard:direction-to:all,files-to:all"
  "/drive:${share_name},${share_dir}"
  "/floatbar:sticky:off,default:hidden,show:fullscreen"
  "/network:auto"
  "/gfx:avc420"
)

echo "Connecting FreeRDP..."
echo "  Shared folder: $share_dir -> ~/thinclient_drives/$share_name (on Sprite)"
xfreerdp "${rdp_args[@]}"
