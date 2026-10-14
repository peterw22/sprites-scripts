#!/usr/bin/env bash
# Installs an XFCE desktop + xrdp on a Sprite. Usage: ./setup-desktop.sh <sprite-name>
sprite exec -s "$1" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

# Ubuntu only ships Firefox as a snap, and snaps need systemd.
# Use the .deb from Mozilla APT repo instead, pinned above the snap stub.
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null
printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" | sudo tee /etc/apt/preferences.d/mozilla >/dev/null

sudo --preserve-env=DEBIAN_FRONTEND apt-get update
sudo --preserve-env=DEBIAN_FRONTEND apt-get install -y xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11 fuse3 firefox

# Listen on loopback only. We come in through a tunnel.
sudo sed -i "0,/^port=3389/s//port=tcp:\/\/127.0.0.1:3389/" /etc/xrdp/xrdp.ini

# xrdp runs as the xrdp user and has to reach the per-session sockets.
sudo sed -i "s/^#\?SessionSockdirGroup=.*/SessionSockdirGroup=xrdp/" /etc/xrdp/sesman.ini

# Start XFCE when you log in over RDP (clean up any stale FUSE mount first).
cat << "EOF" > ~/.xsession
fusermount -uz "$HOME/thinclient_drives" 2>/dev/null || true
exec startxfce4
EOF

# The sprite user gets a password for xrdp. Keep SSH key-only.
echo "PasswordAuthentication no" | sudo tee /etc/ssh/sshd_config.d/10-no-password.conf >/dev/null
if pgrep -x sshd >/dev/null; then sudo service ssh reload; fi

# No systemd on a Sprite, so let the Sprite runtime supervise xrdp.
sprite-env services create xrdp-sesman --cmd sudo \
  --args "sh,-c,. /usr/share/xrdp/socksetup && exec /usr/sbin/xrdp-sesman --nodaemon" --no-stream
sprite-env services create xrdp --cmd sudo \
  --args "-u,xrdp,/usr/sbin/xrdp,--nodaemon" --needs xrdp-sesman --no-stream'
