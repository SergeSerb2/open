#!/bin/bash
# Build NativeLink v1.8.3 with a 4 MiB max_batch_total_size_bytes (upstream hard-codes 64 KiB,
# which makes Siso upload small files 2 per round trip; our client is 150 ms away).
set -euo pipefail
cd /opt/e3
# boat.dev images ship rustup/cargo in /usr/local/cargo (owned by user).
export RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/rustup} CARGO_HOME=${CARGO_HOME:-/usr/local/cargo}
export PATH=$CARGO_HOME/bin:$PATH
sudo apt-get install -y -qq build-essential pkg-config >/dev/null 2>&1 || true
[ -d nativelink-src ] || git clone -q --depth 1 --branch v1.8.3 https://github.com/TraceMachina/nativelink.git nativelink-src
cd nativelink-src
git rev-parse HEAD
sed -i 's/^const MAX_BATCH_TOTAL_SIZE: i64 = 64 \* 1024;/const MAX_BATCH_TOTAL_SIZE: i64 = 4 * 1024 * 1024;/' nativelink-service/src/capabilities_server.rs
grep -n "^const MAX_BATCH_TOTAL_SIZE" nativelink-service/src/capabilities_server.rs
git diff --stat
nice -n 5 cargo build --release --bin nativelink 2>&1 | tail -3
cp target/release/nativelink /opt/e3/nativelink-batch4m
/opt/e3/nativelink-batch4m --version
