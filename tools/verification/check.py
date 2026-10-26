#!/usr/bin/env python3
"""Fixtures and assertions for verify-all.sh; invokes real release interfaces only."""
import contextlib
import json
import os
from pathlib import Path
import re
import runpy
import select
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import zlib


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*args, expected=0, env=None, quiet=False, timeout=180):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        if not quiet and error.stdout:
            output = error.stdout
            print(output.decode(errors="replace") if isinstance(output, bytes) else output, end="", flush=True)
        raise RuntimeError(f"command {Path(args[0]).name} timed out after {timeout}s") from None
    if not quiet:
        print(result.stdout, end="", flush=True)
    require(result.returncode == expected,
            f"command {Path(args[0]).name} exited {result.returncode}; expected {expected}")
    return result.stdout


def matches(pattern, text):
    require(re.search(pattern, text, re.MULTILINE), f"missing pass evidence: {pattern}")


def all_passed(text):
    fractions = re.findall(r"\b(\d+)/(\d+)\s+(?:checks\s+)?passed\b", text)
    counts = re.findall(r"\b(\d+) checks passed, (\d+) failed\b", text)
    counts += re.findall(r"\bchecks:\s*(\d+) passed, (\d+) failed\b", text)
    require(fractions or counts, "missing N/N passed, N checks passed, or checks: N passed, 0 failed summary")
    require(all(int(n) == int(d) and int(n) > 0 for n, d in fractions), "incomplete pass count")
    require(all(int(n) > 0 and int(f) == 0 for n, f in counts), "failed check count")
    require(not re.search(r"^\s*(?:FAIL\b|.*\bFAIL(?:ED)?:)", text, re.MULTILINE),
            "explicit failure in output")


def build(root):
    # A new session protects the Swift build from an app restart. Stop on diagnostics,
    # drain its pipe, and count warning lines even when Swift would otherwise exit 0.
    command = ["nice", "-n", "10", "swift", "build", "-c", "release", "-j",
               os.environ.get("VERIFY_JOBS", "6")]
    warnings = errors = 0
    with subprocess.Popen(command, cwd=root / "Packages/OpenKit", start_new_session=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as job:
        try:
            for line in job.stdout:
                print(line, end="", flush=True)
                warnings += int("warning:" in line)
                errors += int("error:" in line)
                if (warnings or errors) and job.poll() is None:
                    os.killpg(job.pid, signal.SIGTERM)
            code = job.wait()
        finally:
            if job.poll() is None:
                os.killpg(job.pid, signal.SIGTERM)
                job.wait()
    print(f"build exit={code} warning_lines={warnings} error_lines={errors}")
    require(code == 0 and warnings == 0 and errors == 0, "release build must be warning/error free")


def seed_snapshot(cli, seed):
    snapshot = seed / "State/browser.json"
    if not snapshot.is_file():
        text = run(cli, "commands-demo", str(seed))
        matches(r"commands-demo OK: [1-9]\d* checks passed, 0 failed", text)
    return json.loads(snapshot.read_text())


def save_snapshot(data, directory="fixture"):
    path = Path(directory) / "State/browser.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))
    return str(path.parent.parent.resolve())


def route(cli, root, seed):
    for name in ("route-check.sh", "verify-routing.sh", "verify-route.sh"):
        runner = root / "tools" / name
        if runner.is_file():
            run("/bin/bash", str(runner))
            return
    runner = root / "Packages/OpenKit/.build/release/route-check"
    if runner.is_file():
        all_passed(run(str(runner)))
        return
    usage = run(cli, expected=2, quiet=True)
    if re.search(r"[<|]route-check[|>]", usage):
        all_passed(run(cli, "route-check"))
        return
    # docs/routing.md A1-A10: synthetic snapshot, no imported URLs or network.
    data = seed_snapshot(cli, seed)
    target = data["spaces"][0]["id"]
    data["defaultDestination"] = {"littleOpen": {}}

    def rule(kind, value, destination, source=None):
        item = {"id": "00000000-0000-0000-0000-000000000010",
                "match": {kind: {"_0": value}}, "destination": destination}
        if source:
            item["sourceBundleID"] = source
        return item

    space = {"space": {"_0": target}}
    little = {"littleOpen": {}}

    def case(label, url, expected, rules, *options):
        data["routingRules"] = rules
        directory = save_snapshot(data)
        print(label)
        toggle = () if "--external-little-open" in options else ("--external-little-open", "on")
        return run(cli, "route", directory, url, *toggle,
                   "--expect-destination", expected, *options)

    host = rule("hostEquals", "example.com", space)
    case("A1", "https://example.com/", "littleOpen", [rule("hostEquals", "other.invalid", space)])
    case("A2", "https://www.example.com/", "space:" + target, [host])
    case("A3", "https://sub.example.com/", "littleOpen", [host])
    case("A4", "https://mail.google.com/", "space:" + target, [rule("hostContains", "google.com", space)])
    later = dict(host, id="00000000-0000-0000-0000-000000000011")
    case("A5", "https://example.com/", "littleOpen", [rule("hostEquals", "example.com", little), later],
         "--external-little-open", "off")
    source = rule("hostEquals", "example.com", space, "com.example.mail")
    case("A6 no source", "https://example.com/", "littleOpen", [source])
    case("A6 source", "https://example.com/", "space:" + target, [source], "--source", " COM.EXAMPLE.MAIL ")
    case("A7 off", "https://example.com/", "space:" + target, [],
         "--most-recent", target, "--external-little-open", "off")
    case("A7 on", "https://example.com/", "littleOpen", [])
    print("A8")
    text = run(cli, "route", save_snapshot(data), "ftp://example.com/", "--external-little-open", "on")
    matches(r"decision: rejected", text)
    stale = rule("hostEquals", "example.com", {"space": {"_0": "00000000-0000-0000-0000-000000000099"}})
    text = case("A9", "https://example.com/", "space:" + target, [stale, later])
    matches(r"target Space missing", text)
    text = case("A10", "https://example.com/", "littleOpen", [], "--json")
    decision = json.loads(text)
    require("littleOpen" in decision["resolved"] and "defaultDestination" in decision["via"],
            "A10 JSON does not agree with default Little Open decision")
    print("route A1-A10 passed")


@contextlib.contextmanager
def server(kind, location):
    # Bind port 0 in the actual server, avoiding fixed-port conflicts and reservation races.
    with open("server.log", "w") as log:
        job = subprocess.Popen([sys.executable, "-u", str(Path(__file__).resolve()),
                                "server", kind, str(location)], start_new_session=True,
                               stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            require(select.select([job.stdout], [], [], 10)[0], "local server startup timed out")
            line = job.stdout.readline().strip()
            require(line.isdigit(), "local server failed to publish its bound port; see server.log")
            yield "http://127.0.0.1:" + line
        finally:
            if job.poll() is None:
                job.terminate()
            job.wait(timeout=10)
            job.stdout.close()


def serve(kind, location):
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
    from functools import partial
    handler = (runpy.run_path(location)["Handler"] if kind == "boosts" else
               partial(SimpleHTTPRequestHandler, directory=location))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as http:
        print(http.server_port, flush=True)
        http.serve_forever()


def png():
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress((b"\x00" + b"\x40\x80\xc0\xff" * 16) * 16)) + chunk(b"IEND", b""))


def favicons(cli, seed):
    site = Path("site").resolve()
    site.mkdir()
    (site / "index.html").write_text('<html><head><link rel="icon" href="/icon.png"></head><body>Local Open fixture</body></html>')
    (site / "icon.png").write_bytes(png())
    with server("favicon", site) as origin:
        data = seed_snapshot(cli, seed)
        # Keep one real demo tab and remove all external origins from traversal.
        def tabs(value):
            if isinstance(value, dict):
                if "url" in value and "createdAt" in value:
                    yield value
                for child in value.values():
                    yield from tabs(child)
            elif isinstance(value, list):
                for child in value:
                    yield from tabs(child)
        tab = next(tabs(data))
        tab["url"] = origin + "/"
        tab.pop("pinnedURL", None)
        for profile in data["profiles"]:
            profile["favorites"] = []
        data["profiles"][0]["favorites"] = [{"tab": {"_0": tab}}]
        data["spaces"] = []
        data["windows"] = []
        directory = save_snapshot(data)
        env = dict(os.environ, OPENKIT_FAVICON_DEBUG="1")
        text = run(cli, "favicons", "fetch", "--snapshot", directory, "--db", "icons.sqlite3",
                   "--treat-as-public", "127.0.0.1", "--diagnostic-concurrent", "2", env=env)
        matches(r"concurrentPrefetches=2 fetchOne=ok", text)
        matches(r"requested=1 alreadyCached=0 fetched=1 missing=0 failed=0", text)
        text = run(cli, "favicons", "fetch", "--snapshot", directory, "--db", "icons.sqlite3")
        matches(r"requested=1 alreadyCached=1 fetched=0 missing=0 failed=0", text)
        for size in (32, 64):
            output = f"icon-{size}.png"
            run(cli, "favicons", "get", origin + "/other", "--db", "icons.sqlite3", "--out", output, "--size", str(size))
            image = Path(output).read_bytes()
            require(image[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", image[16:24]) == (size, size), "wrong PNG dimensions")
        matches(r"ok=1 missing=0 failed=0 count=1", run(cli, "favicons", "stats", "--db", "icons.sqlite3"))
        (site / "icon.png").unlink()
        (site / "index.html").write_text("<html><head></head><body>No icon</body></html>")
        matches(r"requested=1 alreadyCached=0 fetched=0 missing=1 failed=0",
                run(cli, "favicons", "fetch", "--snapshot", directory, "--db", "missing.sqlite3"))
        matches(r"^absent$", run(cli, "favicons", "get", origin, "--db", "missing.sqlite3", "--out", "absent.png", expected=1))
    print("favicons local fetch, cache, readback, and missing flow passed")


def adblock_perf(cli):
    text = run(cli, "adblock", "perf", "--dir", str(Path("data").resolve()))
    lookup = re.search(r"lookups_1000 p95_ms=([\d.]+) budget_ms=1 groups=10 lookups=10000 matches=5000", text)
    opened = re.search(r"profile_open_with_integrity_scan p95_ms=([\d.]+) budget_ms=10", text)
    require(lookup and opened, "missing one of the two adblock performance metrics")
    require(float(lookup[1]) < 1 and float(opened[1]) < 10, "adblock performance budget exceeded")


def adblock_catalog(cli, root):
    text = run(cli, "adblock", "catalog")
    catalog = json.loads((root / "Packages/OpenKit/Sources/OpenAdBlock/Resources/catalog.json").read_text())
    lists = catalog["lists"]
    rows = re.findall(r"^(\S+) \| .*? \| category=(\S+) default_on=(true|false) bundled=(true|false) info=(\S+)$", text, re.MULTILINE)
    require(len(lists) == len(rows) == 46, "catalog must contain all 46 entries")
    require({row[0] for row in rows} == {item["id"] for item in lists}, "catalog IDs differ")
    categories = {name: sum(row[1] == name for row in rows) for name in ("generic", "cookies", "privacy", "regional", "bcny")}
    require(list(categories.values()) == [3, 2, 5, 35, 1], "catalog category counts differ")
    require({row[0] for row in rows if row[2] == "true"} == {"EasyList", "EasyPrivacy"}, "catalog defaults differ")
    print("catalog 46/46; categories 3/2/5/35/1; defaults verified")


def archive_migration(cli):
    for boundary in ("alter", "version"):
        root = Path("archive-migration-" + boundary).resolve()
        file = root / "Profiles/Default/State/archive.sqlite3"
        file.parent.mkdir(parents=True)
        with sqlite3.connect(file) as db:
            db.executescript("""
                CREATE TABLE archived_tabs(id TEXT PRIMARY KEY,url TEXT NOT NULL,title TEXT NOT NULL,
                  space_id TEXT,profile_id TEXT,archived_at REAL NOT NULL,reason TEXT NOT NULL,
                  original_location TEXT NOT NULL,payload TEXT NOT NULL);
                INSERT INTO archived_tabs VALUES('00000000-0000-0000-0000-000000000001',
                  'https://example.invalid/legacy','Legacy tab',NULL,NULL,1,'folderDeleted','today:legacy','{}');
            """)
            original = db.execute("SELECT * FROM archived_tabs").fetchall()
        environment = dict(os.environ, OPENKIT_DEBUG_ARCHIVE_MIGRATION_CRASH=boundary)
        run(cli, "archive-list", str(root), expected=86, env=environment)
        with sqlite3.connect(file) as db:
            require("kind" not in [row[1] for row in db.execute("PRAGMA table_info(archived_tabs)")], "crash published partial kind column")
            require(db.execute("PRAGMA user_version").fetchone()[0] == 0, "crash published schema version")
            require(db.execute("SELECT * FROM archived_tabs").fetchall() == original, "crash changed old rows")
            require(db.execute("PRAGMA quick_check").fetchone()[0] == "ok", "crashed archive is corrupt")
        for _ in range(2):
            text = run(cli, "archive-list", str(root))
            matches(r"archive rows total=1 showing=1", text)
            matches(r"kind=tab reason=folderDeleted", text)
        with sqlite3.connect(file) as db:
            require(db.execute("PRAGMA user_version").fetchone()[0] == 1, "migration version not committed")
            require(db.execute("SELECT kind FROM archived_tabs").fetchall() == [("tab",)], "legacy row kind changed")
        print("FA6 crash recovery and repeated migration passed: " + boundary)


def profiles(cli):
    directory = str(Path("data").resolve())
    def command(*args, expected=0):
        return run(cli, "profiles", directory, *args, expected=expected)
    matches(r"no snapshot at", command("list"))
    command("create", "--name", "Personal")
    command("create", "--name", "Work")
    rows = json.loads(command("list", "--json"))
    require(len(rows) == 2 and rows[0]["isDefault"] and rows[0]["dataDirectoryName"] == "Default" and
            not rows[1]["isDefault"] and rows[1]["dataDirectoryName"].startswith("Profile-"), "P-2 default/directory mismatch")
    snapshot = Path(directory) / "State/browser.json"
    def refusal(args, message):
        before = snapshot.read_bytes()
        matches(message, command(*args, expected=1))
        require(snapshot.read_bytes() == before, "refused command changed the snapshot")
    refusal(("create", "--name", "work"), r"profile name duplicate")
    command("create-space", "--title", "Work Space", "--profile", "Work")
    def assigned(name):
        data = json.loads(snapshot.read_text())
        profile = next(item for item in data["profiles"] if item["name"] == name)
        require(len(data["spaces"]) == 1 and data["spaces"][0]["profileID"] == profile["id"], "wrong Space assignment")
    assigned("Work")
    refusal(("delete", "Work"), r"profile has 1 space\(s\)")
    command("assign-space", "Work Space", "--to", "Personal")
    assigned("Personal")
    refusal(("delete", "Personal"), r"profile is default")
    command("create", "--name", "Temp")
    temp = next(item for item in json.loads(snapshot.read_text())["profiles"] if item["name"] == "Temp")
    folder = Path(directory) / "Profiles" / temp["dataDirectoryName"]
    require(folder.is_dir(), "P-8 create did not create profile directory")
    matches(r"deleted profile .*archivedFavorites=0", command("delete", "Temp"))
    require(folder.is_dir(), "P-8 delete removed the profile directory")
    require(all(item["id"] != temp["id"] for item in json.loads(snapshot.read_text())["profiles"]), "P-8 deleted profile remains")
    run(cli, "dump", directory)
    matches(r"roundtrip OK", run(cli, "roundtrip", directory))
    print("profiles P-1 through P-8 and P-10 passed; real-data P-9 requires --with-arc-data")


def arc_import(cli):
    # All private files AND raw command output are removed even with --keep-logs.
    # Only allowlisted count lines can reach the persistent log.
    with tempfile.TemporaryDirectory(prefix="private-arc-") as private:
        source = Path.home() / "Library/Application Support/Arc"
        copy = Path(private) / "arc"
        copy.mkdir(mode=0o700)
        files = list(source.glob("*.json"))
        require(files, "no Arc JSON files available for the requested import")
        for file in files:
            shutil.copyfile(file, copy / file.name)
        output = str(Path(private) / "import")
        text = run(cli, "import-arc", "--arc-dir", str(copy), "--out", output, quiet=True)
        matches(r"^  accounted check: OK$", text)
        if "archive filePresent=true" in text:
            matches(r"^  archive check accounted=(\d+) total=\1 OK$", text)
        else:
            matches(r"archive filePresent=false total=0 imported=0", text)
        print(f"copiedJSONFiles={len(files)}")
        for line in text.splitlines():
            if re.match(r"^  (?:totalItems=|pinnedTabs=|folders=|skipped easels=|orphans=|archive filePresent=|archive check accounted=|containers\(structural\)=|accounted check:)", line):
                print(line)
        listed = run(cli, "archive-list", output, "--limit", "0", quiet=True)
        matches(r"^archive rows total=\d+ showing=0$", listed)
        stored = re.search(r"storedTotal=(\d+)", text)
        if stored:
            matches(r"^archive rows total=" + stored[1] + r" showing=0$", listed)
        print(listed, end="")
        # When available, P-9 inspects the imported profile through the public CLI.
        usage = run(cli, quiet=True, expected=2)
        if re.search(r"[<|]profiles[|>]", usage):
            listed = run(cli, "profiles", output, "list", quiet=True)
            matches(r"dir=Default", listed)
            print("importedProfiles=" + str(len(re.findall(r"^profile ", listed, re.MULTILINE))))
        matches(r"roundtrip OK", run(cli, "roundtrip", output, quiet=True))
        print("importRoundtrip=1")


def boosts(root):
    require(shutil.which("npm"), "npm is required when node and Chrome exist")
    shutil.copyfile(root / "tools/verification/boosts.mjs", "boosts.mjs")
    Path("package.json").write_text('{"private":true,"type":"module"}\n')
    run("npm", "i", "--no-audit", "--no-fund", "--ignore-scripts", "puppeteer-core")
    with server("boosts", root / "Packages/OpenKit/Sources/OpenBoosts/Harness/serve.py") as origin:
        run("node", "boosts.mjs", origin)


def main():
    if sys.argv[1] == "server":
        serve(sys.argv[2], sys.argv[3])
        return
    name, root, seed = sys.argv[1:]
    root, seed = Path(root), Path(seed)
    cli = str(root / "Packages/OpenKit/.build/release/openkit")
    if name == "build":
        build(root)
    elif name == "commands-demo":
        directory = Path("data").resolve()
        text = run(cli, name, str(directory))
        matches(r"commands-demo OK: [1-9]\d* checks passed, 0 failed", text)
        shutil.copytree(directory, seed, dirs_exist_ok=True)
        archive_migration(cli)
    elif name == "roundtrip":
        data = seed_snapshot(cli, seed)
        shutil.copytree(seed, "data")
        matches(r"^roundtrip OK$", run(cli, name, str(Path("data").resolve())))
        require(data["profiles"], "roundtrip fixture has no profiles")
        for profile in data["profiles"]:
            profile["settings"].pop("keepAliveSites", None)
        old_directory = save_snapshot(data, "without-keep-alive")
        matches(r"^roundtrip keepAliveSites OK: profiles=\d+ sites=0$", run(cli, name, old_directory))
        old_saved = json.loads((Path(old_directory) / "State/browser.json").read_text())
        require(all(p["settings"]["keepAliveSites"] == [] for p in old_saved["profiles"]),
                "old snapshot did not default keepAliveSites to []")
        print("roundtrip keepAliveSites: old snapshot without key decodes as [] OK")
        for index, profile in enumerate(data["profiles"]):
            profile["settings"]["keepAliveSites"] = [f"notify-{index}.example.invalid/inbox", "WWW.Custom.invalid/Chat"]
        new_directory = save_snapshot(data, "with-keep-alive")
        matches(r"^roundtrip OK$", run(cli, name, new_directory))
        new_saved = json.loads((Path(new_directory) / "State/browser.json").read_text())
        expected = {p["id"]: p["settings"]["keepAliveSites"] for p in data["profiles"]}
        require({p["id"]: p["settings"]["keepAliveSites"] for p in new_saved["profiles"]} == expected,
                "snapshot changed per-profile keepAliveSites values")
        print("roundtrip keepAliveSites: snapshot values preserved per profile OK")
    elif name == "suggest-check":
        all_passed(run(cli, name))
    elif name == "commands-dump":
        text = run(str(root / "Packages/OpenKit/.build/release/commands-dump"))
        matches(r"missing=0 extra=0 different=0\b", text)
        matches(r"^  no unexpected conflicts$", text)
        matches(r"^  no unexpected conflicts after overrides$", text)
        matches(r"^commands-dump OK$", text)
    elif name == "route":
        route(cli, root, seed)
    elif name == "favicons":
        favicons(cli, seed)
    elif name == "media-demo":
        all_passed(run(cli, name))
    elif name == "sleep-demo":
        text = run(cli, name, str(Path("data").resolve()))
        all_passed(text)
        matches(r"sleep-demo OK:", text)
    elif name == "adblock-perf":
        adblock_perf(cli)
    elif name == "adblock-catalog":
        adblock_catalog(cli, root)
    elif name == "profiles":
        profiles(cli)
    elif name == "settings-preview":
        preview = str(root / "Packages/OpenKit/.build/release/settings-preview")
        all_passed(run(preview, "check"))
        output = Path("settings-panes").resolve()
        run(preview, "render", "--out", str(output))
        dump = run(preview, "dump-keys", "--root", str(output / "fixture"))
        require("snapshot profile Personal searchEngineID = google" in dump, "missing settings store receipt")
        pngs = sorted(output.glob("*.png"))
        require(len(pngs) == 214, "missing settings/library/appearance/detail/sheet/state renders")
        states = ("welcome welcome-inactive welcome-counting welcome-nodata welcome-saveerror "
                  "import import-arcrunning import-counting import-nodata import-parsehint "
                  "import-parsehint-running import-partial import-capability-on secrets secrets-on "
                  "progress progress-history-landed report report-worst report-saveerror failed "
                  "default-browser default-declined default-error default-already "
                  "welcome-singular import-singular secrets-singular report-singular "
                  "welcome-large import-large secrets-large").split()
        required = {f"first-run-{state}{appearance}@{scale}x.png"
                    for state in states for appearance in ("", "-light") for scale in (1, 2)}
        require(required <= {p.name for p in pngs}, "missing permanent first-run review state")
        for png in pngs:
            data = png.read_bytes()
            scale = 2 if "@2x" in png.name else 1
            sheets = {"previews": (480, 320), "search-engines": (520, 420), "clear-data": (460, 360),
                      "adblock": (600, 560), "link-rule": (520, 380), "link-rule-invalid": (520, 380), "suggestion-notice": (400, 180), "search-engine-edit": (520, 540), "profile-create": (440, 330),
                      "profile-rename": (440, 180), "archive-scope": (500, 160)}
            expected = (560, 520) if png.name.startswith("first-run-") else ((960, 640) if png.name.startswith("library-") else ((640, 520) if png.name.startswith("import-") else (sheets[png.name.split("@")[0][6:]] if png.name.startswith("sheet-") else (684, 650))))
            require(data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == tuple(n * scale for n in expected), "bad pane dimensions: " + png.name)
    elif name in ("sidebar-render", "commandbar-render"):
        all_passed(run(str(root / "Packages/OpenKit/.build/release" / name), "check"))
    elif name == "sidebar-compare":
        args = [str(root / "tools/verification/sidebar-compare-states.sh")]
        if os.environ.get("SIDEBAR_CAPTURE_ROOT"):
            args.append(os.environ["SIDEBAR_CAPTURE_ROOT"])
        if os.environ.get("SIDEBAR_BASELINE_RENDERER"):
            args += ["--baseline-renderer", os.environ["SIDEBAR_BASELINE_RENDERER"]]
        if os.environ.get("SIDEBAR_BASELINE_REF"):
            args += ["--baseline-ref", os.environ["SIDEBAR_BASELINE_REF"]]
        # Renders can contain private titles. Keep them out of the normal log
        # directory (which may be an artifact upload directory).
        text = run(*args, timeout=1800)
        matches(r"^states passed: 13/13;", text)
        output = Path(re.search(r"output: (\S+)", text)[1])
        baseline = os.environ.get("SIDEBAR_BASELINE_RENDERER") or str(output / "main-source/Packages/OpenKit/.build/release/sidebar-render")
        all_passed(run(str(root / "Packages/OpenKit/.build/release/sidebar-render"), "divider-check", "--baseline", baseline, "--out", str(output / "cu5")))
    elif name == "boosts":
        boosts(root)
    elif name == "import-arc":
        arc_import(cli)
    else:
        raise RuntimeError("unknown check " + name)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No exception text for private imports: exceptions can contain personal paths/data.
        detail = "private import failed (raw output discarded)" if sys.argv[1] == "import-arc" else str(error)
        print("FAIL: " + detail, file=sys.stderr)
        sys.exit(1)
