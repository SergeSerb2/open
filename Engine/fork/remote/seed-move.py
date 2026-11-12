#!/usr/bin/env python3
# runs as root on the scheduler: move hashed seed files into the NativeLink CAS dir (skip existing digests)
import os
D = "/opt/e3/data/cas/d2"
moved = skipped = missing = 0
with open("/opt/e3/seed.uniq") as f:
    for line in f:
        h, p = line.rstrip("\n").split("\t", 1)
        src = os.path.join("/opt/e3/seed", p)
        try:
            st = os.stat(src)
        except FileNotFoundError:
            missing += 1   # already moved by the earlier shell loop
            continue
        dst = f"{D}/{h}-{st.st_size}-0"
        if os.path.exists(dst):
            skipped += 1
            continue
        os.rename(src, dst)
        os.chown(dst, 0, 0)
        moved += 1
print("moved", moved, "skipped", skipped, "already_moved", missing, "total", len(os.listdir(D)))
