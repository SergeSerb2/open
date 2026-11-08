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
| Large pre-entry wall-time difference |About 153–157 ms depends on the LaunchServices request|The same executable/hash, with empty main, measured 177.65 ms under the simple request versus 25.20 ms with the harness request: paired delta 152.93 ms. It cannot be explained by a different application image graph or post-main work. Exact OS wait remains unresolved.|

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

A final bundle control changes only the bundle identifier and its required signature. Unique-ID simple launches still have a 159.82 ms entry median, while the same control with arguments has 25.31 ms. Duplicate-ID simple launches have 178.22 ms, versus 25.31 ms with arguments. Duplicate registration alone does not explain the delay. Full-main controls also retain occasional slow-entry samples. No exact launchd/dyld/security caller was established. The fast controls use an altered entry/bundle and do not establish that the production App meets its launch budgets.

WebKit is informational. Sparkle adds WebKit to the entry image set, while the no-Sparkle AppKit floors load it later by the confirmed frame. Its presence is not a gate and does not prove a removable launch duration.

## Ranked next targets

These are measured opportunity bounds, not accepted fix gains:

1. **Explain the LaunchServices pre-entry wait first:** roughly 150 ms of request-sensitive wall time is the largest observed pool. Keep executable, arguments, environment and bundle identity explicit in the next receipt. Identify the platform wait before proposing a shipping change. A harness-mode change is not a product launch improvement.
2. **Reduce the executable's real loader footprint only if worthwhile:** the measured pool is about 5.9 ms. Class/Swift metadata registration,48.8k fixups and touched code/signature pages remain combined. A module split or metadata reduction cannot claim the full 107 ms hypothesis from this evidence.
3. **Embedded framework work is low priority:** roughly 1 ms in the Swift floor and 3 ms in the C graph control. Do not revive Sparkle/framework-delay candidates without a new measured gain.

The former menu/layout/link candidates remain reverted. No optimization was implemented during this research.

## Current-source validation block

After merging main `caf42f74`, the real Release build of diagnostic source `0922a78c` ran through the S16 wrapper against `open-engine-s8-main`. It exited 65 in 7.3 seconds at load1 5.11→5.18. Unchanged main engine sources require absent `cef_open_world.h`, absent `cef_site_control.h`, and `CefOpenPageHandler.OnSecurityStateChanged`. The authorized view is stale. No other engine root was used or fetched.

Per the lead instruction, current-source build validation stops there. The pending media, firstrun, window, updater and full M5 verify-all checks remain blocked on the refreshed view. Earlier updater 21/21 and menu 107-route evidence belongs to the earlier pinned cohort. It is not current-head acceptance. PR #251 is not ready to merge.
