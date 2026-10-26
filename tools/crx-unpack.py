#!/usr/bin/env python3 -I
"""Unpack a CRX3 file into a directory for --load-extension testing.

  tools/crx-unpack.py <file.crx> <out-dir> [expected-extension-id]

Adds the CRX public key as manifest "key", so the unpacked extension keeps
its Chrome Web Store id (needed for stores, native messaging and allowlists).
"""
import base64
import hashlib
import io
import json
import os
import struct
import sys
import zipfile


def varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def fields(buf):
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        num, wire = key >> 3, key & 7
        if wire == 2:
            n, i = varint(buf, i)
            yield num, buf[i:i + n]
            i += n
        elif wire == 0:
            v, i = varint(buf, i)
            yield num, v
        else:
            raise ValueError("unsupported wire type %d" % wire)


def ext_id(pubkey):
    digest = hashlib.sha256(pubkey).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def main(crx_path, out_dir, expected=None):
    data = open(crx_path, "rb").read()
    magic, version, header_len = struct.unpack("<4sII", data[:12])
    if magic != b"Cr24" or version != 3:
        raise SystemExit("not a CRX3 file")
    header = data[12:12 + header_len]
    keys = []
    for num, value in fields(header):
        if num in (2, 3):  # sha256_with_rsa, sha256_with_ecdsa
            for n, v in fields(value):
                if n == 1:
                    keys.append(v)
    key = None
    for k in keys:
        if expected is None or ext_id(k) == expected:
            key = k
            break
    with zipfile.ZipFile(io.BytesIO(data[12 + header_len:])) as z:
        z.extractall(out_dir)
    manifest_path = os.path.join(out_dir, "manifest.json")
    manifest = json.load(open(manifest_path, encoding="utf-8-sig"))
    if key:
        manifest["key"] = base64.b64encode(key).decode()
    json.dump(manifest, open(manifest_path, "w"), indent=2)
    print(json.dumps({"dir": out_dir, "id": ext_id(key) if key else None,
                      "name": manifest.get("name"), "version": manifest.get("version"),
                      "manifest_version": manifest.get("manifest_version")}))


if __name__ == "__main__":
    main(*sys.argv[1:])
