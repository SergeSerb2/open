#!/bin/bash
# Runs on the scheduler after the Mac streamed sources into /opt/e3/seed (see README "Seed the CAS").
# Hashes every file, dedupes by digest, then seed-move.py places them in the CAS. Restart NativeLink after.
set -euo pipefail
D=/opt/e3/data/cas/d2; sudo mkdir -p $D
cd /opt/e3/seed
find . -type f -print0 | xargs -0 -P 8 -n 2000 sha256sum > /opt/e3/seed.sha
wc -l < /opt/e3/seed.sha
# path -> digest; dedupe by digest
awk '{h=$1; $1=""; sub(/^ +/,""); if(!(h in s)){s[h]=1; print h "\t" $0}}' /opt/e3/seed.sha > /opt/e3/seed.uniq
wc -l < /opt/e3/seed.uniq
sudo python3 /opt/e3/seed-move.py
