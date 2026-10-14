#!/usr/bin/env bash
# Spins up a desktop Sprite (sshd + your key + XFCE/xrdp/Firefox), sets a random
# RDP password, and saves a "clean" checkpoint you can reset to later.
# Usage: ./new-workspace.sh <name>
set -euo pipefail
name="${1:?usage: new-workspace.sh <name>}"
key="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
here="$(cd "$(dirname "$0")" && pwd)"

sprite create --skip-console "$name"

sprite exec -s "$name" --file "$key:/tmp/k.pub" -- bash -c '
set -e
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null
install -d -m700 ~/.ssh
cat /tmp/k.pub >> ~/.ssh/authorized_keys
sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
rm /tmp/k.pub'

"$here/setup-desktop.sh" "$name"

pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
printf 'sprite:%s\n' "$pw" | sprite exec -s "$name" -- sudo chpasswd

install -d -m700 "$HOME/.config/sprites"
printf '%s' "$pw" > "$HOME/.config/sprites/$name.pass"
chmod 600 "$HOME/.config/sprites/$name.pass"

sprite checkpoint create -s "$name" --comment clean

echo
echo "Workspace $name is ready."
echo "  RDP login:  sprite / $pw (saved to ~/.config/sprites/$name.pass)"
echo "  Connect:    ./connect-desktop.sh $name"
echo "  Reset:      ./reset-workspace.sh $name"
