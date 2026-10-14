---
title: Using Sprite as a Remote Desktop
description: Extending the Sprite dev box with an XFCE desktop over xrdp, tunneled through SSH.
date: 2026-10-09
---

# Using Sprite as a Remote Desktop

In the [last post](/blog/cloud_notes/vscode_remote_sprites) I turned a Sprite into a remote dev box that I reach over SSH from VS Code. That covers 90% of my work. The other 10% needs a screen: a GUI app, a browser pointed at something only reachable from inside the box, or a tool that just refuses to run headless.

So let's put a real desktop on it. The plan is XFCE as the desktop, xrdp as the RDP server, and the same SSH setup from last time as the tunnel. No new ports exposed, and the Sprite still sleeps when I walk away.

## Why xrdp?

I could have gone with VNC, but RDP clients are just better. Every OS has a good one, they handle resizing and clipboard, and xrdp gives each login its own X session instead of mirroring a physical screen (which a Sprite doesn't have anyway).

## Sprite-side setup

This assumes you already did the [Sprite-side setup](/blog/cloud_notes/vscode_remote_sprites#sprite-side-setup) from the last post, so sshd and your key are in place.

### Install the desktop

```bash
sprite exec -s my-blog -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

# Ubuntu only ships Firefox as a snap, and snaps need systemd.
# Use the .deb from Mozilla APT repo instead, pinned above the snap stub.
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null
printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" | sudo tee /etc/apt/preferences.d/mozilla >/dev/null

sudo --preserve-env=DEBIAN_FRONTEND apt-get update
sudo --preserve-env=DEBIAN_FRONTEND apt-get install -y xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11 firefox

# Listen on loopback only. We come in through a tunnel.
sudo sed -i "0,/^port=3389/s//port=tcp:\/\/127.0.0.1:3389/" /etc/xrdp/xrdp.ini

# xrdp runs as the xrdp user and has to reach the per-session sockets.
sudo sed -i "s/^#\?SessionSockdirGroup=.*/SessionSockdirGroup=xrdp/" /etc/xrdp/sesman.ini

# Start XFCE when you log in over RDP.
echo startxfce4 > ~/.xsession

# The sprite user gets a password for xrdp. Keep SSH key-only.
echo "PasswordAuthentication no" | sudo tee /etc/ssh/sshd_config.d/10-no-password.conf >/dev/null
if pgrep -x sshd >/dev/null; then sudo service ssh reload; fi

# No systemd on a Sprite, so let the Sprite runtime supervise xrdp.
sprite-env services create xrdp-sesman --cmd sudo \
  --args "sh,-c,. /usr/share/xrdp/socksetup && exec /usr/sbin/xrdp-sesman --nodaemon" --no-stream
sprite-env services create xrdp --cmd sudo \
  --args "-u,xrdp,/usr/sbin/xrdp,--nodaemon" --needs xrdp-sesman --no-stream'
```

The install takes about four minutes. A few of those lines deserve an explanation, because each one is a wall I hit.

**`SessionSockdirGroup=xrdp`**: Without this you log in, the session starts, and you get a black screen with `connection problem, giving up` in the log. On Ubuntu, the `xrdp` daemon drops to an unprivileged `xrdp` user, but the session manager creates each user's socket directory with group `root` by default, so xrdp can't open the socket for the X session it just started. Setting the group to `xrdp` fixes it.

**The Mozilla repo**: On Ubuntu, `apt install firefox` installs a stub package (`1snap1`) that pulls in the snap. Snaps need snapd, and snapd needs systemd, so that dead-ends on a Sprite. Mozilla publishes a regular `.deb` in its own [APT repo](https://support.mozilla.org/kb/install-firefox-linux), and the pin with priority 1000 makes apt pick it over Ubuntu's stub.

**`--preserve-env=DEBIAN_FRONTEND` instead of `sudo -E`**: My first version used `sudo -E apt-get`. That keeps `HOME=/home/sprite` for root, so a package's post-install hook created `~/.cache` owned by root with mode 700. Everything looked fine until I clicked Firefox in the menu and got "Your Firefox profile cannot be loaded". Firefox keeps part of its profile under `~/.cache` and couldn't write there. Passing only the variable apt needs keeps root's `HOME` at `/root`.

**`sprite-env services`**: A Sprite has no systemd (PID 1 is `tini`), so `systemctl enable xrdp` is not a thing. In the last post I got away with starting sshd on demand from the ProxyCommand. For xrdp I'm using Sprite [Services](https://docs.fly.io/sprites/concepts/services) instead. The runtime starts them at boot, restarts them if they crash, and brings them back after a cold wake. Services run as the `sprite` user, hence the `sudo`. `/run` is a tmpfs that gets wiped on a cold boot, which is why sesman runs xrdp's `socksetup` first to recreate `/run/xrdp`. Services also don't keep the Sprite awake by themselves, so an idle xrdp costs nothing.

### Set a password

xrdp logs you in through PAM, so the `sprite` user needs a password. This is also why the step above turns off password auth for SSH: SSH stays key-only.

```bash
sprite exec -s my-blog --tty -- sudo passwd sprite
```

That's it for the Sprite-side setup.

## Client setup

### Open the tunnel

xrdp only listens on the Sprite's `127.0.0.1:3389`, so forward a local port to it over the SSH config from last time:

```bash
ssh -S none -N -L 13389:127.0.0.1:3389 my-blog.spr.internal
```

The ProxyCommand wakes the Sprite and starts sshd like before, and the Sprite runtime has already brought up xrdp. Leave this running while you use the desktop, and press `Ctrl-C` when you're done.

The `-S none` matters. With the `ControlPersist` setting from the last post, a plain `ssh -N -L` forks into a background control master and keeps the tunnel open after you think you closed it. An open connection keeps the Sprite awake, and an awake Sprite bills. `-S none` skips connection sharing for the tunnel, so `Ctrl-C` actually closes it.

If you don't want SSH in the picture at all, `sprite proxy` does the same thing:

```bash
sprite proxy -s my-blog 13389:3389
```

### Connect an RDP client

Point any RDP client at `localhost:13389` and log in as `sprite` with the password you set.

- **macOS / Windows**: Microsoft's Windows App (formerly Microsoft Remote Desktop). Add a PC with `localhost:13389` as the address.
- **Linux**: FreeRDP.

```bash
xfreerdp /v:localhost:13389 /u:sprite /dynamic-resolution
```

xrdp uses a self-signed certificate, so the client asks you to trust it the first time.

![XFCE desktop running on a Sprite over xrdp](/content/cloud_notes/xrdp_remote_sprites/desktop.png)

And there it is: a full XFCE desktop on the Sprite, on the same box VS Code is already connected to. Firefox runs fine too:

![Firefox running inside the Sprite desktop](/content/cloud_notes/xrdp_remote_sprites/firefox.png)

When I'm done, I close the RDP window and `Ctrl-C` the tunnel, and nothing is left holding the Sprite awake.
