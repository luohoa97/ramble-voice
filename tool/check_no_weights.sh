#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fails if model weights or very large files are tracked.
set -euo pipefail
cd "$(dirname "$0")/.."

max_bytes=$((20 * 1024 * 1024))
fail=0

while IFS= read -r -d '' f; do
  case "$f" in
    *.task | *.litertlm | *.bin | *.gguf | *.safetensors)
      echo "model weights or binary blob tracked: $f"
      fail=1
      ;;
  esac
  if [ -f "$f" ]; then
    size=$(stat -c %s "$f")
    if [ "$size" -gt "$max_bytes" ]; then
      echo "file larger than 20 MB tracked: $f ($size bytes)"
      fail=1
    fi
  fi
done < <(git ls-files -z)

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "No model weights or oversized files tracked."
