#!/usr/bin/env python3
"""Rebuild pinned redirect resources offline; never stage unverified bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CAP = 4 * 1024 * 1024


MACHINE_CACHE = Path.home() / "Library/Caches/OpenRE/adblock-resources"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", required=True, type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--include-source", action="store_true", help="stage verified uBO text sources for bundle notices")
    parser.add_argument("--pins", type=Path, default=ROOT / "Engine/fork/adblock/resources-pins.txt")
    args = parser.parse_args()
    pins = {}
    for line in args.pins.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3 or fields[0] in pins or not re.fullmatch(r"[0-9a-f]{64}", fields[2]):
            raise ValueError("invalid resources pin")
        pins[fields[0]] = fields[1:]
    if set(pins) != {"ubo.tar.gz", "resources.json"} or pins["resources.json"][0] != "assemble:ubo.tar.gz":
        raise ValueError("expected source archive and assembled output pins")
    url, source_hash = pins["ubo.tar.gz"]
    match = re.fullmatch(r"https://codeload.github.com/gorhill/uBlock/tar.gz/([0-9a-f]{40})", url)
    if not match:
        raise ValueError("resources require an immutable official uBlock source")
    output_hash = pins["resources.json"][1]
    # Reject symlink cache entries and rehash the copied output below. The Swift
    # runtime also uses O_NOFOLLOW and bounded reads before publication/on open.
    # A machine-wide cache, keyed by the output pin, lets fresh worktrees and
    # machines without Cargo (the M1) build: seed it once per machine.
    machine = MACHINE_CACHE / output_hash / "resources.json"
    def usable(path):
        return path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= CAP and sha(path) == output_hash
    cached = next((path for path in ((args.cache or args.dest) / "resources.json", machine) if usable(path)), None)
    valid = cached is not None
    args.dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="open-adblock-resources-", dir="/tmp") as work:
        work = Path(work)
        output = work / "resources.json"
        if valid:
            shutil.copyfile(cached, output)
            print("resources.json: verified cache", flush=True)
        if not valid or args.include_source:
            archive = work / "ubo.tar.gz"
            archive_cache = (args.cache or args.dest) / "ubo.tar.gz"
            if archive_cache.is_file() and not archive_cache.is_symlink() and archive_cache.stat().st_size <= 16777216 and sha(archive_cache) == source_hash:
                shutil.copyfile(archive_cache, archive)
                print("ubo.tar.gz: verified source cache", flush=True)
            else:
                print("ubo.tar.gz: missing/stale source cache; refetch " + url, flush=True)
                subprocess.run(["curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https",
                                "--connect-timeout", "15", "--max-time", "90", "--retry", "3",
                                "--max-filesize", "16777216", "-o", str(archive), url], check=True)
            if sha(archive) != source_hash:
                raise ValueError("ubo.tar.gz: SHA-256 pin mismatch")
            prefix = "uBlock-" + match[1] + "/"
            total = count = 0
            with tarfile.open(archive, "r:gz") as source:
                for member in source:
                    # Only assembler inputs and their license; no upstream program runs.
                    name = member.name.removeprefix(prefix)
                    if not member.name.startswith(prefix) or not (name.startswith("src/web_accessible_resources/") or name in {"src/js/redirect-resources.js", "LICENSE.txt"}):
                        continue
                    if member.isdir():
                        continue
                    count += 1
                    total += member.size
                    if not member.isfile() or ".." in Path(name).parts or member.size < 0 or total > 32 * 1024 * 1024 or count > 4096:
                        raise ValueError("invalid or oversized assembler input archive")
                    target = work / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as body, target.open("wb") as dest:
                        shutil.copyfileobj(body, dest)
            for line in (ROOT / "Engine/fork/adblock/resources-inputs.sha256").read_text().splitlines():
                expected, name = line.split("  ", 1)
                if sha(work / name) != expected:
                    raise ValueError("assembler input hash mismatch: " + name)
        if not valid:
            print("resources.json: missing/stale cache; refetch pinned inputs and assemble", flush=True)
            cargo = shutil.which("cargo")
            if cargo is None and (Path.home() / ".cargo/bin/cargo").is_file():
                cargo = str(Path.home() / ".cargo/bin/cargo")
            if cargo is None:
                raise ValueError("Cargo is required to rebuild resources; seed the machine cache " + str(machine) + " with the pinned resources.json (copy it from a machine that built it; the pin verifies it)")
            driver = work / "driver"
            shutil.copytree(ROOT / "tools/adblock-resources", driver)
            # Fetch checksum-locked crates first. The assembler itself runs offline.
            subprocess.run([cargo, "fetch", "--locked", "--manifest-path", str(driver / "Cargo.toml")], check=True)
            subprocess.run([cargo, "run", "--quiet", "--offline", "--locked", "--manifest-path", str(driver / "Cargo.toml"), "--",
                            str(work / "src/web_accessible_resources"), str(work / "src/js/redirect-resources.js"), str(output)], check=True)
        if not 0 < output.stat().st_size <= CAP or sha(output) != output_hash:
            raise ValueError("resources.json: SHA-256 pin mismatch or size limit exceeded")
        if args.include_source:
            # Notices keep original text, including original copyright headers.
            # Binary stubs are in resources.json; the exact complete upstream
            # archive remains available at the source URL in the license inventory.
            source_dir = args.dest / "ubo-source"
            if source_dir.exists():
                shutil.rmtree(source_dir)
            names = sorted(resource["name"] for resource in json.loads(output.read_text()))
            if any(Path(name).name != name for name in names):
                raise ValueError("redirect source name is not a filename")
            source_paths = [work / "LICENSE.txt", work / "src/js/redirect-resources.js"]
            source_paths += [work / "src/web_accessible_resources" / name for name in names]
            for path in source_paths:
                try:
                    path.read_bytes().decode("utf-8")
                except UnicodeDecodeError:
                    continue
                target = source_dir / path.relative_to(work)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
            shutil.copyfile(archive, args.dest / "ubo.tar.gz")
        # Final same-filesystem rename only after output verification.
        fd, name = tempfile.mkstemp(prefix=".resources-", dir=args.dest)
        try:
            with os.fdopen(fd, "wb") as dest:
                dest.write(output.read_bytes())
            os.replace(name, args.dest / "resources.json")
        finally:
            Path(name).unlink(missing_ok=True)
    if not usable(machine):
        machine.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=".resources-", dir=machine.parent)
        try:
            with os.fdopen(fd, "wb") as dest:
                dest.write((args.dest / "resources.json").read_bytes())
            os.replace(name, machine)
        finally:
            Path(name).unlink(missing_ok=True)
    print(f"resources.json: bytes={(args.dest / 'resources.json').stat().st_size} sha256={output_hash}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SystemExit(f"fetch-adblock-resources: {error}")
