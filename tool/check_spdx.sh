#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fails if a source file lacks the GPL-3.0-or-later SPDX header.
# Checks tracked files (or all files when not in a git checkout).
set -euo pipefail
cd "$(dirname "$0")/.."

want='SPDX-License-Identifier: GPL-3.0-or-later'

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  list() { git ls-files -z -- "$@"; }
else
  list() { find "$@" -type f -print0 2>/dev/null; }
fi

dirs=(lib linux native android/app/src tool packaging .github)
existing=()
for d in "${dirs[@]}"; do
  [ -e "$d" ] && existing+=("$d")
done

fail=0
checked=0
while IFS= read -r -d '' f; do
  case "$f" in
    *.g.dart | *GeneratedPluginRegistrant* | *generated_plugin* | linux/flutter/ephemeral/* | */build/* | */.dart_tool/*) continue ;;
  esac
  case "$f" in
    *.dart | *.kt | *.kts | *.c | *.h | *.cc | *.cmake | */CMakeLists.txt | CMakeLists.txt | *.sh | *.yml | *.yaml) ;;
    *) continue ;;
  esac
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  if ! head -n 5 "$f" | grep -q "$want"; then
    echo "missing SPDX header: $f"
    fail=1
  fi
done < <(list "${existing[@]}")

if [ "$fail" -ne 0 ]; then
  echo "SPDX check failed ($checked files checked)." >&2
  exit 1
fi
echo "SPDX check passed ($checked files checked)."
