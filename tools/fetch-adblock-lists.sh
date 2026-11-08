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
commit=
if [[ "$UPDATE" == true ]]; then
  commit="$(git ls-remote https://github.com/easylist/easylist refs/heads/gh-pages | awk '$2 == "refs/heads/gh-pages" { print $1 }')"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid gh-pages commit" >&2; exit 1; }
  echo "easylist/easylist gh-pages: $commit"
fi
count=0
bytes=0
seed_commit=
seen_names=' '
while read -r name url expected; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! "$url" =~ ^https://raw\.githubusercontent\.com/easylist/easylist/([0-9a-f]{40})/(easylist|easyprivacy)\.txt$ ||
        "$name" != "${url##*/}" || ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "unsupported list source or pin: $name" >&2; exit 1
  fi
  current_commit="${url#https://raw.githubusercontent.com/easylist/easylist/}"
  current_commit="${current_commit%%/*}"
  [[ "$seen_names" != *" $name "* ]] || { echo "duplicate bundled list: $name" >&2; exit 1; }
  seen_names+="$name "
  [[ -z "$seed_commit" || "$seed_commit" == "$current_commit" ]] || { echo "bundled lists must use the same commit" >&2; exit 1; }
  seed_commit="$current_commit"
  old_url="$url"
  [[ "$UPDATE" == false ]] || url="https://raw.githubusercontent.com/easylist/easylist/$commit/$name"
  # Reuse a cached snapshot only when it matches the pin (offline builds stay
  # repeatable). A stale or tampered cache is fetched again from the immutable,
  # commit-pinned URL and must then match the pin; nothing unverified is staged.
  if [[ "$UPDATE" == false && -f "$DEST/$name" && $(wc -c < "$DEST/$name") -le 16777216 &&
        "$(shasum -a 256 "$DEST/$name" | cut -d ' ' -f1)" == "$expected" ]]; then
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
    python3 - "$STAGING/list-pins.txt" "$name" "$url" "$actual" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
lines=p.read_text().splitlines()
for i,line in enumerate(lines):
    fields=line.split()
    if fields and fields[0]==sys.argv[2]:
        lines[i]=' '.join([fields[0],sys.argv[3],sys.argv[4]])
p.write_text('\n'.join(lines)+'\n')
PY
    echo "$name: $old_url $expected -> $url $actual"
  elif [[ "$actual" != "$expected" ]]; then
    echo "$name: SHA-256 pin mismatch expected=$expected actual=$actual" >&2; exit 1
  fi
  count=$((count + 1))
  bytes=$((bytes + $(wc -c < "$STAGING/$name")))
done < "$PINS"
[[ "$count" == 2 ]] || { echo "expected both bundled lists" >&2; exit 1; }
# The package receipt mirrors the engine-side canonical pin for SwiftPM callers.
cmp "$ROOT/Engine/fork/adblock/resources-pins.txt" "$ROOT/Packages/OpenKit/Sources/OpenAdBlock/Resources/resources-pins.txt" || {
  echo 'resources pins differ between engine and Swift package' >&2; exit 1;
}
python3 "$ROOT/tools/fetch-adblock-resources.py" --dest "$STAGING" --cache "$DEST" --include-source
# Publish only after every fetched file passed verification. Same-filesystem rename per file.
while read -r name url expected; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  mv -f "$STAGING/$name" "$DEST/$name"
done < "$PINS"
mv -f "$STAGING/resources.json" "$DEST/resources.json"
mv -f "$STAGING/ubo.tar.gz" "$DEST/ubo.tar.gz"
rm -rf "$DEST/ubo-source"
mv "$STAGING/ubo-source" "$DEST/ubo-source"
# SwiftPM CLI/settings-preview callers also need an offline bundled payload.
# This generated file is ignored; its bytes have passed the same output pin.
MODULE="$ROOT/Packages/OpenKit/Sources/OpenAdBlock/Resources"
if ! cmp -s "$DEST/resources.json" "$MODULE/resources.json"; then
  cp "$DEST/resources.json" "$MODULE/.resources.json.tmp"
  mv -f "$MODULE/.resources.json.tmp" "$MODULE/resources.json"
fi
[[ "$UPDATE" == false ]] || mv -f "$STAGING/list-pins.txt" "$PINS"
echo "fetch-adblock-lists: $count files, $bytes bytes -> $DEST"
