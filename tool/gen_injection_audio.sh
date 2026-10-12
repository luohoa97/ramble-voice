#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generates 16 kHz mono s16 WAVs for every case in
# test/fixtures/injection/cases.json into test/fixtures/injection/audio/.
# Needs espeak-ng and one of ffmpeg or sox. Inside the toolbox:
#   toolbox run -c ramble tool/gen_injection_audio.sh
# (sudo dnf install -y espeak-ng sox  if missing)
set -euo pipefail
cd "$(dirname "$0")/.."

cases=test/fixtures/injection/cases.json
out=test/fixtures/injection/audio
mkdir -p "$out"

command -v espeak-ng >/dev/null || { echo "espeak-ng not found" >&2; exit 1; }
if command -v ffmpeg >/dev/null; then conv=ffmpeg; elif command -v sox >/dev/null; then conv=sox
else echo "need ffmpeg or sox" >&2; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One "id<TAB>spoken" line per case.
if command -v python3 >/dev/null; then
  python3 -c '
import json, sys
for c in json.load(open(sys.argv[1]))["cases"]:
    print(c["id"] + "\t" + c["spoken"])' "$cases" > "$tmp/list.tsv"
else
  echo "python3 not found" >&2; exit 1
fi

while IFS=$'\t' read -r id text; do
  espeak-ng -v en-us -s 160 -w "$tmp/$id.wav" "$text"
  if [ "$conv" = ffmpeg ]; then
    ffmpeg -loglevel error -y -i "$tmp/$id.wav" -ar 16000 -ac 1 -sample_fmt s16 "$out/$id.wav"
  else
    sox "$tmp/$id.wav" -r 16000 -c 1 -b 16 -e signed-integer "$out/$id.wav"
  fi
  echo "wrote $out/$id.wav"
done < "$tmp/list.tsv"
