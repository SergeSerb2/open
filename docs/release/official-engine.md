# Official engine: overnight runbook

This is a preparation report. No engine build or engine-tree status check ran.
No engine file changed. Only repo patch-plan validation ran as a fork script.
The commands below are for the lead and engine owner.
The lead must clear the stop gates before starting them.

Checked on 2026-11-07, about 18:09–18:16 America/Vancouver.
The repo snapshot is main `e64cbdeb28b1c07119e5d1fe31665281a5ed07bf`.
Recheck the inputs against the main commit selected for the release.

## Preconditions checked now

| Input | Result and evidence |
|---|---|
| Build root | **Lead decision pending.** Recommend a new APFS clone at `~/Developer/open-engine-s16-official`. Use a full source root certified against the selected main commit. Keep the existing roots intact. `ls -la ~/Developer/open-engine-s8-main` and its `README.txt` confirm that it is a **distribution-only view**, with no build tree or depot_tools. Do not clone that view for a build. |
| Source candidate | `~/Developer/open-engine-s8` contains all 23 main patch records, but also three Section 12 records. Its `applied.json` lists 26 patches and 59 overlays. This main snapshot has 23 active patches and 53 overlay files. The extra records are `chromium/0601-open-script-world.patch`, `cef/0601-open-script-world.patch`, and `cef/0602-open-browser-extra-info.patch`. It is not certified as exact main. These results come from `cat .open-engine-state/applied.json` and a set comparison with the three repo `series` files. |
| Main distribution | The view's `README.txt` records main `ca56dff3` (#223), from `open-engine-s10`, at 17:20. Framework SHA-256: `c03a5109fc0d815770743a6c25a92d24bd1632eba6e658e00eb6e46314440c91`. Its distribution README contains both pinned source commits. The source root `open-engine-s10` was **not inspected**; it is outside this research lane. The lead can ask its owner to certify it as an alternative clone source. |
| Source pins | `VERSIONS` pins Chromium `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`, CEF `4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f`, arm64, and 10 jobs. The s8 `applied.json` records those two source pins. This is state evidence, not a fresh Git pin proof. No Git command ran in an engine root. |
| Field trials | **PASS in checked-in inputs.** `disable_fieldtrial_testing_config=true` is in `gn/dev.args.gn` and the s8 dev output's `args.gn`. Release inherits it. The short list in release.md §2.1 omits this line, but its following rule requires it. There is no missing-fieldtrial drift in the files. |
| PGO | **STOP.** s8's `chrome/build/pgo_profiles/` is absent. Its `.gclient` has `checkout_pgo_profiles: False`. Both conditions fail the gate in `engine-build`. See the exact profile name below. No official clone was certified in this task, so its PGO state remains unverified. |
| Existing output size | `du -sh …/open-engine-s8/chromium_git/chromium/src/out/Release_GN_arm64` reports **8.1 GiB allocated**. `du -A -sh` reports **7.8 GiB apparent**. These are directory measurements, not unique APFS block ownership. No `Release_Official_arm64` directory was listed in s8. |
| Additional disk estimate | Allow **80–150 GiB of new free blocks** for planning. Estimate: 3–5 × the 8.1 GiB dev output for official objects and symbols (24–41 GiB), 40–80 GiB for ThinLTO/cache/link scratch, and 10–20 GiB for distribution and symbol copies; round the total. This is an unmeasured allowance, not a known minimum. It excludes an unshared source checkout or an unbounded cache. APFS cloning does not reserve future writes. |
| Free disk now | `df -h ~/Developer/open-engine-s8`: `/dev/disk3s5`, mounted at `/System/Volumes/Data`, **926 GiB size, 831 GiB used, 65 GiB available, 93%**. Disk is user-managed. This report makes no disk decision and deletes nothing. |
| Packaging | **STOP before distribution.** `engine-distrib` rejects release before its dry-run branch. `make_distrib.py:775–782,898,920–934` selects `_GN_arm64` and reads `out/Release_GN_arm64`. S10-3 is still required. |
| A-1 status | **Fixed 2026-11-12.** `engine-status --config release` checks `OUT_DIR_RELEASE`, and S-5 compares its args with merged dev + release args (as `engine-build` writes them). It ignores only the build-execution key `use_remoteexec`. `release.sh` calls it with `--strict`. Dry run on the M5 with the official engine: A-1 PASS. |

The source root must be frozen by its owner before cloning. The latest main
view came from s10; s8 is the source root examined here. The lead must select
an exact source snapshot, or reconcile only a disposable clone to main.
Do not remove Section 12 work from its owned root. `engine-apply` adds work;
it does not remove extra patches or stale overlays.

Certify the selected clone as follows, before the official build:

1. Freeze the repo commit. Record hashes of `VERSIONS`, every `series`,
   every `manifest`, every active patch, and every overlay file.
2. Compare `applied.json` pins and its active patch keys with that commit's
   `Engine/fork/patches/{chromium,cef,rust}/series`. Require equal sets,
   not just the same count. Validate one `manifest` block per active patch.
3. Have the engine owner run `engine-status --strict` against the clone
   while its dev output still uses dev args. Require S-1…S-8 PASS.
   Its S-3 reverse checks prove the selected patches are present. S-4
   checks overlay bytes and reports stale files. Review the owner's source
   diff inventory too: S-3 alone cannot exclude an extra source edit.
4. Save the certificate, source commit, patch/overlay hashes, and logs
   outside the engine tree. A copied `applied.json` alone is not proof.
   After S10-3, repeat certification against main plus the reviewed S10 patch.

The exact published PGO filename in s8's `chrome/build/mac-arm.pgo.txt` is:

```text
chrome-mac-arm-8078-1791925243-b77c87a12380c6212a5d36737d1c76576eaaa85d-8bf8e95f3aaaafc23171beddc0ee3f397abd1e12.profdata
```

The owner must enable `checkout_pgo_profiles=True` in the selected clone's
`.gclient` and fetch the revision-matched published profile. The pinned
`DEPS:4806–4814` hook uses `tools/update_pgo_profiles.py --target=mac-arm
update --gs-url-base=chromium-optimization-profiles/pgo_profiles`.
Use the owner's approved hook procedure. Do not sync or update source pins.
Check the named file under `chrome/build/pgo_profiles/` again afterward.
The research task did not run that hook, bootstrap, or gclient.

On failure, preserve this exact build gate message:

```text
release: no PGO profile found; set chrome_pgo_phase=0 explicitly in gn/release.args.gn or add the profile
```

The phase-0 suggestion in that message is not release permission.

## Effective release args

This is the complete assignment list from dev, then release, with the last
assignment for each key retained. It is sorted by key. `engine-build`
inserts a newline between the files because dev has no final newline.
These are explicit inputs, not a dump of all GN defaults.

```gn
alternate_cdm_storage_id_key="968b476909da4373b08903c28e859454"
blink_symbol_level=0
chrome_pgo_phase=2
clang_use_chrome_plugins=false
dcheck_always_on=false
disable_fieldtrial_testing_config=true
enable_background_mode=false
enable_cdm_host_verification=true
enable_cdm_storage_id=true
enable_downgrade_processing=false
enable_precompiled_headers=false
enable_resource_allowlist_generation=false
enable_rlz=true
enable_widevine=false
ffmpeg_branding="Chrome"
forbid_non_component_debug_builds=false
is_component_build=false
is_debug=false
is_official_build=true
optimize_webui=true
proprietary_codecs=true
symbol_level=1
target_cpu="arm64"
thin_lto_enable_optimizations=true
treat_warnings_as_errors=false
use_thin_lto=true
v8_symbol_level=0
```

Release.md §2.1 prints 15 of these values. The other 12 are inherited dev
values, including the required fieldtrial switch. Fork-infra §5.2 still
shows `enable_widevine=true`; the checked-in release file and the later
release decision correctly set it to **false**. Do not copy the older list.

## Time allowance at 10 jobs

| Real receipt | Time | Meaning |
|---|---|---|
| `~/Library/Caches/OpenRE/s8/build-check.log`, 2026-11-02 | **8,374 s = 2 h 19 m 34 s**, exit 0. Start load **7.95 / 7.37 / 6.61**. End load was not recorded. | Build after moving an APFS-cloned source root. `engine-build` used its default 10 jobs. Its summary matches `s8/logs/engine-build.log:203–205`. It is a dev-build baseline, not an official-build timing. |
| `08-engine-basics-done.md`, engine-state row | **37 s**, incremental, 2026-11-05 | Already-built dev tree. No load in this receipt. It cannot predict a first official build. |
| s8 `logs/engine-build.log`, 2026-11-05/06 Section 6 work | **158 s** (P3-era), **28 s** (notification guard), exit 0 | Incremental `cefsimple cefclient` builds. No load in these summary lines. The Section 6 done note identifies the corresponding distribution revisions. |

Estimate the first official `cefsimple` at **5–7 hours**. This uses an
explicit **2–3×** ThinLTO/PGO factor on the 2.33-hour moved-tree baseline.
Reserve **8–10 hours** for the build window, including a possible long link.
This factor is a planning assumption. No official timing receipt was found.
A cold cache, new GN graph, symbols, or memory pressure can take longer.
Allow another **15–60 minutes** for `cefclient` and packaging after the proof.
Do not extrapolate from the 28–158 s incremental receipts.

## Lead setup and detached launcher

Use a dedicated **release repo checkout** for this work. Its `Vendor/cef`
must not be shared with dev App work. `fetch-engine.sh` has no destination
flag; its destination is the checkout's `Vendor/cef`. It uses `rsync --delete`.
Keep that checkout at the certified release commit plus reviewed fixes.

Run the following setup in Bash after the lead selects and prepares the
full engine clone. It creates only the lead's local run files. Replace the
repo path with the dedicated release checkout. Do not use the main view as
`OPEN_ENGINE_ROOT` for these release commands.

```bash
export REPO=/absolute/path/to/release-checkout
export OPEN_ENGINE_ROOT="$HOME/Developer/open-engine-s16-official"
export SRC="$OPEN_ENGINE_ROOT/chromium_git/chromium/src"
export OUT="$SRC/out/Release_Official_arm64"
export OFFICIAL_RUN="$REPO/.re/s16/official-engine-run"
export OPEN_RELEASE_HEAVY_WRAPPER=/Users/serge/.t3/projects/open/.re/handoff/sections/s16/s16-heavy.sh
unset OPEN_ENGINE_LOCK_OWNER OPEN_ENGINE_LOCK_HANDOFF OPEN_ENGINE_DETACHED
cd "$REPO"
mkdir -p "$OFFICIAL_RUN"
cat > "$OFFICIAL_RUN/job.py" <<'PY'
import os, pathlib, subprocess, sys, time
if sys.argv[1] == '--worker':
    log = pathlib.Path(sys.argv[2])
    print('START', time.strftime('%Y-%m-%dT%H:%M:%S%z'), flush=True)
    subprocess.run(['/usr/bin/uptime'], check=False)
    try:
        rc = subprocess.call(sys.argv[3:])
    except OSError as error:
        print(error, flush=True)
        rc = 127
    subprocess.run(['/usr/bin/uptime'], check=False)
    print('END exit=' + str(rc), flush=True)
    log.with_suffix('.exit').write_text(str(rc) + '\n')
    sys.exit(rc)
run = pathlib.Path(os.environ['OFFICIAL_RUN'])
step, *command = sys.argv[1:]
log = run / (step + '-' + time.strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()) + '.log')
argv = [sys.executable, __file__, '--worker', str(log),
        '/usr/bin/lockf', '-k', '/tmp/open-engine-build.lock', *command]
with log.open('xb', buffering=0) as stream:
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stream,
                             stderr=subprocess.STDOUT, start_new_session=True,
                             cwd=os.environ['REPO'])
print('pid=' + str(child.pid), 'log=' + str(log), 'exit=' + str(log.with_suffix('.exit')))
PY
official_job() { python3 "$OFFICIAL_RUN/job.py" "$@"; }
```

Every `official_job` below starts a new session and holds the persistent
machine engine lock until the real command exits. The launcher prints the
exact log, PID, and `.exit` path. A missing `.exit` means **not completed**;
check that PID and the log. A launcher's exit 0 means only that it started.
Wait for the worker's `.exit` and inspect its log before the next step.
Never queue these steps together. Never put `engine-build --detach` inside
this wrapper: its parent would release the outer machine lock too early.

`engine-build` already uses `caffeinate -dimsu nice -n 10 autoninja … -j 10`.
Do not add another `nice` around that script. Do not raise the job count.
The Section 16 token wrapper schedules the App work inside `release.sh`.
No heavy slot is needed for these engine scripts under the current rules.
Coordinate the overnight window with all engine owners. Build work does
not take the timing quiet lock. Record the load with every receipt.

### A. Official cefsimple proof

Only after root, patch, fieldtrial, and PGO preconditions pass:

```bash
official_job 01-build Engine/fork/scripts/engine-build --config release --target cefsimple --jobs 10
```

This is the one-line overnight start command after setup.
Expected time: 5–7 hours; reserve 8–10 hours.
Logs: `$OFFICIAL_RUN/01-build-*.log`, plus
`$OPEN_ENGINE_ROOT/logs/build-release-<date>-<unique>.log` and `engine-build.log`.
Require worker exit 0 and `build summary: config=release … exit=0`.
Require `$OUT/cefsimple.app/Contents/MacOS/cefsimple`, not `$OUT/cefsimple`.
For the first build it must be newer than the build start. Check the
generated args against the merged list, not just the summary label.

**Resume:** repeat the same command on unchanged inputs. Ninja reuses its
completed outputs. Keep `args.gn`, build graph, objects, caches and logs.
The script leaves existing args unchanged unless `--regen` is explicit.
Use `--regen` only after reviewing an input change; it can trigger a large
rebuild. The PGO gate runs even when args already exist. Do not clean.

### B. cefsimple smoke

Use the release output, never a dev sample. This is the raw CEF sample;
do not launch a re-signed Open.app or anything from a DMG on the M5.
Check `/tmp/open-onscreen-priority` first. If another live priority flag
exists, follow TANDEM §3.4a before launching this one smoke suite.
Run no build at the same time. The launcher takes the engine lock first;
the command takes the screen lock next.

Save the following as `$OFFICIAL_RUN/smoke.py`:

```python
import json, os, pathlib, signal, socket, subprocess, time, urllib.request
out = pathlib.Path(os.environ['OUT'])
run = pathlib.Path(os.environ['OFFICIAL_RUN'])
exe = out / 'cefsimple.app/Contents/MacOS/cefsimple'
profile = run / 'cefsimple-profile'
profile.mkdir(exist_ok=True)
for attempt in (1, 2):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    stderr = run / ('cefsimple-' + str(attempt) + '-' + str(time.time_ns()) + '.log')
    with stderr.open('wb') as stream:
        proc = subprocess.Popen([str(exe), '--url=https://example.com',
            '--use-mock-keychain', '--user-data-dir=' + str(profile),
            '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=' + str(port),
            '--enable-logging=stderr', '--v=0'], stdout=stream, stderr=stream,
            start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            title = False
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError('cefsimple exited early: ' + str(proc.returncode))
                try:
                    with urllib.request.urlopen('http://127.0.0.1:' + str(port) + '/json/list', timeout=1) as response:
                        title |= any(p.get('title') == 'Example Domain' and
                                     p.get('url', '').startswith('https://example.com')
                                     for p in json.load(response))
                except (OSError, ValueError):
                    pass
                time.sleep(0.2)
            if proc.poll() is not None or not title:
                raise RuntimeError('alive at 10 s and loaded title required')
        finally:
            if proc.poll() is None:
                proc.terminate()
            try:
                rc = proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise RuntimeError('shutdown timeout')
            # Only this launch's process group. Never kill another sample.
            try:
                os.killpg(proc.pid, 0)
            except ProcessLookupError:
                pass
            else:
                os.killpg(proc.pid, signal.SIGKILL)
                raise RuntimeError('sample left child processes')
    text = stderr.read_text(errors='replace')
    if rc not in (0, -signal.SIGTERM):
        raise RuntimeError('unexpected shutdown: ' + str(rc))
    if any(s in text for s in ('FATAL', 'Check failed', 'sandbox_extension', 'GPU process launch failed')):
        raise RuntimeError('sample stderr failure: ' + str(stderr))
    print('smoke', attempt, 'PASS: alive 10 s; Example Domain; clean owned shutdown;', stderr)
print('SMOKE A PASS')
```

Then run:

```bash
official_job 02-smoke /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock /usr/bin/nice -n 10 python3 "$OFFICIAL_RUN/smoke.py"
```

Time: about 20–60 seconds, plus screen-lock wait.
Log: `$OFFICIAL_RUN/02-smoke-*.log` and the printed sample stderr paths.
Require exit 0 and `SMOKE A PASS`. No desktop input is used.
The two launches use the same private profile and separate local ports.
**Resume:** after an ordinary interruption, confirm no owned sample remains,
then repeat both launches with this profile. Keep the stderr evidence.
If there is a crash or loader failure, stop. Report it to the lead. Do not
repeat a failed-to-load launch or dismiss a dialog.

### C. S10-3 patch round trip: proposal only

Do this after proof build and smoke PASS. The current gate message is:

```text
release packaging not wired yet: CEF's make_distrib expects out/Release_GN_arm64; see docs/plans/fork-infra.md Step 10
```

The lead records the old gate with these two separate jobs. Each should
exit 1 before build or packaging. Even `--dry-run` hits the current gate.

```bash
official_job 03-old-dry Engine/fork/scripts/engine-distrib --config release --dry-run
official_job 03-old-gate Engine/fork/scripts/engine-distrib --config release --run
```

Review each completion before starting the next. These take seconds.
Preserve their `$OFFICIAL_RUN/03-old-*.log` files for the packaging PR.

Proposed source change, against the inspected CEF 8078 file:

```diff
diff --git a/cef/tools/make_distrib.py b/cef/tools/make_distrib.py
--- a/cef/tools/make_distrib.py
+++ b/cef/tools/make_distrib.py
@@ -898,4 +898,6 @@
   platform_arch, binary_arch, build_dir_suffix = get_architecture(options)
+  build_dir_suffix = os.environ.get('OPEN_CEF_BUILD_DIR_SUFFIX',
+                                   build_dir_suffix)
   mode = get_distribution_mode(options)
   output_dir_base, output_dir_name = get_output_name(
       cef_ver, platform, platform_arch, mode, options)
```

`os` is already imported. No other logic changes. When the variable is
unset, the selected suffix and package contents remain byte-identical to
the old path. No timestamp or output-name behavior changes. When it is
`_Official_arm64`, the existing lines 922–923 select both
`out/Debug_Official_arm64` and `out/Release_Official_arm64`. Require a real
unset-variable dev packaging control, using saved inputs, in the S10 PR.
Compare file contents with the same generated metadata; do not treat a
different packaging date as an env-variable effect. This report claims no
runtime or byte-identity proof.

The proposed repo patch name is `cef/0106-release-distrib-output.patch`.
It is unused in this snapshot. Recheck ownership and numbering first.
Save the diff above as `$OFFICIAL_RUN/s10-proposal.diff`, not as a repo
patch. The fork workflow generates the committed patch from the tree.

Save this metadata edit as `$OFFICIAL_RUN/register-s10.py`. It inserts the
new series entry in numeric order, as strict S-8 requires. It refuses a
second registration.

```python
import pathlib
base = pathlib.Path('Engine/fork/patches/cef')
name = '0106-release-distrib-output.patch'
series = (base / 'series').read_text()
manifest = (base / 'manifest').read_text()
if name in series or name in manifest:
    raise RuntimeError('already registered; inspect state')
series_anchor = '\n0302-open-hosted-tabs.patch'
manifest_anchor = '# 0302-open-hosted-tabs.patch\n'
if series.count(series_anchor) != 1 or manifest.count(manifest_anchor) != 1:
    raise RuntimeError('metadata anchor changed; review before editing')
series = series.replace(series_anchor, '\n' + name +
    '  # S10-3: select the official distribution input via an environment suffix' + series_anchor, 1)
manifest = manifest.replace(manifest_anchor, '# ' + name +
    '\npaths: cef/tools/make_distrib.py\n' + manifest_anchor, 1)
(base / 'series').write_text(series)
(base / 'manifest').write_text(manifest)
```

Run these jobs one at a time, with review between them:

```bash
official_job 03-edit /bin/bash -eu -c 'cp "$SRC/cef/tools/make_distrib.py" "$OFFICIAL_RUN/make_distrib.before.py"; patch -d "$SRC" -p1 < "$OFFICIAL_RUN/s10-proposal.diff"; cp "$SRC/cef/tools/make_distrib.py" "$OFFICIAL_RUN/make_distrib.after.py"'
official_job 03-manifest python3 "$OFFICIAL_RUN/register-s10.py"
official_job 03-refresh Engine/fork/scripts/engine-refresh-patches --series cef
```

Read the generated patch **in full**. Require only the two added source
lines above, and no unintended changes to existing patches. Do not hand
edit its hunks. Save the repo diff. Then restore only the saved pre-edit
file and prove the round trip:

```bash
official_job 03-revert /bin/cp "$OFFICIAL_RUN/make_distrib.before.py" "$SRC/cef/tools/make_distrib.py"
official_job 03-apply Engine/fork/scripts/engine-apply --only cef
official_job 03-roundtrip /usr/bin/cmp "$OFFICIAL_RUN/make_distrib.after.py" "$SRC/cef/tools/make_distrib.py"
```

Logs: `$OFFICIAL_RUN/03-*.log`, `logs/engine-refresh-patches.log`, and
`logs/engine-apply.log`. Expect `refreshed: cef/0106-…`, then `applied: …`
or `already applied: …`, and an exit-0 byte comparison. Time: about
5–15 minutes for review and commands; no compile is needed for this Python
packager edit. A second apply must report no newly applied patch.

Also prepare the repo script wiring as part of the **separate S10 PR**.
Replace the release `die` in `engine-distrib` with:

```bash
if [[ "$config" == release ]]; then
    export OPEN_CEF_BUILD_DIR_SUFFIX=_Official_arm64
else
    unset OPEN_CEF_BUILD_DIR_SUFFIX
fi
```

Keep its shared lock, `cefsimple cefclient` build, output fingerprint,
single-updated-child discovery, atomic `distrib.txt` write, and stamps.
The present script calls `make_distrib.py --minimal --no-symbols --no-docs
--no-archive` directly. Release.md §2.6 still describes an automate flow.
The later Phase B receipt in `docs/engine-fork.md` explains this drift:
automate did not pass `--no-symbols` for minimal output. Recommend keeping
the proven direct call and documenting that decision in the S10 PR.
Do not silently switch back to automate or patch its external source.
If the lead requires automate, prove its `--no-build` behavior first and
stop if it still reads the wrong output. The direct call needs `cefclient`;
`cefsimple` alone cannot supply the packaged framework.

**Resume:** read the saved before/after files and current repo diff first.
Do not repeat `03-edit` or `03-manifest` blindly: patch application and
metadata registration are not idempotent. Refresh is repeatable on unchanged
source. Apply is idempotent. Keep all conflict reports, `.rej`, `.orig`,
and state files until the owner resolves the cause. Never reset the whole
engine tree or delete a patch to make the gate pass.

### D. Official distribution

Only after the S10 source patch and script wiring are reviewed and present:

```bash
official_job 04-distrib Engine/fork/scripts/engine-distrib --config release --run
```

Allow 15–60 minutes for the extra `cefclient` target, link and copy.
The nested build uses the pinned default of 10 jobs and `nice -n 10`.
Do not pass `--skip-build` on the first run. Log:
`$OFFICIAL_RUN/04-distrib-*.log`, `logs/engine-distrib.log`, and a new
`logs/build-release-*.log`. Require exit 0, a release build summary,
`distribution: <path>`, and exactly one updated distribution directory.
Its README pins must equal `VERSIONS`. Its framework must hash equal to
the framework in `$OUT/cefclient.app/Contents/Frameworks/…`, not a dev file.
Record `du -sh` of the distribution and framework.

**Resume:** rerun on unchanged inputs. `distrib-release.done` is a
fingerprint of the pins and built outputs. A match plus a valid recorded
path skips packaging with `already up to date`. `distrib.txt` is the
selected absolute path; it is not an official-build certificate. A cloned
state file may still point into the source root until this step succeeds.
Do not use that old pointer for the release fetch. Dev and release can have
the same distribution directory name; isolation and binary hashes matter.
After interrupted packaging, keep the evidence and rerun the script. Do
not guess a candidate or manually write a successful stamp.

### E. Fetch into the release checkout

```bash
official_job 05-fetch /usr/bin/nice -n 10 tools/fetch-engine.sh --run
```

Allow 1–5 minutes. Log: `$OFFICIAL_RUN/05-fetch-*.log`.
Require exit 0 and `fetch-engine: <official recorded path> -> …/Vendor/cef`.
Require the fetched framework's SHA-256 to equal the official output and
the recorded distribution. The fetch validates that its source resolves
under this clone's `cef/binary_distrib/`. Check the repo status from the
repo checkout; the fetch must add no tracked file.
**Resume:** repeat the command. The directory copy is idempotent.
`rsync --delete` repairs a partial Vendor copy. Never point it at a dev
distribution or use another checkout's Vendor as the source.

### F. A-1 provenance through the release script

`release.sh` runs `engine-status --config release --strict`. S-5 compares the
official output's `args.gn` with the **merged dev + release args** that
`engine-build` writes (later keys win). It ignores build-execution-only keys
(`use_remoteexec`, which the remote build sets; it does not change any
compile command, `Engine/fork/remote/README.md`). Every other changed or
extra key fails under `--strict`. Dev mode (the default) is unchanged.

Then run the real release path:

```bash
official_job 06-provenance tools/release.sh --dry-run --skip-engine
```

Allow 5–20 minutes for App build and packaging, plus slot wait.
Logs: `$OFFICIAL_RUN/06-provenance-*.log` and
`build/release/<marketing>-<build>/release.log`.
Require `02-engine` PASS, `Official output/distrib SHA-256: …`, all strict
status rows PASS, Vendor equality, and **A-1 PASS** in
`.staging/acceptance.tsv`. A-1 `mode-SKIP` is a failed official proof.
`--skip-engine` skips the fetch, not the provenance checks. The engine
phase also archives symbols and fails if the archive is empty.

This command continues beyond A-1. It makes local ad-hoc artifacts.
Do not launch the exact artifact. It may exit 1 for missing M1 supplemental
smoke evidence in A-2/A-3/A-11. Report that separately from A-1. The M1
screen hold remains a separate lead gate. This runbook does not start an
M1 smoke, use credentials, or authorize release publication.

**Resume:** rerun with the same source, tools, engine and release version.
`release.sh` uses `.stamps/<phase>.stamp`, `.result`, and `.outputs` with
chained input/output hashes. It skips only matching work. Keep the staging
directory, logs, symbols, manifest and M1 receipts. Do not delete a stamp
to turn a real failure into a pass. A changed input must invalidate the
appropriate phase. Inspect the actual A-1 row even if another row fails.

### G. Keep a local symbol archive

Official args imply `enable_dsyms=true` and `enable_stripping=true` through
`build/config/apple/symbols.gni:11–24`. The symbol level stays at 1.
`--no-symbols` excludes symbols from the distribution; it does not replace
the archive. Archive them before any clean, including when step F stops.

Set `REL` to the same release directory that `release.sh` printed. Then:

```bash
export REL="$REPO/build/release/<marketing>-<build>"
official_job 07-symbols /bin/bash -eu -c '
mkdir -p "$REL/symbols"
while IFS= read -r -d "" d; do
  ditto "$d" "$REL/symbols/$(basename "$d")"
done < <(find "$OUT" -maxdepth 4 -name "*.dSYM" -type d -print0)
find "$OUT" -maxdepth 4 -name "*.sym" -type f -exec cp {} "$REL/symbols/" \;
test -n "$(find "$REL/symbols" -type f -print -quit)"
du -sh "$REL/symbols"
xcrun dwarfdump --uuid "$OUT/cefclient.app/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
find "$REL/symbols" -name "*.dSYM" -type d -exec xcrun dwarfdump --uuid {} \;
echo "SYMBOL ARCHIVE COPIED; compare framework and dSYM UUIDs"
'
```

Allow 1–10 minutes. Log: `$OFFICIAL_RUN/07-symbols-*.log`.
Require exit 0, a nonempty archive, and a matching framework dSYM UUID.
Use the actual flat/versioned framework path if the built layout differs.
Save the certified source/patch hashes and official framework hash beside
the archive. Keep each shipped build's symbols forever on local storage.
Never upload symbols or put them in Open.app or the DMG. Never run a second
`strip` pass. **Resume:** the copies are repeatable for the same exact
build. Preserve separate archives when the binary or build number changes.

## What the official build unlocks

The main view's distribution `CREDITS.html` is **401 bytes**, confirmed with
`stat -f '%N %z bytes' …/CREDITS.html`. The license inventory correctly says
**incomplete**. It contains a sample, not Chromium's dependency notices.

The pinned `components/resources/BUILD.gn:16–19` defaults
`generate_about_credits = is_official_build`. The merged args do not
override it, so an official build selects the real generation action.
Lines 158–188 run `tools/licenses/licenses.py credits` when true; the
false branch copies `sample_credits.html`. `components_resources` depends
on `:about_credits` (line 92), so this is a build dependency, not a separate
manual target. Expected generated file:

```text
out/Release_Official_arm64/gen/components/resources/about_credits.html
```

`make_distrib.py:925–934` copies it to the distribution's `CREDITS.html`.
After the suffix fix, require byte equality of those files, reject the
sample marker, and run the production credits requirement in the real
acknowledgements generator. A larger file alone does not prove completeness.
If license generation fails on a downstream dependency, stop and fix its
notice metadata. Do not turn the GN flag off. A real credits file unlocks
the exact-engine inventory audit; it does not clear U-6 or U-8 by itself.

The official engine also enables the first valid release size check.
Release.md §1 targets **app ≤300 MB and DMG ≤300 MB**, warns above 285 MB,
and fails above 320 MB. Treat 300–320 MB as a budget miss even if the script
does not hard-fail. Section 2.7 trims only locales from the committed
`tools/release-locales.txt` list, currently `en`. Require exactly `en.lproj`
in the initial release bundle. Record actual app and DMG sizes and the
framework, Resources, and Libraries breakdown. Do not reuse dev size
receipts as official acceptance. Keep SwiftShader and required data files.

## State and stop rules

- PGO missing or checkout disabled: stop before GN generation. Never ship
  `chrome_pgo_phase=0` as an official release.
- Root not certified, extra patch present, wrong pins, overlay drift, or
  fieldtrial switch missing: stop. The lead resolves ownership and inputs.
- Never copy dev output or a dev distribution into a release path. Never
  relabel a dev framework. The directory name and README pins alone do not
  prove official args. Keep output-to-distribution-to-Vendor hash evidence.
- Keep `.open-engine-state/applied.json`, `distrib*.done`, `distrib.txt`,
  GN args, build graph, caches, output, logs, and conflict evidence. Applied
  state is a history record; distribution state selects an artifact.
- `lock-writer/owner` contains a PID and operation. A named `lock-build`,
  `lock-distrib`, `lock-apply`, or `lock-refresh` accompanies it. If a crash
  leaves these directories, verify that the owner and its children stopped.
  Only the owner may remove the two stale lock directories by hand.
  Never delete a live lock or `/tmp/open-engine-build.lock`.
- If package discovery finds zero or multiple updated candidates, stop and
  inspect them. Do not bypass discovery by editing `distrib.txt`.
- If a build or smoke fails, keep the first failure. Do not auto-retry,
  raise jobs above 10, disable PGO/ThinLTO, or change performance thresholds.
- No source sync, engine rebuild, App launch, signing, key, notary, tag,
  upload, or publication happened for this document. The S10 patch and S-5
  fix remain proposals. This docs-only PR does not complete Step 10 or A-1.

Sources: [release plan §§1–2,9](../plans/release.md),
[fork-infra §§5.2,6.5,8,10.3 and Step 10](../plans/fork-infra.md),
[operator guide](../engine-fork.md), [follow-ups](../followups.md),
[license inventory](licenses.md), the scripts and manifests in
[`Engine/fork`](../../Engine/fork/), and `tools/release.sh`.
Local historical receipts: `.re/handoff/sections/08-engine-basics-done.md`,
`06-extensions-done.md`, `s8/E-engine.md`, and the build-check log named
above. Current tree facts use only narrow file reads and directory/size
checks in s8 and its main distribution view. Section 3's root was not read.

## Built and adopted (2026-11-11)

The official engine was built remotely (see `docs/engine-fork.md`, "Remote official build") and
packaged as `cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64_-official_minimal`.
Record with hashes and inputs: `Engine/fork/official-distrib.json` (no binaries in git). Framework
SHA-256 `b8d6e3363eec07f880bbc1505580480c143b4625a7247d84032753852751259f`, UUID
`4C4C445D-5555-3144-A19E-A98D4CE75780` (after patches 0012 and 0013; earlier builds `6b6c8d5c…` and `cd76f997…` are superseded). The dSYM and receipts are archived on the M5 in
`~/Developer/open-engine/symbols/<distribution name>/`. The App build fetches it through the engine
root's `distrib.txt`; adoption also applies the download-handler lifetime companion change in
`Engine/OpenEngine/src/OEClient.{h,mm}`.

### Widevine (option D with a switch)

Release args keep the CEF-required plumbing: `enable_widevine = true`, `bundle_widevine_cdm = false`,
`ignore_missing_widevine_signing_cert = true` (no CDM is bundled). Patch `chromium/0012-open-widevine-opt-in.patch`
registers Chromium's Widevine CDM component only when the browser process has `--open-enable-widevine`.
The App passes it when Settings → Advanced → "Play DRM-protected video" is on (`open.advanced.enableWidevine`,
off by default; takes effect at the next launch). Then the component updater downloads Google's CDM. Open has no
Widevine licence or VMP signature, so services that enforce VMP may still refuse playback.

### Profile deletion barrier (patch 0013)

`chromium/0013-open-bookmark-deletion-barrier.patch` adds `BookmarkModel::FlushAndStopWritesForProfileDeletion`
(and `BookmarkStorage::SaveNowAndStop`). `ProfileDeletion::Wiped` in `open/browser/profiles/open_profile_context.cc`
calls it and releases the Profile only after the bookmark backend sequence has finished its writes. Before, the
storage's final save ran after the deletion completed and recreated `Bookmarks` / `EncryptedBookmarks2` in the
deleted Profile folder (e2e-profiles failed 6/6 on rented Macs, 2026-11-12). The patch also runs the bookmark
storage's backend sequence at USER_VISIBLE: Chrome fences BEST_EFFORT tasks until it sees startup complete, which
Open's hosted pages reach only by the 3-minute failsafe, so fenced saves ran late and the barrier waited on them.
Other BEST_EFFORT work in Open is also deferred until that failsafe (follow-up for the lead).
