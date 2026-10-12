#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs a locally built Ramble Voice bundle for the current user (no root).
#   tool/install-linux.sh [--capslock] [--no-autostart]
# --capslock   Turn Caps Lock into the dictation key on GNOME: maps Caps Lock to
#              Menu (xkb option caps:menu) and sets Ramble's hotkey to Menu.
#              Caps Lock no longer toggles capitals.
# Build first: tool/fl flutter build linux --release
set -euo pipefail
cd "$(dirname "$0")/.."

app_id=io.github.luohoa97.RambleVoice
bundle=$(find build/linux -type d -path '*release/bundle' | head -n 1)
[ -n "$bundle" ] && [ -x "$bundle/ramble_voice" ] || { echo "No release bundle; run: tool/fl flutter build linux --release" >&2; exit 1; }

capslock=0
autostart=1
for arg in "$@"; do
  case "$arg" in
    --capslock) capslock=1 ;;
    --no-autostart) autostart=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

data="${XDG_DATA_HOME:-$HOME/.local/share}"
dest="$HOME/.local/opt/ramble-voice"
bin="$HOME/.local/bin"

pkill -x ramble_voice 2>/dev/null || true
rm -rf "$dest.new"
mkdir -p "$dest.new" "$bin" "$data/applications" "$data/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$dest.new/"
rm -rf "$dest"
mv "$dest.new" "$dest"
ln -sf "$dest/ramble_voice" "$bin/ramble-voice"

install -m 644 packaging/icons/$app_id-256.png "$data/icons/hicolor/256x256/apps/$app_id.png"

entry() {
  cat <<EOF
[Desktop Entry]
Type=Application
Name=Ramble Voice
Comment=Speak a messy ramble, get clean text
Exec=$dest/ramble_voice $1
Icon=$app_id
Terminal=false
Categories=Utility;Accessibility;
Keywords=dictation;voice;speech;transcribe;
StartupWMClass=$app_id
X-GNOME-UsesNotifications=true
EOF
}
entry "%U" > "$data/applications/$app_id.desktop"
update-desktop-database "$data/applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -q "$data/icons/hicolor" >/dev/null 2>&1 || true

if [ "$autostart" = 1 ]; then
  mkdir -p "$HOME/.config/autostart"
  { entry "--background"; echo "X-GNOME-Autostart-enabled=true"; } > "$HOME/.config/autostart/$app_id.desktop"
fi

if [ "$capslock" = 1 ]; then
  current=$(gsettings get org.gnome.desktop.input-sources xkb-options)
  if ! grep -q "caps:menu" <<<"$current"; then
    new=$(python3 -c 'import ast,sys; o=[x for x in ast.literal_eval(sys.argv[1].replace("@as ","")) if not x.startswith("caps:")]; o.append("caps:menu"); print(str(o))' "$current")
    gsettings set org.gnome.desktop.input-sources xkb-options "$new"
  fi
  settings="$data/$app_id/settings.json"
  mkdir -p "$(dirname "$settings")"
  python3 - "$settings" <<'PY'
import json, os, sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) else {}
s["hotkeyTrigger"] = "Menu"
json.dump(s, open(p, "w"), indent=2)
PY
  echo "Caps Lock now acts as Menu and triggers Ramble Voice (hold to talk)."
fi

echo "Installed to $dest. Start it from the app grid or run: ramble-voice"
