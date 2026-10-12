#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Downloads and verifies the pinned Flutter embedder engine (libflutter_engine.so).
#   linux/engine/fetch_engine.sh <x64|aarch64> <debug|profile|release>
# Result: linux/engine/<arch>-<mode>/libflutter_engine.so
# The engine is built from the same revision as the Flutter SDK by ardera/flutter-ci
# (MIT) because Google only publishes a JIT/debug embedder engine for Linux.
set -euo pipefail

arch="${1:?usage: $0 <x64|aarch64> <debug|profile|release>}"
[ "$arch" = "x86_64" ] && arch=x64
[ "$arch" = "arm64" ] && arch=aarch64
mode="${2:?usage: $0 <x64|aarch64> <debug|profile|release>}"
here="$(cd "$(dirname "$0")" && pwd)"
lock="$here/engine.lock"
dest="$here/$arch-$mode"
asset="engine-$arch-generic-$mode.tar.xz"

rev="$(sed -n 's/^ENGINE_REVISION=//p' "$lock")"
repo="$(sed -n 's/^ENGINE_REPO=//p' "$lock")"
want="$(awk -v a="$asset" '$2 == a { print $1 }' "$lock")"
[ -n "$want" ] || { echo "fetch_engine: no pinned hash for $asset" >&2; exit 1; }

if [ -f "$dest/libflutter_engine.so" ] && [ -f "$dest/.sha256" ] && [ "$(cat "$dest/.sha256")" = "$want" ]; then
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/$repo/releases/download/engine%2F$rev/$asset"
echo "fetch_engine: downloading $asset"
curl -fsSL --retry 3 -o "$tmp/$asset" "$url"
got="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
if [ "$got" != "$want" ]; then
  echo "fetch_engine: sha256 mismatch for $asset: got $got, want $want" >&2
  exit 1
fi
rm -rf "$dest"
mkdir -p "$dest"
tar -C "$dest" -xf "$tmp/$asset"
[ -f "$dest/libflutter_engine.so" ] || { echo "fetch_engine: archive has no libflutter_engine.so" >&2; exit 1; }
echo "$want" > "$dest/.sha256"
