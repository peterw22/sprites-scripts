#!/usr/bin/env bash
# Installs Forge's pi-go-agent from a release onto a Sprite and runs it as a
# Sprite service on the URL's HTTP port, so a request to the Sprite URL wakes
# the Sprite and starts the agent. Re-run it to update to another release.
# Usage: ./forge-sprite.sh <sprite-name> [release-tag]
set -euo pipefail
name="${1:?usage: forge-sprite.sh <sprite-name> [release-tag]}"
tag="${2:-app-v1.0.1-rc28}"

sprite exec -s "$name" --env "TAG=$tag" -- bash -c '
set -e
ver="${TAG#app-v}"
bundle="Forge-$ver-linux-amd64"
tmp="$(mktemp -d)"
cd "$tmp"
base="https://github.com/peterw22/forge/releases/download/$TAG"
curl -fsSLO "$base/$bundle.tar.gz"
curl -fsSLO "$base/SHA256SUMS"
grep " $bundle.tar.gz\$" SHA256SUMS | sha256sum -c -

# Only the agent is needed. It is a static Go binary, so none of the
# desktop app GTK/Flutter libraries have to be installed.
tar xzf "$bundle.tar.gz" "$bundle/helpers/pi-go-agent"
install -D -m755 "$bundle/helpers/pi-go-agent" ~/.local/bin/pi-go-agent
cd / && rm -rf "$tmp"

install -d -m700 ~/.pi-go
[ -f ~/.pi-go/authorized-devices.json ] || echo "{\"version\":1,\"devices\":[]}" > ~/.pi-go/authorized-devices.json
chmod 600 ~/.pi-go/authorized-devices.json

# Recreate the service so an update picks up the new binary.
sprite-env services delete forge-agent >/dev/null 2>&1 || true
sprite-env services create forge-agent --cmd "$HOME/.local/bin/pi-go-agent" \
  --args "--listen,ws://127.0.0.1:7346/ws,--cwd,$HOME" --http-port 7346 --no-stream >/dev/null

~/.local/bin/pi-go-agent --print-identity'

echo
echo "Forge agent installed on $name."
sprite info -s "$name" 2>/dev/null | grep -i '^ *url' || true
echo "Forge address: wss://<the URL host above>/ws"
echo
echo "Phones and the web client cannot send Sprite auth, so the URL has to be public."
echo "Forge's device whitelist is then the only gate:"
echo "  sprite config update -s $name --url-auth public"
echo
echo "Add a device (paste Forge's \"Copy device whitelist entry\"):"
echo "  wl-paste | sprite exec -s $name -- .local/bin/pi-go-agent --authorize-device"
echo "  sprite exec -s $name -- sprite-env services restart forge-agent"
