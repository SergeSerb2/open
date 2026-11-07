#!/bin/bash
# Stage release-pinned official lists. Never reads a browser bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt"
DEST="$ROOT/Vendor/adblock"
UPDATE=false
while (($#)); do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --update-pins) UPDATE=true; shift ;;
    *) echo "usage: $0 [--dest DIR] [--update-pins]" >&2; exit 2 ;;
  esac
done
mkdir -p "$DEST"
STAGING="$(mktemp -d "$DEST/.fetch.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$PINS" "$STAGING/list-pins.txt"
count=0
bytes=0
while read -r name url expected; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  case "$name $url" in
    'easylist.txt https://easylist.to/easylist/easylist.txt'|'easyprivacy.txt https://easylist.to/easylist/easyprivacy.txt') ;;
    *) echo "unsupported list source: $name" >&2; exit 1 ;;
  esac
  # An existing snapshot is immutable until an explicit pin refresh. This also
  # makes offline builds repeatable and refuses a tampered cache without repair.
  if [[ "$UPDATE" == false && -e "$DEST/$name" ]]; then
    [[ $(wc -c < "$DEST/$name") -le 16777216 ]] || { echo "$name: size limit exceeded" >&2; exit 1; }
    cp "$DEST/$name" "$STAGING/$name"
  else
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 90 --retry 3 \
      --max-filesize 16777216 -o "$STAGING/$name" "$url" || {
        echo "$name: no verified staged snapshot; fetch failed (offline builds require a pinned cache)" >&2; exit 1;
      }
  fi
  first="$(awk 'NF { sub(/^\xef\xbb\xbf/, ""); print; exit }' "$STAGING/$name")"
  [[ "$first" == '[Adblock Plus'* ]] || { echo "$name: invalid header" >&2; exit 1; }
  actual="$(shasum -a 256 "$STAGING/$name" | cut -d ' ' -f1)"
  if [[ "$UPDATE" == true ]]; then
    python3 - "$STAGING/list-pins.txt" "$name" "$actual" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
lines=p.read_text().splitlines()
for i,line in enumerate(lines):
    fields=line.split()
    if fields and fields[0]==sys.argv[2]:
        lines[i]=' '.join([fields[0],fields[1],sys.argv[3]])
p.write_text('\n'.join(lines)+'\n')
PY
    echo "$name: $expected -> $actual"
  elif [[ "$actual" != "$expected" ]]; then
    echo "$name: SHA-256 pin mismatch expected=$expected actual=$actual" >&2; exit 1
  fi
  count=$((count + 1))
  bytes=$((bytes + $(wc -c < "$STAGING/$name")))
done < "$PINS"
# Publish only after every fetched file passed verification. Same-filesystem rename per file.
while read -r name url expected; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  mv -f "$STAGING/$name" "$DEST/$name"
done < "$PINS"
[[ "$UPDATE" == false ]] || mv -f "$STAGING/list-pins.txt" "$PINS"
echo "fetch-adblock-lists: $count files, $bytes bytes -> $DEST"
