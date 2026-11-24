#!/bin/sh
set -eu
DATA_DIR="${OPEN_SYNC_DATA_DIR:-/data}"
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DATA_DIR"
  chown -R node:node "$DATA_DIR"
  exec setpriv --reuid=node --regid=node --clear-groups -- "$@"
fi
exec "$@"
