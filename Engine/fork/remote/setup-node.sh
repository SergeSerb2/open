#!/bin/bash
# E3 node setup: NativeLink + Chromium's pinned Linux clang (same revision as the M5 tree).
set -euo pipefail
NL_VER=1.8.3
NL_SHA=1a6596c96f059d4e99f7352164321e1f1cdff435275667ad8489e83f7e2977c5
CL_OBJ=Linux_x64/clang-llvmorg-24-init-7747-g62397f8b-53.tar.xz
CL_SHA=53c3bfd12b5d01378c6277bbebcacec595ef9d9fc4ec54f155c03a1b2cae4dbf
sudo mkdir -p /opt/e3 /opt/cr-clang
sudo chown user:user /opt/e3 /opt/cr-clang
cd /opt/e3
if [ ! -x /opt/e3/nativelink ]; then
  curl -fsSL -o nl.tgz "https://github.com/TraceMachina/nativelink/releases/download/v${NL_VER}/nativelink-${NL_VER}-x86_64-unknown-linux-musl.tar.gz"
  echo "$NL_SHA  nl.tgz" | sha256sum -c -
  mkdir -p nlx && tar -xzf nl.tgz -C nlx && find nlx -type f -name nativelink -exec cp {} /opt/e3/nativelink \; && chmod +x /opt/e3/nativelink && rm -rf nl.tgz nlx
fi
if [ ! -x /opt/cr-clang/bin/clang ]; then
  curl -fsSL -o cl.txz "https://commondatastorage.googleapis.com/chromium-browser-clang/${CL_OBJ}"
  echo "$CL_SHA  cl.txz" | sha256sum -c -
  tar -xJf cl.txz -C /opt/cr-clang && rm cl.txz
fi
/opt/e3/nativelink --version || true
/opt/cr-clang/bin/clang --version | head -1
cat /opt/cr-clang/cr_build_revision 2>/dev/null || true
