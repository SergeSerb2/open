# Launch diagnostics and pre-main research

The 2026-11-08 M5 window found no measurable gain from the five launch candidates. They were all reverted: menu deferral/coalescing, optional framework delays, initial layout coalescing, unused dylib stripping, and Sparkle delay-load. PR #251 keeps default-off diagnostics and the batch harness. No further optimization is implemented.

The window medians were floor 141 ms, matched-links 149 ms, main 375 ms and branch 377 ms, with seven launches per variant. Main/branch paint was 744/771 ms; key acceptance was 489/490 ms in a separate set. All 119 valid samples and the multi-second outliers remain in the PR table. The 250/700 ms budgets remain open.

## What the marks mean

`main` is recorded after `OEApplication.shared`, not at the executable's first instruction. The floor's `main` mark also follows application creation. Subtracting those marks cannot identify a loader cost. The separate budget run's 282/175 ms values do not establish a 107 ms cost in Open's own images.

`OPEN_SPEED_TRACE=1` enables fixed signposts and precise phase counters. It is off by default. Automation can separately enable entry/sidebar image snapshots, first-frame registry-route diagnostics and a CmdL readiness event. Image enumeration and key probes stay out of primary timing runs. The whole native menu tree is checked at a settled point, including AppKit's late items. Registry diagnostics report routing without executing commands such as Quit or Print.

## Method and provenance

The research uses the frozen window cohort: main `cca16812` plus measurement-only menu/loader hooks and the same embedded engine. It does not validate current merged main. All 137 cached linker inputs were preserved and hash-checked before the current-main build. Their 53,999,560 bytes let the research relink the original executable without another engine root.

Controls add OpenEngine and Sparkle to the 52-link floor, one at a time and together. There is no dynamic OpenKit product in this cohort: OpenKit objects are linked into Open. The 52-link floor already includes all 26 direct Swift runtime/overlay dylibs.

The empty-entry Open retains the original Swift main as a linker root. It keeps 493 Objective-C classes and the same Swift metadata while executing no application main. A second entry records its timestamp and then calls that original main. This is a measurement control, not a proposed production trampoline. Small C controls use the same direct graph, with/without the embedded frameworks. Unreferenced padding makes the small executable approximately the same file size as Open. Optional application-creation controls record the interval after the C entry separately.

Builds ran through `s16-heavy.sh` before launches, with no quiet/screen lock. Every changed control first passed a loader-only launch under the screen lock, without creating NSApplication or a window. Timing used LaunchServices, seven interleaved rounds, load1≤12, quiet then screen per round, and no heavy token. Low-load waits held no lock. A separate image pass took only the screen lock.

| Set | Valid timing samples | Valid load1 range | Over-limit attempts retained |
|---|---:|---|---:|
| Framework / empty-entry controls |98|6.06–8.25|0|
| Same-executable launch setup |42|10.97–11.86|2|
| CPU / argv / environment controls |42|10.06–11.16|1|
| Unique bundle identifier controls |49|10.62–11.99|1|

All 231 valid timing samples remain, including outliers. Four over-limit attempts remain in raw JSON and are excluded only by the declared load gate. The harness now rechecks the recorded load immediately before launching. The 14 image launches are functional observations and are excluded from timing results.

Raw evidence is under the project artifact directory `.re/s16/launch-fixes/pre-main/`: `build.json`, `cached-inputs.json`, `static.json`, `experiment-summary.json`, `all-samples.json`, and `results/{primary,launch-shape,cpu-shape,unique-shape,images}/`. Every result directory has a table, sample JSON and raw launch logs. Sources and exact link commands are retained there. No cache purge or debugger attachment was used. These are repeated launches, not a disk-cold experiment.

## Cause table

Deltas below are medians of differences within each interleaved round. They are not differences of unrelated medians. A negative delta within noise is not an improvement.

| Item | Measured effect | Evidence and limit |
|---|---|---|
| OpenEngine added to matched Swift floor |+0.68 ms to entry; paired range −1.14…+0.91 ms|`primary/samples.json`;52→53 direct links. No large cost identified.|
| Sparkle added to matched Swift floor |−0.37 ms; range −2.75…+2.54 ms|Same set;52→53 links. The result is noise, not a gain.|
| Both embedded frameworks |+0.96 ms; range −0.66…+1.82 ms|Swift floor. In the small C controls, both add+3.11 ms versus the same C entry without them. Different control languages must not be combined into an exact decomposition.|
| Open's executable with code/metadata retained |+5.85 ms versus the small C entry with both frameworks; range +3.30…+6.96 ms|Same 54 direct links. This pool includes metadata registration, fixups and paging of actual executable contents. Those parts are not separated.|
| Unreferenced file-size padding |−0.08 ms with both frameworks; range −2.32…+2.97 ms|51,136→28,749,824 bytes. File length/mapping alone does not explain the large gap. This does not isolate paging of real code/metadata or external signature/security waits in slow launch modes.|
| Dynamic OpenKit / additional Swift overlays |No extra image to add|At entry, matched floor 747 images; floor+both 766; retained Open 766. After normalizing bundle paths, the latter two differ only in the executable. No additional Swift image or dynamic OpenKit image appears. This is image-set evidence, not a zero-cost claim.|
| Own load-time initializers |No main/Sparkle initializer; one OpenEngine allocator-zone initializer|`dyld_info -arch arm64 -inits`. Its cost is included in the framework controls. No non-lazy Objective-C class/category list is present.|
| Large pre-entry wall-time difference |About 153–157 ms in the original request experiment|The same executable/hash, with empty main, measured 177.65 ms under the simple request versus 25.20 ms with the harness request: paired delta 152.93 ms. It cannot be explained by a different application image graph or post-main work. The follow-up below identifies a `syspolicyd` scan and corrects the request-only interpretation.|

Static inventory (`audit.py`, `otool -L`, `dyld_info -arch arm64 -inits -fixups`): the retained empty Open is 28,648,608 bytes, 493 Objective-C classes, one category and 48,782 fixups. The small C control has no own classes and 22 fixups. OpenEngine has 31 classes/6,815 fixups; Sparkle has 57 classes/5,908 fixups. Open has 1,503 Swift type-descriptor references. These counts support the pooled comparison; they do not assign CPU milliseconds to individual sections.

Removing the explicit linker root for original main did not remove its code/metadata: the second empty Open has the same size, class counts and fixup counts. It is not a successful code-stripping experiment and supplies no separate gain estimate.

## The large delay is mostly non-CPU time

A second control records self CPU time with `getrusage` at entry, plus page-ins and the `RUSAGE_INFO_V5` shared-cache flag. It changes no production code.

| Same executable, empty main | Entry wall median | Self CPU median | Median wall minus CPU |
|---|---:|---:|---:|
| Simple LaunchServices request |183.72 ms|23.13 ms|160.37 ms|
| Harness arguments, minimal environment |26.41 ms|18.02 ms|8.28 ms|
| Harness environment, no arguments |26.81 ms|18.85 ms|8.01 ms|
| Both |26.86 ms|18.75 ms|8.09 ms|

The paired wall reduction is 155.99/156.91/156.74 ms for those three request changes. The first simple sample is 38.69 ms and remains in the data. Page-ins are 39 in the warm samples for both slow and fast requests. The shared-cache reslide flag is unset throughout. This excludes neither external signature/security work nor another platform wait; it does show that the missing wall time is not 150 ms of CPU in Open's process.

A final bundle control changes only the bundle identifier and its required signature. Unique-ID simple launches still have a 159.82 ms entry median, while the same control with arguments has 25.31 ms. Duplicate-ID simple launches have 178.22 ms, versus 25.31 ms with arguments. Duplicate registration alone does not explain the delay. Full-main controls also retain occasional slow-entry samples. That experiment did not yet identify the OS caller. The unified-log follow-up below does. The fast controls use an altered entry/bundle and do not establish that the production App meets its launch budgets.

WebKit is informational. Sparkle adds WebKit to the entry image set, while the no-Sparkle AppKit floors load it later by the confirmed frame. Its presence is not a gate and does not prove a removable launch duration.

## Ranked next targets

These are measured opportunity bounds, not accepted fix gains:

1. **Stop invalidating the security scan cache on every run:** the follow-ups below identify about 148–157 ms in `syspolicyd` `ChangetimeScan`, then identify Chromium's per-run code-sign clone hard link as the ctime writer. The feature can be disabled from the App, but its update-safety purpose must be preserved or proved unnecessary before shipping that choice. The first signed-build check remains required. Changing the harness request is not a product launch improvement.
2. **Reduce the executable's real loader footprint only if worthwhile:** the measured pool is about 5.9 ms. Class/Swift metadata registration,48.8k fixups and touched code/signature pages remain combined. A module split or metadata reduction cannot claim the full 107 ms hypothesis from this evidence.
3. **Embedded framework work is low priority:** roughly 1 ms in the Swift floor and 3 ms in the C graph control. Do not revive Sparkle/framework-delay candidates without a new measured gain.

The former menu/layout/link candidates remain reverted. No optimization was implemented during this research.

## Unified-log follow-up: the wait is a syspolicy change-time scan

The OS component is **`syspolicyd`**, specifically its `ChangetimeScan` signpost. Across the follow-up, launches with this scan take a median 182.25 ms to the empty C entry; launches without it take 25.51 ms. The scan median is 156.86 ms. Subtracting each scan interval leaves a median 24.81 ms. This accounts for the large non-CPU interval. It does not establish that a production notarized build pays the same cost.

The earlier “simple versus harness” result was incomplete. An unchanged executable can launch quickly through either request. After a research copy's file-change time advances, **all** request types can incur the scan, including arguments, plain `open -a`, and default NSWorkspace. Arguments are not a reliable way to remove it. Cache/change-time state must be controlled as well as request shape.

### Capture and controls

The original empty-main slow/fast binary was repeated in seven interleaved pairs, then another seven pairs with two seconds between pairs outside all locks. The first simple launch in each set remained slow (183.24/185.54 ms); the following simple launches were fast. All samples are retained.

A second control keeps the original Open code, metadata and links, but writes the C-entry receipt to a fixed `/tmp/s16-ls-entry-PID.json` path. This lets the request be exactly `/usr/bin/open -a APP`, with no arguments, environment or output-redirection options. The NSWorkspace helper calls `openApplicationAtURL:configuration:completionHandler:` with `[NSWorkspaceOpenConfiguration configuration]` unchanged. Its timing/log window starts at the API call, excluding the helper's own startup. Neither control calls the original Swift main or creates NSApplication.

For the change-time experiment, only the research copy's executable timestamps were changed with `os.utime`; its bytes and SHA-256 remained identical. A second set advanced the whole change-time second before every sample, outside all locks. This tests security cache invalidation, not a disk-cold launch. No quarantine attribute was removed, no cache was purged, and no security policy was disabled. The frozen window artifacts were untouched.

Builds used `s16-heavy.sh` with the authorized engine root exported. Changed controls passed signature checks and direct loader-only launches under the screen lock before LaunchServices runs. Timing waited outside all locks for load1≤12, then acquired quiet → screen per set, with load checks before each launch. Launches took no heavy token. The scripts held no lock during spacing or low-load waits.

For every launch, `log show --start/--end --style ndjson --info --debug --signpost` captured the named security/launch daemons, plus kernel AMFI/sandbox messages containing the control path or PID. This version of `log show` rejects fractional start/end timestamps. The queries therefore enclose the window in whole seconds; the retained `.ndjson` is filtered back to the exact request-to-observed-exit interval. `.seconds.ndjson` preserves the enclosing query. All collection ran after releasing timing locks. No command requested a password.

Raw evidence, sources, exact link commands, artifact hashes and query arguments are in `.re/s16/launch-fixes/pre-main/launchservices/` under the project artifact directory. `TABLE.md`, `summary.json`, `derived.json`, and `evidence.md` index the results. Each sample has its original launch receipt, exact log window and retained enclosing log. The historical CPU sample is separately labeled and excluded from the new timing totals.

### Cause and hypothesis table

All **168** launches passed the load gate (load1 **6.39–11.12**); none was discarded. There were 82 launches with a complete `ChangetimeScan` and 86 without one. Every request/settings row below has seven interleaved launches. The full per-sample table and all outliers are in the raw artifact table.

| Request or hypothesis | Measured result | Evidence and interpretation |
|---|---|---|
| Original simple / args pair, unchanged files |Entry 25.30 / 24.03 ms medians; first simple 183.24 ms retained. Spaced repeat 24.01 / 23.18 ms; first simple 185.54 ms retained.|`results/` and `spaced-pair/`; each first slow sample has a 145.26/147.73 ms scan. Most warm simple launches do not.|
| Simple / args after change-time advances |Entry 177.65 / 173.42 ms; scan 152.75 / 151.37 ms. Scan incidence 7/7 and 6/7.|`ctime-seconds-results/`; the 24.77 ms first args sample remains. In the later settings set both modes have scans 7/7 and entry 182.04/180.64 ms. A request-only explanation is refuted.|
| Dock-equivalent `open -a`, no options |Warm entry 27.22 ms; after change-time advances 180.96 ms. Scan 157.16 ms, 7/7.|`results/` versus `ctime-seconds-results/`. Request→RunningBoard PID median 25.12 ms; request→SIGCONT 28.13 ms in the latter set.|
| Default NSWorkspace configuration |Warm entry 28.80 ms; after change-time advances 185.29 ms. Scan 161.55 ms, 7/7.|Same sets. Actual API request→RunningBoard PID 19.88 ms; request→SIGCONT 22.80 ms. Caller startup is excluded.|
| Gatekeeper / ad-hoc-signature hypothesis |A long `syspolicyd` change-time scan accounts for the gap; the first ordinary `GatekeeperEvaluation` is only 6.25 ms.|`results/000-0-legacy-simple.ndjson` lines 40–43, 182–185, 313. AMFI names the research paths and reports ad-hoc/unknown-chain status. The signed/notarized outcome remains untested.|
| State restoration / reopen |Single-key `NSQuitAlwaysKeepsWindows=NO`: entry 183.53 ms, scan 157.85 ms, 7/7. Same-set base 182.04 ms.|`settings-results/`. The empty entry creates no NSApplication or window. The tested setting does not remove the scan.|
| LaunchServices / Apple Event handshake |Hint send→reply median 0.226 ms, range 0.104–0.415 ms across all 168 launches; SIGCONT precedes scan completion.|Per-sample CoreServicesUIAgent/launchservicesd sequence. The app exits without consuming an open-application event. This handshake is not the observed 150 ms interval.|
| App scripting / child-death declarations |`NSAppleScriptEnabled=NO`: entry 180.10 ms, scan 158.47 ms in 5/7; two fast samples retained. `LSGetAppDiedEvents=NO`: entry 186.58 ms, scans 7/7.|`settings-results/` and `ctime-results/`. Neither setting prevents the scan. They do not supply a product fix.|

The executable's kernel process-start receipt is not an `exec` tracepoint. The requested daemon/kernel filter exposed no precise successful-exec timestamp. The table uses the explicit RunningBoard `submitAndStart completed … pid=…` line and LaunchServices SIGCONT as observable boundaries. These appear well before entry and cannot account for the scan interval. Wall-clock-to-log calibration varied by up to 9.9 ms, so sub-millisecond request-to-exec claims would be unsound. Scan durations use begin/end timestamps from the same log.

In the first slow sample, `GatekeeperEvaluation` ends at 01:48:12.102709 and `ChangetimeScan` runs from 01:48:12.102751 to .248012 (145.261 ms). LaunchServices sent SIGCONT at .099368. The scan ends just before the embedded OpenEngine/Sparkle AMFI messages and C entry. A prior CPU sample independently has `ChangetimeScan` from 01:28:41.372907 to .528813 (155.906 ms). `evidence.md` gives exact source lines.

AMFI reports the expected missing certificate chain and ad-hoc/unknown-chain status for these research images. They still exit normally with status 0. This is not a crash or evidence that a Developer ID signature will bypass every scan. Syspolicy's ordinary `GatekeeperEvaluation` and its much longer `ChangetimeScan` are distinct intervals. Generic trustd/security activity with private targets is not attributed to Open. No separately identified XProtect, trustd, securityd or kernel interval accounts for the 150 ms gap in these samples.

### App settings and signed-build check

No App-side setting tested removes the scan. The single-key `NSQuitAlwaysKeepsWindows=NO` control tests the restoration hypothesis. `NSAppleScriptEnabled=NO` tests whether the App's scripting declaration is responsible. `LSGetAppDiedEvents=NO` also leaves the delay. These are research-only Info.plist copies; none is proposed for the product. The first exploratory restoration copy also included `NSDisablePersistence` as an Info entry; that entry is not treated as proof of a supported NSApplication switch. The later single-key control is the useful comparison.

The empty C entry has not created NSApplication, called `finishLaunching`, restored a window, dispatched an open-application event, or entered a run loop. An App-side restoration handler or NSApplication option applied after entry cannot explain a delay before that entry. The logs show the Apple Events hint and SIGCONT completing before the scan finishes. This excludes that handshake as the dominant observed interval; it does not claim that every OS restoration path has been exhaustively tested.

**First notarized Developer ID build: required check.** The owner should produce a signed measurement-only empty-entry sibling from the same Release object inputs and engine as the signed App, with the receipt writer included before signing. Sign/notarize/staple it through the normal owner-run distribution process. Do not re-sign an existing distribution or change its quarantine state. We did not access a signing identity, Keychain or notary service.

On its first natural launch from the intended distribution location, at load1≤12 under quiet → screen, record the exact `open -a` request, entry receipt and exit window before running an explicit Gatekeeper assessment. Then run seven interleaved launches per mode: `open -a APP`, default NSWorkspace, and the existing args request, retaining first and warm samples separately. Use the same `collect.py` predicate and exact-window filtering. Repeat the signed real App's normal Dock-equivalent launch and record sidebar/paint with its existing diagnostics in a separate functional/timing set. The empty sibling alone does not accept a product launch budget.

Record these static checks after preserving the first-launch evidence (none needs signing credentials):

```sh
codesign --verify --deep --strict "$SIGNED_APP"
codesign -d --verbose=4 "$SIGNED_APP"
xcrun stapler validate "$SIGNED_APP"
spctl --assess --type execute --verbose=4 "$SIGNED_APP"
xattr -p com.apple.quarantine "$SIGNED_APP"  # absence is a recorded result
```

Compare the signed cohort's `ChangetimeScan` incidence/duration, AMFI chain result, request→RunningBoard/SIGCONT intervals and entry time with this ad-hoc cohort. A valid Developer ID chain, accepted notarization and absence of the long scan would support the signing hypothesis. A persistent scan would refute the claim that notarization alone removes it. Preserve network state and first/warm cache state; do not promise a 155 ms product gain from this research. Stop rather than answering any authentication dialog.

No product code or product signing configuration changed.

## Frozen-window scan audit

The original window did pay for a security scan on **56/56 Open primary samples**. Neither floor did: **14/14 floor samples had no observed scan**. Of the Open samples, 50 have `ChangetimeScan` (median **148.188 ms**, range **145.768–151.021 ms**). The first launch of six candidate bundles instead has a full `GatekeeperScan` lasting **3.53–3.73 seconds**. Those scans explain the retained multi-second outliers; they are not missing or scan-free samples.

This audit reads the existing `/tmp/s16w0027/results.json` and unified log from **2026-11-08 00:26:50–00:30:30, GMT−07:00**. It adds no timing set. The query used `log show --start/--end --style ndjson --signpost --info --debug`, with the security/launch-daemon and kernel AMFI/sandbox filter described above. The table covers only the 70 primary samples, not the separate key-readiness set. Sample numbers follow the seven interleaved rounds.

Cells are scan durations in milliseconds. `GK` means a full `GatekeeperScan` rather than `ChangetimeScan`; `0` means neither scan was observed in that sample's pre-main window.

| Variant | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---:|---:|---:|---:|---:|---:|---:|
| floor | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| main | 148.188 | 148.222 | 148.649 | 146.413 | 146.401 | 147.815 | 148.084 |
| update-ui | 149.211 | 146.847 | 148.129 | 147.292 | 147.663 | 148.900 | 149.886 |
| floor-links | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| branch | GK 3528.084 | 147.303 | 149.549 | 147.237 | 151.021 | 147.619 | 148.164 |
| eager-menu | GK 3731.917 | 148.463 | 148.445 | 148.346 | 148.650 | 148.560 | 149.411 |
| eager-optional | GK 3656.449 | 147.255 | 149.733 | 146.624 | 145.850 | 147.684 | 148.373 |
| double-layout | GK 3622.381 | 147.693 | 147.219 | 145.768 | 147.848 | 148.188 | 149.005 |
| no-strip | GK 3714.931 | 150.452 | 150.842 | 148.159 | 149.618 | 149.179 | 149.802 |
| eager-sparkle | GK 3706.494 | 145.865 | 148.599 | 146.896 | 146.937 | 149.680 | 148.358 |

Attribution uses each receipt's PID, RunningBoard's public executable path/PID, and the single-launch pre-main interval. Signpost `Path` fields are private, so this is temporal attribution, not a decoded private path. Every assigned scan has a complete begin/end pair, and none is assigned twice. For example, main sample 1 has an explicit bundle-path `Checking PreventLaunch` at 00:27:13.925884, then `ChangetimeScan` at 00:27:13.931796–14.079984 (148.188 ms). Raw log lines are 2202, 2208 and 2337. Branch sample 1 has `GatekeeperScan` at 00:27:16.847584–20.375668 (3528.084 ms), lines 3562–3869, following RunningBoard's PID 39841 at line 3508.

The 50 change-time samples have a median Open `main` mark of 259 ms. Subtracting each scan leaves a median 110.824 ms. The matched floor's `main` median is 79.545 ms. Thus the scan explains most, but not all, of the main-mark gap. These marks still include application creation; this subtraction does not identify another loader cost or prove a fix gain.

### Executable ctime advances during a full run

A functional launch used an APFS copy of frozen `window-main/Open.app`, never the frozen artifact itself. Before launch, strict signature verification and SHA-256 matched the manifest. Snapshots recursively recorded all 705 bundle entries and separately captured `stat -f '%c %m %N'` for the root, `Contents/MacOS/Open`, each framework/helper and `Contents/Resources`. Separate `xattr -lr` dumps avoid treating the JSON's empty xattr placeholders as evidence.

Only **`Contents/MacOS/Open` changes ctime**, the filesystem metadata change time. The other 704 entries remain unchanged, including the bundle root, frameworks, helpers and resources. The executable's bytes, mtime, size, inode and mode remain unchanged. Its before/after xattr dumps are byte-identical, including `com.apple.provenance` values. Static signature verification alone changes no entry. The frozen source's before/after snapshots also match.

| Observation | Executable ctime, local GMT−07:00 | Other executable evidence |
|---|---|---|
| Before full launch |02:11:25.258602646|SHA-256 `61b19063b7d30ba7115a06ec9272f4b3b049cb54f050d3b2d9ec7003e691c48c`|
| After paint |02:11:53.969511411|mtime remains `1794111024364991895` ns; size 28,656,080 bytes|
| After clean exit |02:11:54.780675916|Same SHA-256, inode, mode and xattrs|

That launch ran at load1 12.249→14.151. It is functional metadata evidence, not a timing receipt. Two further full runs, with the earlier research trace enabled, also advance executable ctime during the run and again by clean exit. All three full runs close their windows and leave no owned process.

### Cause boundary and controls

| Check or control | Result | What it establishes |
|---|---|---|
| Batch/harness static inspection |Launches the bundle in place; copies only profiles per sample. Hash/signature validation is before the batch; no per-sample xattr, signing or touch operation.|No identified per-launch bundle writer in `window_batch.py` or `engine_e2e.Open` constructor/quit paths.|
| Empty C entry, twice |No ctime advance.|The retained executable/framework bundle can exit without changing its metadata.|
| Empty entry plus `NSApplication.shared` |No ctime advance.|Application creation alone is insufficient. This control does not call `finishLaunching`.|
| Same full Open executable with `OPEN_AUTOMATION_QUIT_BEFORE_ENGINE=1` |No ctime advance; clean exit and `terminationSkippedEngine` logged.|The existing AppKit/model/window/finish-launching path and `open -n` registration are insufficient. The observed change needs a later stage.|
| Entry-only CEF `dlopen`, leaving it resident through exit |No ctime advance.|Mapping CEF alone is insufficient. This is not an engine-initialization control.|
| Entry-only child `posix_spawn` and `fork` controls |No ctime advance.|A simple child-process operation alone is insufficient.|
| Entry-only copy of Open's signature-information query |All three Security calls succeed; no ctime advance.|`SecCodeCopySelf`, `SecCodeCopyStaticCode` and `SecCodeCopySigningInformation` alone are insufficient. No identity or Keychain was accessed.|
| Earlier opt-in metadata-call trace |No matching metadata setter caught in Open or its CEF helpers, while ctime still advances.|No writer identified. Missing calls, direct syscalls and external writers remain possible; this negative result does not prove an OS writer.|

The auxiliary entry controls and traces are historical research evidence from before the new interposer ban. They supply no product change and will not be reused. The attempted broader trace failed its loader-only check before NSApplication/window creation: `Open-2026-11-08-022918.ips`, SIGABRT, `_tlv_bootstrap_error` from the research library's `wrap_mmap`. It is a research-instrument failure, excluded from the evidence above. All launch work stopped immediately. The lead was notified, and research remained stopped overnight until the morning's explicit M5 clearance. `DYLD_INSERT_LIBRARIES` and interposer experiments remain prohibited on every machine.

The overnight audit established **security re-assessment, with executable ctime advancing during full runs**. At that point the exact writer was unresolved. The unchanged bundle and before-engine control do not support bundle size or nested-code count alone as the reason for a ctime advance on every full launch. They do not exclude those factors from the scan's duration. Nearby `syspolicyd` bastion/XProtect messages have private target paths and do not prove that either service wrote Open's metadata. No product or harness writer has yet been demonstrated, so no fix is proposed.

**Open question at 02:32:** which writer in or after engine init advances the executable's ctime? The morning follow-up below resolves it.

**Next step recorded at 02:32:** find the writer without interposers: compare ctime before and after runs that stop at successive engine milestones, using the App's existing launch marks. Work resumed after the lead cleared the M5 screen in the morning.

Evidence is retained in `.re/s16/launch-fixes/pre-main/launchservices/window-audit/`: `window.ndjson`, `index.py`, `primary-scans.json` (bundle/PID and exact log-line references for every cell), `scan-spans.json`, `audit-summary.json`, the before/live/after `.json`, `.stat` and `.xattr` snapshots, `functional.json`, `appkit-probe.json`, `early-quit.json`, `load-probe.json`, `spawn-probe.json`, `signature-probe.json`, and the two completed trace directories. No new timing set or product change was made.

## Writer found: Chromium's code-sign clone hard link

**The writer is Chromium's `CodeSignCloneManager`.** During engine initialization it APFS-clones the App, replaces the clone's main executable with a hard link to the running App's executable, and later removes that link through its cleanup helper. Creating and deleting a hard link changes the source inode's ctime and link count without changing its bytes, mtime or xattrs. This explains both changes observed overnight.

The call path in the authorized read-only Chromium source view is:

| Source under `chromium/src/` | Evidence |
|---|---|
| `chrome/browser/chrome_browser_main_mac.mm:79` |`ChromeBrowserMainPartsMac` constructs `code_sign_clone_manager_` with the outer bundle and main executable name.|
| `chrome/browser/mac/code_sign_clone_manager.mm:513` |`kMacAppCodeSignClone` is enabled by default. The constructor checks that feature at line 524, then posts `Clone` at lines 543–546.|
| Same file, lines 623, 338 and 294 |`Clone` calls `CloneApp`, which calls `HardLinkMainExecutable`; its `link(source, destination)` creates the additional reference to the original executable.|
| Same file, lines 550–559 and 734–765 |The destructor launches the cleanup helper. It waits for the parent to exit and removes the clone directory, including the hard link.|
| `chrome/browser/mac/code_sign_clone_manager.h:18–49` |The stated purpose is to keep the original executable and its surrounding signed bundle reachable after a live App update. This is code-signature protection, not signing or changing the executable's contents.|

No engine source was edited, and no git command ran in that source tree. `source-evidence.json` records the viewed files' SHA-256 values and line ranges; the retained excerpts identify the exact source used. The runtime evidence below independently proves that this path runs in Open.

### Separate-process stat observation

The observer requests a poll every 2 ms and records `st_ctime_ns` (the full `st_ctimespec` value), mtime, inode, device, link count, size and mode. It watches the executable, bundle root and immediate framework/helper entries. It runs in a separate process, without attachment, root, `fs_usage` or an interposer. It also records the matching clone path and inode while the hard link exists. Ordinary functional launches take only the screen lock. They are not timing or budget receipts.

| Functional run | Executable metadata changes | Result |
|---|---|---|
| Frozen normal App |09:29:39.524486043: links 1→2; 09:29:41.012449262: 2→1|The live `Open.app.bundle/Contents/MacOS/Open` clone has the original's device and inode. Observed change-boundary poll gaps are 3.200/3.277 ms.|
| Same executable with `--disable-features=MacAppCodeSignClone` |None through first paint and clean exit|Link count stays 1; ctime and executable SHA-256 stay fixed. The feature switch is passed through the existing process command line to CEF.|
| Same executable, existing quit-before-engine path |None|`terminationSkippedEngine` confirms a clean exit before engine initialization.|
| Current merged Debug, normal feature state |09:35:04.641391754: links 1→2; 09:35:05.624395400: 2→1|The live clone again has the original's device/inode. Change-boundary poll gaps are 2.676/2.618 ms. This build uses the refreshed main engine view.|

All four runs keep their executable SHA-256 unchanged, exit cleanly and leave no owned process. No observed bundle-root/framework/helper metadata changes occur. Loads before→after are 10.40→11.01, 16.59→17.42, 33.46→33.46, and 17.27→15.84. The observer's requested interval is not a real-time scheduling guarantee: maximum gaps elsewhere are 35.0/45.8/23.5 ms in the normal, disabled and current Debug runs. Those gaps are retained; the two link transitions in each normal run are bracketed within 3.3 ms, and the inode itself supplies each exact ctime value.

The existing Debug signposts place the first ctime change **inside `CefInitialize`**:

| Event, 2026-11-08 GMT−07:00 | Timestamp | Evidence |
|---|---|---|
| `engineStart` |09:35:04.542080|`current-debug/unified.ndjson:1720`|
| `cefInitializeBegin` |09:35:04.570891|Line 1730|
| Executable hard link, links 1→2 |09:35:04.641391754|`current-debug/stat.ndjson`; matching clone device/inode|
| `cefInitializeEnd` |09:35:04.683469|Line 1833|
| `engineStarted` |09:35:04.683547|Line 1834|
| `engineInitialized` |09:35:04.688707|Line 1866|
| `firstLoadEnd` |09:35:04.899971|Line 2027|
| `updaterCreated` |09:35:05.032134|Line 2146|

The hard link already exists before `CefInitialize` returns and before the later navigation/updater marks. The existing before-engine stop, the same-inode clone and the feature-off full run isolate the writer directly. No new milestone executable or crash-prone probe was needed. `--enable-logging=stderr --v=1 --verbose` reaches Chromium; its ordinary logs are retained alongside the signposts.

The prior launch's link creation/removal advances the executable ctime **after** that launch's pre-entry assessment. The next LaunchServices request therefore sees a changed executable and scans again. This sequence explains why unchanged in-place Open bundles scan repeatedly while the empty-entry controls stay warm. It is not evidence of a source-file write, an updater installation, or a bundle-size-only cache policy.

### Fix options and remaining gate

The existing App/engine configuration can append `--disable-features=MacAppCodeSignClone` before CEF starts. The functional control proves that this removes the ctime writer; it does not measure a shipping launch gain. No product default or switch was changed in this PR.

For Debug/ad-hoc builds with no in-place updater, an App-side opt-out is the bounded option. For shipping builds, first prove the updater never replaces a bundle while its old process is alive, or preserve Chromium's protection. A protection-preserving engine option is to keep and reuse an executable/version-specific anchor across launches, with safe multi-instance/update cleanup, instead of creating and deleting a hard link every run. That needs an engine-owner design and authorized root; it is not implemented here. Simply delaying the clone until after paint would still invalidate the next launch's assessment.

The 148–157 ms scan is the measured opportunity bound from earlier paired research. These functional runs do not establish its removal on the first notarized Developer ID distribution, and do not accept the sidebar/paint budgets. The signed-build check above remains required.

Raw evidence is in `.re/s16/launch-fixes/pre-main/ctime-writer/`: `summary.json`, `source-evidence.json`, source excerpts, and `normal/`, `clone-disabled/`, `before-engine/`, `current-debug/` receipts and stat logs. `current-debug/phase-signposts.json` indexes the unified-log lines. Frozen batch artifacts and the engine source tree remain untouched.

## Current-source validation

The earlier Release build of diagnostic source `0922a78c`, after merging main `caf42f74`, exited 65 in 7.3 seconds at load1 5.11→5.18. Main required missing world/site-control headers and a security-state callback in the authorized engine view. Validation stopped at that external block; no other engine root was used or fetched.

The lead refreshed `open-engine-s8-main` in the morning to main's engine SHA-256 `47af3007153a883fac2acd10e491451de0abcac030c4fbebb14f15f1052115d9`. Main `cdd147ca` merged cleanly in `fc007a04`. The Debug build through `s16-heavy.sh`, with that authorized root exported, passes in 87.8 seconds at load1 44.08→28.67. Media, firstrun, window, updater and full M5 verify-all validation are in progress. The real current-Debug functional launch and cleanup also pass. Earlier updater 21/21 and menu 107-route evidence still belongs to the earlier pinned cohort. It is not current-head acceptance. PR #251 is not ready to merge.
