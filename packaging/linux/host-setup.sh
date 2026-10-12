#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Optional host setup for Ramble Voice text insertion through ydotool.
#
# Run this on the HOST (not inside the Flatpak sandbox). It is only needed on
# compositors without a RemoteDesktop portal, wtype or xdotool route, or if you
# prefer ydotool. Ramble Voice works without it (clipboard fallback).
#
# What it does:
#   1. Installs /etc/udev/rules.d/80-ramble-uinput.rules so the logged-in seat
#      user can open /dev/uinput (needs root, via pkexec or sudo).
#   2. Checks that ydotoold is installed and tells you how to install it.
#   3. Creates and enables a systemd user service running ydotoold with its
#      socket at $XDG_RUNTIME_DIR/.ydotool_socket.
#
# Security note: access to /dev/uinput lets the logged-in user's processes
# inject keyboard input. Run `host-setup.sh --uninstall` to revert.
#
# Usage: host-setup.sh [--uninstall] [--yes] [--help]
set -euo pipefail

RULE_FILE=/etc/udev/rules.d/80-ramble-uinput.rules
RULE_LINE='KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"'
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/ramble-ydotoold.service"

assume_yes=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall=1 ;;
    --yes | -y) assume_yes=1 ;;
    --help | -h)
      sed -n '4,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [ -e /.flatpak-info ]; then
  echo "This script must run on the host, not inside the Flatpak sandbox." >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user. It asks for root only where needed." >&2
  exit 1
fi

confirm() {
  [ "$assume_yes" -eq 1 ] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

as_root() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Neither pkexec nor sudo found; cannot run: $*" >&2
    return 1
  fi
}

reload_udev() {
  as_root udevadm control --reload-rules
  as_root udevadm trigger --subsystem-match=misc --sysname-match=uinput || true
}

systemd_user() {
  systemctl --user "$@"
}

if [ "$uninstall" -eq 1 ]; then
  echo "This will remove the udev rule and the ramble-ydotoold user service."
  confirm "Continue?" || exit 1
  if systemd_user list-unit-files ramble-ydotoold.service >/dev/null 2>&1; then
    systemd_user disable --now ramble-ydotoold.service || true
  fi
  rm -f "$UNIT_FILE"
  systemd_user daemon-reload || true
  if [ -e "$RULE_FILE" ]; then
    as_root rm -f "$RULE_FILE"
    reload_udev
  fi
  echo "Reverted. ydotool itself was not uninstalled."
  exit 0
fi

cat <<TXT
Ramble Voice host setup (optional)

This will:
  1. Write $RULE_FILE (root required) giving the active seat user access to /dev/uinput.
  2. Create and enable the systemd user service $UNIT_FILE
     which runs ydotoold with its socket at \$XDG_RUNTIME_DIR/.ydotool_socket.

TXT
confirm "Continue?" || exit 1

ydotoold_bin=$(command -v ydotoold || true)
if [ -z "$ydotoold_bin" ]; then
  cat >&2 <<'TXT'
ydotoold was not found on your PATH. Install it first, then rerun this script:
  Fedora:           sudo dnf install ydotool
  Debian / Ubuntu:  sudo apt install ydotool
  Arch:             sudo pacman -S ydotool
  Bluefin / Silverblue (rpm-ostree): brew install ydotool
                    or: rpm-ostree install ydotool && systemctl reboot
TXT
  exit 1
fi

# 1. udev rule (idempotent)
if [ -f "$RULE_FILE" ] && grep -qxF "$RULE_LINE" "$RULE_FILE"; then
  echo "udev rule already present."
else
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "# Installed by Ramble Voice host-setup.sh" "$RULE_LINE" >"$tmp"
  as_root install -m 644 "$tmp" "$RULE_FILE"
  reload_udev
  echo "Installed $RULE_FILE."
fi

# 2. systemd user service (idempotent)
mkdir -p "$UNIT_DIR"
cat >"$UNIT_FILE" <<UNIT
# Installed by Ramble Voice host-setup.sh
[Unit]
Description=ydotool daemon for Ramble Voice text insertion

[Service]
Type=simple
ExecStart=$ydotoold_bin --socket-path=%t/.ydotool_socket --socket-own=$(id -u):$(id -g)
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
systemd_user daemon-reload
systemd_user enable --now ramble-ydotoold.service
echo "Service ramble-ydotoold is enabled."

cat <<'TXT'

Done. If /dev/uinput is still not accessible, log out and back in.
Check the daemon with: systemctl --user status ramble-ydotoold
For the Flatpak, the socket is exposed to the sandbox by the app manifest.
Revert everything with: host-setup.sh --uninstall
TXT
