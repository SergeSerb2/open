#!/usr/bin/env python3
"""Fixtures and assertions for verify-all.sh; invokes real release interfaces only."""
import contextlib
import fcntl
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
import time
import zlib


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class SuiteInterrupted(RuntimeError):
    pass


def run(*args, expected=0, env=None, quiet=False, timeout=180, interrupted_exit=None):
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
    if interrupted_exit is not None and result.returncode == interrupted_exit:
        raise SuiteInterrupted(f"command {Path(args[0]).name}: native foreground lost")
    require(result.returncode == expected,
            f"command {Path(args[0]).name} exited {result.returncode}; expected {expected}")
    return result.stdout


def native_suite_apps(directory):
    """LaunchServices apps escape the renderer's process group; match only our root."""
    output = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,comm="], text=True)
    prefix = str(Path(directory).resolve()) + "/open-editor-native-"
    suffix = "/EditorHarness.app/Contents/MacOS/sitecontrol-render"
    found = set()
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            pid, executable = fields
            if os.path.realpath(executable).startswith(prefix) and executable.endswith(suffix):
                found.add(int(pid))
    return found


def stop_native_suite_apps(directory):
    # Recheck the executable path before every signal, including SIGKILL, so a
    # recycled PID or another worktree's harness cannot become a cleanup target.
    found = native_suite_apps(directory)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in native_suite_apps(directory):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, sig)
        deadline = time.monotonic() + 2
        while native_suite_apps(directory) and time.monotonic() < deadline:
            time.sleep(0.05)
        if not native_suite_apps(directory):
            break
    require(not native_suite_apps(directory), "owned native suite app survived cleanup")
    return len(found)


def onscreen_suite(command):
    """Own lockf's shared FD; keep the 180 s execution budget after acquisition."""
    termination_signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    cancelled = None
    waiting_for_lock = False
    directory = job = lock_file = None
    cleanup_complete = False
    output = ""

    def cleanup():
        nonlocal cleanup_complete, output
        if cleanup_complete:
            return
        # Repeated process-group signals must not interrupt cleanup, including
        # the short-lived ps children used to identify our registered app.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, termination_signals)
        try:
            if job is not None:
                if job.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(job.pid, signal.SIGTERM)
                    # Keep the leader unreaped through the TERM grace. Its PID
                    # cannot be reused before KILL reaches remaining group members.
                    time.sleep(2)
                    groups = subprocess.check_output(["/bin/ps", "-axo", "pgid=,stat="], text=True)
                    if any(fields[0] == str(job.pid) and not fields[1].startswith("Z")
                           for line in groups.splitlines() if len(fields := line.split()) == 2):
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(job.pid, signal.SIGKILL)
                    output, _ = job.communicate(timeout=2)
                job.wait()
            native_apps = stop_native_suite_apps(directory.name) if directory is not None else 0
            if directory is not None:
                directory.cleanup()
            renderer = f"renderer {job.pid} reaped" if job is not None else "no renderer started"
            with contextlib.suppress(BrokenPipeError):
                print(f"On-screen cleanup: {renderer}; native apps stopped={native_apps}; private root removed", flush=True)
            # flock locks this shared open-file description. Reap all
            # helpers and remove the root before releasing our last descriptor.
            if lock_file is not None:
                lock_file.close()
            cleanup_complete = True
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def exit_cancelled():
        # This internal worker owns its signal policy until process exit. Cleanup
        # may already have run in finally, or a late handler may enter here.
        signal.pthread_sigmask(signal.SIG_BLOCK, termination_signals)
        cleanup()
        code = 128 + cancelled
        with contextlib.suppress(BrokenPipeError):
            print(f"On-screen cancellation: {signal.Signals(cancelled).name}; owned cleanup complete; exit {code}", flush=True)
        # The parent may have died in the same group signal and closed stdout.
        # All owned resources are gone; avoid a failing Python exit-time pipe
        # flush replacing the required cancellation status with exit 120.
        os._exit(code)

    def terminate(signum, _frame):
        nonlocal cancelled
        if cancelled is None:
            cancelled = signum
        if cleanup_complete:
            exit_cancelled()
        if waiting_for_lock:
            # Raising prevents Python from restarting the blocking flock after
            # the signal. Setup and child assignment still use deferred cancel.
            raise InterruptedError("on-screen lock wait cancelled")
        # Do not raise asynchronously across TemporaryDirectory/Popen assignment:
        # a spawned child must be recorded before cancellation can unwind setup.

    for signum in termination_signals:
        signal.signal(signum, terminate)

    timed_out = False
    failure = None
    try:
        lock_path = "/tmp/open-onscreen-e2e.lock"
        while cancelled is None:
            # TANDEM-RULES §3.4a: this native suite never creates a priority flag.
            # Queue time stays outside the execution deadline, as for lock acquisition.
            priority = Path("/tmp/open-onscreen-priority")
            while cancelled is None:
                try:
                    if time.time() - priority.stat().st_mtime >= 1800:
                        break
                except FileNotFoundError:
                    break
                time.sleep(0.25)
            if cancelled is not None:
                break
            lock_file = open(lock_path, "a+")
            waiting_for_lock = True
            try:
                if cancelled is None:
                    # Join the kernel's queue alongside lockf waiters. Polling
                    # with LOCK_NB can starve behind already-blocked waiters.
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            finally:
                waiting_for_lock = False
            if cancelled is not None:
                break
            # An older lockf user or external replacement may unlink the path.
            # Never start a suite on a locked inode that is no longer current.
            held = os.fstat(lock_file.fileno())
            try:
                current = os.stat(lock_path)
            except FileNotFoundError:
                current = None
            if current is not None and (held.st_dev, held.st_ino) == (current.st_dev, current.st_ino):
                break
            lock_file.close()
            lock_file = None
        if cancelled is not None:
            exit_cancelled()
        directory = tempfile.TemporaryDirectory(prefix="open-onscreen-suite-")
        # Foundation can ignore TMPDIR for NSTemporaryDirectory on macOS. Give
        # the registered-app launcher an explicit owned root as well.
        environment = dict(os.environ, TMPDIR=directory.name + "/", OPEN_VERIFY_SUITE_ROOT=directory.name)
        print(f"On-screen lock acquired; suite deadline=180s; worker {os.getpid()}", flush=True)
        if cancelled is None:
            job = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, env=environment, start_new_session=True)
            print(f"On-screen renderer {job.pid}; private temporary root={directory.name}", flush=True)
            deadline = time.monotonic() + 180
            while cancelled is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    # A non-raising signal handler leaves setup and communicate
                    # consistent; this bounded wait observes cancellation promptly.
                    output, _ = job.communicate(timeout=min(0.25, remaining))
                    break
                except subprocess.TimeoutExpired:
                    pass
    except BaseException as error:
        failure = error
    finally:
        cleanup()
    if cancelled is not None:
        exit_cancelled()
    if failure is not None:
        raise failure
    print(output, end="", flush=True)
    require(not timed_out, "on-screen suite timed out after 180s (owned children reaped)")
    if job.returncode == 2:
        raise SuiteInterrupted("on-screen suite exhausted three foreground-interrupted attempts")
    require(job.returncode == 0, f"on-screen suite exited {job.returncode}; expected 0")


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


def legacy_space_fixture(cli, root):
    portability = runpy.run_path(str(Path(__file__).with_name("portable-baselines.py")))
    baseline, scale, key = portability["legacy_baseline"](root)
    fixture = root / "Packages/OpenKit/Fixtures/space-schema1"
    original = (fixture / "State/browser.json").read_bytes()
    expected = json.loads(original)
    # main's later keep-alive setting is additive and defaults to an empty list.
    # Every original semantic field must remain equal; no other addition is allowed.
    for profile in expected["profiles"]:
        profile["settings"].setdefault("keepAliveSites", [])
    directory = Path("legacy-space").resolve()
    shutil.copytree(fixture, directory)
    matches(r"^roundtrip OK$", run(cli, "roundtrip", str(directory)))
    require(json.loads((directory / "State/browser.json").read_text()) == expected,
            "legacy Space fixture semantic fields changed (only main's default keepAliveSites=[] may be added)")
    renderer = str(root / "Packages/OpenKit/.build/release/sidebar-render")
    for space in range(3):
        output = Path(f"legacy-space-{space}.png").resolve()
        run(renderer, "render", "--snapshot", str(directory), "--space", str(space),
            "--size", "900x700", "--scale", str(scale), "--out", str(output),
            env=dict(os.environ, OPEN_VERIFY_DISPLAY_KEY=key))
        if os.environ.get("OPEN_VERIFY_BREAK") in ("all", "legacy"):
            run("/usr/bin/swift", str(Path(__file__).with_name("break-render.swift")), str(output), "pixel")
        require(output.read_bytes() == (baseline / f"window-{space}.png").read_bytes(),
                f"legacy Space {space} PNG differs from the committed pre-Step-1 baseline")
    require((fixture / "State/browser.json").read_bytes() == original, "legacy fixture source was modified")
    print("P1 legacy DTO roundtrip byte comparison PASS; original semantic fields unchanged; 3/3 baseline PNGs byte-identical")


def space_icon_import(cli):
    icons = [{"emoji_v2": "🧭"}, {"emoji": 128188}, {"icon": "planet"},
             {"emoji_v2": ""}, {"icon": "future-unknown-icon"}]
    items = []
    ids = [f"icon-tab-{i}" for i in range(len(icons))]
    for ident, icon in zip(ids, icons):
        items.extend([ident, {"id": ident, "parentID": "pinned-container", "childrenIds": [], "createdAt": 0,
                              "data": {"tab": {"savedURL": "https://example.com/", "savedTitle": "Synthetic icon tab",
                                               "customInfo": {"iconType": icon}}}}])
    items.extend(["pinned-container", {"id": "pinned-container", "childrenIds": ids, "data": {"itemContainer": {}}}])
    source = {"version": 1, "sidebar": {"containers": [{"global": {}}, {"items": items,
              "spaces": ["icon-space", {"id": "icon-space", "title": "Synthetic icons", "profile": {"default": True},
                         "containerIDs": ["pinned", "pinned-container"], "customInfo": {}}], "topAppsContainerIDs": []}]}}
    directory = Path("icon-source").resolve()
    directory.mkdir()
    (directory / "StorableSidebar.json").write_text(json.dumps(source))
    output = Path("icon-import").resolve()
    result = run(cli, "import-arc", "--arc-dir", str(directory), "--out", str(output), "--counts-only")
    matches(r"namedSpaceIcons mapped=1 unknown=1 fallback=circle.dotted", result)
    data = json.loads((output / "State/browser.json").read_text())
    tabs = [node["tab"]["_0"] for node in data["spaces"][0]["pinned"]]
    expected = [{"emoji": {"_0": "🧭"}}, {"emoji": {"_0": "💼"}}, {"named": {"_0": "planet"}},
                None, {"named": {"_0": "future-unknown-icon"}}]
    require([tab.get("iconOverride") for tab in tabs] == expected and all("customIcon" not in tab for tab in tabs),
            "tab import did not retain typed icons, omit empty emoji, or preserve unknown named icon")
    matches(r"^roundtrip OK$", run(cli, "roundtrip", str(output)))
    print("tab icon import PASS: empty emoji omitted, typed icons retained, known/unknown named counters checked")


def folder_peek_import(cli):
    """FP11: real CLI import/roundtrip, only made-up Arc-shaped data."""
    import uuid
    def mapped(value):
        try:
            return str(uuid.UUID(value)).upper()
        except ValueError:
            seed = 'item:' + value
            def fnv(text, offset):
                for byte in text.encode(): offset = ((offset ^ byte) * 1099511628211) & ((1 << 64) - 1)
                return offset
            raw = bytearray(fnv(seed, 14695981039346656037).to_bytes(8, 'little') + fnv(seed[::-1], 1469598103934665603).to_bytes(8, 'little'))
            raw[6] = (raw[6] & 15) | 64; raw[8] = (raw[8] & 63) | 128
            return str(uuid.UUID(bytes=bytes(raw))).upper()
    ids = {k: str(uuid.uuid5(uuid.NAMESPACE_URL, 'synthetic-open-peek-' + k)).upper() for k in ('A','B','C','D','E','a','b1','b2','c','d','e')}
    ids['A'] = 'folder-peek-sentinel'
    items = []
    for name, children in [('A',['a']), ('B',['b1','b2']), ('C',['c']), ('D',['d']), ('E',['e'])]:
        items += [ids[name], {'id': ids[name], 'parentID': 'pinned-container', 'title': 'Synthetic ' + name,
                             'childrenIds': [ids[c] for c in children], 'data': {'list': {}}}]
        for child in children:
            items += [ids[child], {'id': ids[child], 'parentID': ids[name], 'childrenIds': [], 'createdAt': 0,
                                  'data': {'tab': {'savedURL': 'https://example.invalid/', 'savedTitle': 'Synthetic peek'}}}]
    items += ['pinned-container', {'id': 'pinned-container', 'childrenIds': [ids[c] for c in 'ABCDE'], 'data': {'itemContainer': {}}}]
    source = {'version': 1, 'sidebar': {'containers': [{'global': {}}, {'items': items,
              'spaces': ['peek-space', {'id': 'peek-space', 'title': 'Synthetic peek', 'profile': {'default': True},
                         'containerIDs': ['pinned', 'pinned-container'], 'customInfo': {}}], 'topAppsContainerIDs': []}]}}
    expansion = [ids['A'], {'peeked': {'_0': [ids['a']]}}, ids['B'], {'peeked': {'_0': [ids['e'],ids['b1'],ids['b2']]}},
                 ids['C'], {'peeked': {'_0': []}}, ids['D'], {'expanded': {}}]
    for variant in ('little', 'littleArc', 'no-standard', 'missing', 'unknown', 'invalid-direct'):
        directory = Path('peek-import-' + variant).resolve(); directory.mkdir()
        (directory / 'StorableSidebar.json').write_text(json.dumps(source))
        little = {'style': {variant if variant == 'littleArc' else 'little': {}}, 'expandedItems': [ids['D'], {'peeked': {'_0': [ids['d']]}}], 'spacesWithCollapsedPinnedSections': ['peek-space']}
        standard = {'style': {'standard': {}}, 'expandedItems': list(expansion), 'spacesWithCollapsedPinnedSections': []}
        if variant == 'unknown': standard['expandedItems'][1] = {'future': {}}
        if variant == 'invalid-direct': standard['expandedItems'][1] = {'peeked': {'_0': [ids['e'],'missing']}}
        if variant != 'missing':
            (directory / 'StorableWindows.json').write_text(json.dumps({'windows': [little] + ([] if variant == 'no-standard' else [standard])}))
        output = Path('peek-output-' + variant).resolve()
        report = run(cli, 'import-arc', '--arc-dir', str(directory), '--out', str(output), '--counts-only')
        data = json.loads((output / 'State/browser.json').read_text())
        folders = [node['folder']['_0'] for node in data['spaces'][0]['pinned']]
        require([f['id'] for f in folders] == [mapped(ids[k]) for k in 'ABCDE'], 'FP11 deterministic folder IDs')
        default = variant in ('missing','no-standard')
        for name, folder in zip('ABCDE', folders):
            expanded = default or name == 'D'
            peek = None if default or name not in 'AB' or (name == 'A' and variant in ('unknown','invalid-direct')) else mapped(ids['a' if name == 'A' else 'b1'])
            require(folder['isExpanded'] == expanded and folder.get('peekedChildID') == peek, 'FP11 ' + variant + ' folder ' + name)
        require(not data['spaces'][0]['isPinnedCollapsed'], 'FP11 Pinned state must also ignore first Little window')
        matches(r'collapsedFolders=' + ('0' if default else '4') + r'\b', report)
        matches(r'^roundtrip OK$', run(cli, 'roundtrip', str(output)))
    print('FP11 folder peek import PASS: 6 synthetic variants, standard window, direct-child map, deterministic IDs and roundtrip')


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
    print("A11")
    directory = save_snapshot(data)
    matches(r"^roundtrip OK$", run(cli, "roundtrip", directory))
    matches(r"commands-demo OK: [1-9]\d* checks passed, 0 failed", run(cli, "commands-demo", directory))

    for address in ("2001:db8::1", "2001:db8::99"):
        for spelling in (address, "[" + address + "]"):
            case("A12 IPv6 host is not a host-rule name", "https://[" + address + "]/docs", "littleOpen",
                 [rule("hostEquals", spelling, space), rule("hostContains", spelling, space)])
    prefix = rule("urlPrefix", "https://[2001:db8::1]/docs", space)
    case("A12 IPv6 prefix exact", "https://[2001:db8::1]/docs/a", "space:" + target, [prefix])
    case("A12 IPv6 prefix distinct address", "https://[2001:db8::99]/docs/a", "littleOpen", [prefix])
    case("A12 IPv6 prefix distinct port", "https://[2001:db8::1]:8443/docs/a", "littleOpen", [prefix])

    for pattern in ("münchen.de", "xn--mnchen-3ya.de"):
        for spelling in ("münchen.de", "xn--mnchen-3ya.de"):
            case("A13 IDN equivalence", "https://" + spelling + "/x", "space:" + target,
                 [rule("hostEquals", pattern, space)])
    case("A13 IDN prefix", "https://münchen.de/docs/a", "space:" + target,
         [rule("urlPrefix", "xn--mnchen-3ya.de/docs", space)])

    print("A14 one-way legacy migration")
    data["routingRules"] = [rule("hostEquals", "legacy.example", {"littleArc": {}})]
    data["defaultDestination"] = {"littleArc": {}}
    directory = save_snapshot(data)
    run(cli, "route", directory, "https://legacy.example/", "--expect-destination", "littleOpen", "--external-little-open", "on")
    matches(r"^roundtrip OK$", run(cli, "roundtrip", directory))
    migrated = (Path(directory) / "State/browser.json").read_text()
    require('"littleArc"' not in migrated and '"littleOpen"' in migrated, "A14 legacy spelling survived save")
    run(cli, "route", directory, "https://legacy.example/", "--expect-destination", "littleOpen", "--external-little-open", "on")
    data["defaultDestination"] = little

    for scheme, port in (("https", "443"), ("http", "80")):
        prefix = rule("urlPrefix", "example.com:" + port + "/docs", space)
        case("A15 omitted default port", scheme + "://example.com/docs/a", "space:" + target, [prefix])
        case("A15 explicit default port", scheme + "://example.com:" + port + "/docs/a", "space:" + target, [prefix])
        case("A15 nondefault port", scheme + "://example.com:8443/docs/a", "littleOpen", [prefix])
    case("A15 preserved port", "https://example.com:8443/docs", "space:" + target,
         [rule("urlPrefix", "example.com:8443/docs", space)])
    for value, host in (("example.com:8080/docs", "example.com"), ("localhost:3000/x", "localhost"),
                        ("example.com:8080", "example.com"), ("localhost:3000", "localhost")):
        case("A16 bare authority with port", value, "space:" + target, [rule("hostEquals", host, space)])

    for window in data["windows"]:
        if window["style"] == "standard": window["focusedSpaceID"] = target
    for default, toggle, expected, via in ((space, "on", "space:" + target, "defaultDestination"),
        ({"mostRecentSpace": {}}, "on", "space:" + target, "defaultDestination"),
        (little, "on", "littleOpen", "defaultDestination"),
        (little, "off", "space:" + target, "defaultSuppressedByToggle"),
        ({"space": {"_0": "00000000-0000-0000-0000-000000000098"}}, "on", "space:" + target, "fallbackMissingSpace")):
        data["defaultDestination"] = default
        text = case("A17 skipped rule retains default reason", "https://example.com/", expected, [stale],
                    "--external-little-open", toggle, "--json")
        decision = json.loads(text)
        require(via in decision["via"], "A17 default reason changed after a skipped rule")
        if via == "fallbackMissingSpace":
            require(decision["via"][via]["requested"] == default["space"]["_0"], "A17 names the skipped rule instead of missing default")
    data["spaces"] = []; data["windows"] = []; data["defaultDestination"] = little
    decision = json.loads(run(cli, "route", save_snapshot(data), "https://example.com/", "--external-little-open", "off", "--json"))
    require("noSpaces" in decision["via"] and decision.get("resolved") is None, "A17 empty state did not report noSpaces")
    print("route A1-A17 passed")
    runpy.run_path(str(root / "tools/verification/routing_atc.py"))["route_atc"](
        cli, seed_snapshot(cli, seed), run, require, save_snapshot)


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
    # Valid PNG ancillary data reaches the encoded boundary without trailing junk.
    base = png()
    for size, expected in ((512 * 1024, 0), (512 * 1024 + 1, 1)):
        body = b"pad\0" + b"x" * (size - len(base) - 16)
        chunk = b"tEXt" + body
        image = base[:-12] + struct.pack(">I", len(body)) + chunk + struct.pack(">I", zlib.crc32(chunk)) + base[-12:]
        require(len(image) == size, "encoded boundary fixture size")
        Path("boundary.png").write_bytes(image)
        run(cli, "favicons", "ingest", "https://boundary.invalid/page", "--db", "boundary.sqlite3",
            "--file", "boundary.png", "--page-specific", "true", expected=expected, env=env)
    matches(r"ok=1 missing=0 failed=0 count=1", run(cli, "favicons", "stats", "--db", "boundary.sqlite3"))
    print("FV11 encoded input: accept 512 KiB, refuse 512 KiB + 1; stored image retained")
    # A valid SQLite file above the physical cap must be refused before open,
    # without a migration/VACUUM allocating temporary databases or a journal.
    oversized = Path("oversize.sqlite3")
    with sqlite3.connect(str(oversized)) as db:
        db.execute("CREATE TABLE padding(data BLOB)")
        db.execute("INSERT INTO padding VALUES(zeroblob(?))", (16 * 1024 * 1024,))
    db.close()
    original_size = oversized.stat().st_size
    require(original_size > 16 * 1024 * 1024, "database boundary fixture")
    Path("valid.png").write_bytes(png())
    run(cli, "favicons", "ingest", "https://boundary.invalid/page", "--db", str(oversized),
        "--file", "valid.png", expected=1, env=env)
    require(oversized.stat().st_size == original_size, "oversize database was changed")
    require(not list(Path('.').glob('oversize.sqlite3-*')), "oversize database created sidecars")
    print("FV12 existing database above 16 MiB refused without writes or sidecars")
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
        # Archive is per Profile. The import report totals every store; the
        # archive-list default alone cannot prove that total after a real
        # multi-Profile import. Keep private IDs/names out of the receipt.
        profile_refs = [None]
        usage = run(cli, quiet=True, expected=2)
        if re.search(r"[<|]profiles[|>]", usage):
            profiles = json.loads(run(cli, "profiles", output, "list", "--json", quiet=True))
            require(any(p["dataDirectoryName"] == "Default" for p in profiles), "missing Default Profile")
            profile_refs = [p["id"] for p in profiles]
            print("importedProfiles=" + str(len(profiles)))
        archive_rows = 0
        for profile_ref in profile_refs:
            selection = ("--profile", profile_ref) if profile_ref is not None else ()
            listed = run(cli, "archive-list", output, "--limit", "0", *selection, quiet=True)
            row = re.search(r"^archive rows total=(\d+) showing=0$", listed, re.MULTILINE)
            require(row is not None, "missing per-Profile Archive count")
            archive_rows += int(row[1])
        print(f"archive rows total={archive_rows} showing=0")
        print(f"archiveProfileStores={len(profile_refs)}")
        stored = re.search(r"storedTotal=(\d+)", text)
        if stored:
            require(archive_rows == int(stored[1]), "per-Profile Archive total differs from import report")
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
    if sys.argv[1] == "onscreen-suite":
        onscreen_suite(sys.argv[2:])
        return
    if sys.argv[1] == "server":
        serve(sys.argv[2], sys.argv[3])
        return
    name, root, seed = sys.argv[1:]
    root, seed = Path(root), Path(seed)
    cli = str(root / "Packages/OpenKit/.build/release/openkit")
    if name == "build":
        build(root)
    elif name == "verify-secrets-fixture":
        for args in [[], ["--stop-after", "logins"], ["--stop-after", "webData"], ["--stop-after", "cookies"]]:
            text = run(cli, name, *args)
            require("FAIL" not in text and "PASS final counts without duplicates" in text, "secrets fixture expectations")
        run(sys.executable, str(root / "tools/verification/secrets-consent.py"), str(root))
        source = Path("synthetic-arc").resolve()
        profile = source / "Default"
        profile.mkdir(parents=True, mode=0o700)
        with sqlite3.connect(profile / "Login Data") as db:
            db.execute("CREATE TABLE logins(blacklisted_by_user INTEGER)")
        text = run(cli, "import-arc-secrets", "--arc-user-data", str(source), "--dry-run")
        require("keychain: not requested" in text and "stored=0" in text and "logins rows=0" in text,
                "empty dry-run stays outside Keychain")
        run(cli, "import-arc-secrets", "--arc-user-data", str(source), expected=3)
        run(cli, "verify-secrets-fixture", "--stop-after", "invalid", expected=2)
    elif name == "commands-demo":
        directory = Path("data").resolve()
        text = run(cli, name, str(directory))
        matches(r"commands-demo OK: [1-9]\d* checks passed, 0 failed", text)
        # Copy URL without trackers over the real library (page-platform §8.2): 30 fixed rows.
        matches(r"^url-clean: 30 passed, 0 failed$", run(cli, "url-clean"))
        shutil.copytree(directory, seed, dirs_exist_ok=True)
        archive_migration(cli)
        folder_peek_import(cli)
    elif name == "space-legacy":
        legacy_space_fixture(cli, root)
        space_icon_import(cli)
    elif name == "space-editor":
        # The icon-picker checks send native events to real windows. Use the
        # existing screen worker so another suite cannot take their focus.
        all_passed(run(sys.executable, str(Path(__file__).resolve()), "onscreen-suite",
                       str(root / "Packages/OpenKit/.build/release/space-editor-render"), "check",
                       timeout=None, interrupted_exit=2))
    elif name == "space-pad-compare":
        text = run(sys.executable, str(root / "tools/verification/space-pad-compare.py"))
        matches(r"session2-pad: [1-9]\d* gate rows PASS", text)
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
        # Every Settings preview launch takes the shared screen lock.
        locked = [sys.executable, str(Path(__file__).resolve()), "onscreen-suite", preview]
        all_passed(run(*locked, "check", timeout=None, interrupted_exit=2))
        output = Path("settings-panes").resolve()
        rendered = run(*locked, "render", "--out", str(output), timeout=None, interrupted_exit=2)
        require("PREVIEWS-CONTROLS delay=absent popups=0 expected-labels=present" in rendered,
                "missing rendered Previews control evidence")
        dump = run(*locked, "dump-keys", "--root", str(output / "fixture"), timeout=None, interrupted_exit=2)
        require("snapshot profile Personal searchEngineID = google" in dump, "missing settings store receipt")
        require(not any(line.startswith("default open.general.previewsDelaySeconds =") for line in dump.splitlines()),
                "removed preview delay default was registered")
        pngs = sorted(output.glob("*.png"))
        # The populated and empty Boosts section each add 1x and 2x renders.
        require(len(pngs) == 240, "missing settings/library/appearance/detail/sheet/state renders")
        require({f"library-boosts{state}@{scale}x.png" for state in ("", "-empty") for scale in (1, 2)} <= {p.name for p in pngs},
                "missing Library Boosts renders")
        require({f"sheet-link-rule-profile-work@{scale}x.png" for scale in (1, 2)} <= {p.name for p in pngs},
                "missing two-Profile destination renders")
        require({f"{state}@{scale}x.png" for state in
                 ("profile-icons", "profile-delete-disabled", "profile-delete-enabled", "profile-delete-unused")
                 for scale in (1, 2)} <= {p.name for p in pngs}, "missing Profile icon/deletion renders")
        require({"library-spaces@1x.png", "library-spaces@2x.png"} <= {p.name for p in pngs}, "missing Library Spaces renders")
        require({f"shortcuts-extension-conflicts-{appearance}@{scale}x.png" for appearance in ("light", "dark") for scale in (1, 2)} <= {p.name for p in pngs},
                "missing extension shortcut conflict renders")
        # Essential Keyboard Shortcuts window (commandbar-completion Step 6): light, dark, and a custom key.
        require({f"essential-shortcuts-{n}@{s}x.png" for n in ("light", "dark", "custom-key") for s in (1, 2)} <= {p.name for p in pngs},
                "missing Essential Keyboard Shortcuts renders")
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
                      "adblock": (600, 560), "link-rule": (520, 380), "link-rule-invalid": (520, 380), "link-rule-profile-work": (520, 380), "suggestion-notice": (400, 180), "search-engine-edit": (520, 540), "profile-create": (440, 330),
                      "profile-rename": (440, 180), "archive-scope": (500, 160)}
            expected = (440, 384) if png.name.startswith("essential-shortcuts-") else (560, 520) if png.name.startswith("first-run-") else ((960, 640) if png.name.startswith("library-") else ((640, 520) if png.name.startswith("import-") else (sheets[png.name.split("@")[0][6:]] if png.name.startswith("sheet-") else (684, 650))))
            expected = {"profile-delete-disabled": (508, 310), "profile-delete-enabled": (508, 310),
                        "profile-delete-unused": (508, 360)}.get(png.name.split("@")[0], expected)
            require(data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == tuple(n * scale for n in expected), "bad pane dimensions: " + png.name)
    elif name == "extensions-render":
        renderer = str(root / "Packages/OpenKit/.build/release/extensions-render")
        for scale in (1, 2):
            for appearance in ("light", "dark"):
                run(renderer, "all", "--scale", str(scale), "--appearance", appearance,
                    "--out", str(Path("extensions-renders") / f"{appearance}-{scale}x"))
        text = run(renderer, "check")
        matches(r"extensions-render check: [1-9]\d* passed, 0 failed", text)
        require(not re.search(r"^FAIL\b", text, re.MULTILINE), "extensions check failure")
        run(renderer, "menus", "--out", str(Path("extensions-menus")))
    elif name == "onboarding-render":
        run(sys.executable, str(root / "tools/generate-intro-sound.py"), "--check")
        decoded = json.loads(run(str(root / "Packages/OpenKit/.build/release/onboarding-render"), "--check-sound"))
        require(decoded["ok"], "committed intro failed decoded PCM curve comparison")
    elif name == "features-render":
        run("python3", str(root / "tools/generate-sounds.py"), "--check")
        text = run(str(root / "Packages/OpenKit/.build/release/features-render"), "check")
        matches(r"features-render check: [1-9]\d* passed, 0 failed", text)
        idle = run(sys.executable, str(root / "tools/verification/features-idle.py"))
        matches(r"features-render idle check: [1-9]\d* passed, 0 failed", idle)
        require("SE1 capture" in text and "SE1 event" in text and "SE2 disabled" in text and "SE3 enabled" in text, "missing sound flow receipts")
    elif name in ("sidebar-render", "commandbar-render", "sitecontrol-render"):
        command = [str(root / "Packages/OpenKit/.build/release" / name), "check"]
        if name == "sitecontrol-render":
            # This CLI opens real native menus. Serialize that suite, while the
            # release build and wholly offscreen checks need no on-screen lock.
            # Lock queue time is not suite execution time. The inner worker owns
            # the unchanged deadline and releases its lock after reaping children.
            # The worker acquires the shared flock itself. A group signal
            # cannot kill a separate lock wrapper and unlock before cleanup.
            command = [sys.executable, str(Path(__file__).resolve()), "onscreen-suite", *command]
            all_passed(run(*command, timeout=None, interrupted_exit=2))
        else:
            all_passed(run(*command))
        if name == "sidebar-render":
            if os.environ.get("SIDEBAR_FOLDER_PEEK_PERF") == "1":
                bench = run(str(root / "tools/verification/folder-peek-bench.py"))
                matches(r"^FP10 PASS$", bench)
            else:
                print("FP10 separate performance gate: run heavy.sh tools/verification/folder-peek-bench.py; set SIDEBAR_FOLDER_PEEK_PERF=1 for this strict dispatcher gate")
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
    except SuiteInterrupted as error:
        print("INTERRUPTED: " + str(error), file=sys.stderr)
        sys.exit(2)
    except Exception as error:
        # No exception text for private imports: exceptions can contain personal paths/data.
        detail = "private import failed (raw output discarded)" if sys.argv[1] == "import-arc" else str(error)
        print("FAIL: " + detail, file=sys.stderr)
        sys.exit(1)
