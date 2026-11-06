# Idle CPU: Section 8 item 12

Release Swift/AppKit shell with `OPEN_AUTOMATION=1`, M5 Pro (18 logical
CPUs), 2026-11-05. The matched CPU comparison uses main `03a0d5cb`, Chromium
156.0.8078.48 / CEF 156.0.14, framework SHA-256
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.
The built-in 2x panel is the main display; the external 1x AW2726DM is
disconnected. Display metadata is checked before and after each matched
run. This is not an official PGO engine build. The branch adds no engine
fork patches and does not edit an engine source tree.

The initial `e949ff69` profiles and CPU values below are historical evidence.
They span the reboot/display change and are not the final CPU comparison.

## Matched CPU results (f34400e7, built-in 2x main)

The before app uses main's old `SleepController.swift`; the after app uses
this branch's deadline scheduler. Both were built from the same merged
`03a0d5cb` source base with identical Release flags and the same engine.
The source hashes and every individual PID's counters are in
[the curated measurement receipt](engine-spike/idle-cpu-matched-2026-11-05.json).
The final branch subsequently merged G2 from `18c14f33` and built successfully;
per the user's final verification rule, its regression suites are deferred
to Section 8's single regression on final main.

The display remained Color LCD, 1728x1117 points / 3456x2234 Retina pixels,
120 Hz, throughout both runs. Each measured window was 1280x1067 points,
visible and active at the recorded state capture. Every 60-second process
set was stable. Mach CPU time and `ps time` deltas agreed within 0.01 s per
process. Totals sum unrounded values; displayed kinds round independently.
Both runs verified framework code hash
`1bc8b6044b77d53d46d76745a39b029e9709dbeb00fd31d08870ed0a38dd576a`.

| Settled 60 s | Variant | App/browser | GPU | Renderers | Utility | Network | Total | Load start to end (1/5/15 min) |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Blank | before | 0.0908% | 0.0120% | 0.0033% | 0.0030% | 0.0135% | 0.1225% | { 6.59 8.09 7.23 } to { 5.61 7.64 7.12 } |
| Blank | after | 0.4685% | 0.0361% | 0.0453% | 0.0058% | 0.0367% | 0.5925% | { 7.42 8.77 7.92 } to { 5.67 7.97 7.67 } |
| Ten tabs | before | 0.2707% | 2.5625% | 1.3604% | 0.0025% | 0.0424% | 4.2384% | { 4.45 6.25 6.63 } to { 4.26 5.88 6.47 } |
| Ten tabs | after | 0.0713% | 2.5566% | 1.2269% | 0.0024% | 0.0043% | 3.8613% | { 5.68 7.17 7.39 } to { 4.34 6.53 7.13 } |

The ten-tab case had ten model tabs and nine live pages at the memory
sample in both variants. The new scheduler completed **1 pass instead of
24** across its two CPU windows. At the state capture the old app planned
its next pass in **5 s**; the fixed app planned **139.59 s**, matching the
remaining discard deadline. The negative proof remains the real-App
`sleep_frozen_deadline FAIL` at delay 5; the earlier fixed real-App check
passed at 269.98 s. The queued repeat of the negative proof on the new pin
was canceled before app launch under the user's reduced verification rule.

The current profile directly catches the Open-owned work:
`SleepController.schedulePass(after:)` -> `runPass(pressure:)` -> `policies()`
in `.re/idle-cpu/matched/before/ten-browser-sample.txt`. This is the repeated
scan and allocation removed while frozen pages wait. The same profile also
shows Chromium message-loop waits. The busiest renderer has
`blink::DOMTimer::Fired` -> `blink::V8ScriptRunner::CallFunction` and paint
work; the GPU has `gpu::Scheduler::RunNextTask`, Dawn/Metal work, and
`ZombieDealloc` backtraces. Commands were `sample <pid> 10 1 -file ...` on
the browser, GPU, busiest renderer and network process, after CPU sampling.
All raw profiles remain in `.re/idle-cpu/matched/before/`.

**The approximately-zero target remains unmet with ten pages.** The after
GPU plus renderers cost 3.7835% of one core. This includes work caused by
page JavaScript and drawing, not only intrinsic Chromium idle overhead.
Blank Chromium helper processes cost about 0.124% in the after sample; the shared
App/browser process adds 0.4685%, an upper bound for its Chromium portion,
since Swift and AppKit run there too. The empty-window control varied from
0.1225% to 0.5925% despite having no hidden tab to schedule. Therefore these
single-run totals do not prove a causal CPU saving for the small scheduler
change. Its direct evidence is the profile, the failed old-policy check,
and the reduction in completed passes. Remaining Chromium investigation
includes background browser/network work and provided-engine GPU
`ZombieDealloc`/Metal costs. No Chromium behavior was disabled to lower CPU.

## What changed

`SleepController.nextPassDelay()` used to return five seconds for every
eligible frozen tab, even when balanced discard was still minutes away.
The initial real-App negative proof on the old-pin binary printed
`sleep_frozen_deadline FAIL` with phase `frozen`, delay `5`, load
8.95 / 7.81 / 8.45, and successful owned-process cleanup.

Frozen tabs now wait for their discard time, extended by any active audio,
load, form or retry deadline. The same shared task remains; there is no
per-tab timer. Visibility, settings, permission, audio, load and other event
hooks still request a pass within five seconds. Live hidden tabs retain the
existing five-second cadence while approaching freeze. Pressure handling
and freeze/discard policy stay the same.

The Release automation build also prints one successful quit-capture timing
line. The existing F4 e2e check read that line after exit, but previously
only Debug printed it. Failed captures still do not emit a success line;
the real store writes, relaunch checks and three-second bound are unchanged.
This adds no idle logging and does not change a normal Release build.

The `measure` suite now records two 60-second OS windows for each case:
a startup tail after a 30-second settle, followed by settled idle. Each PID
uses cumulative `proc_pid_rusage` CPU ticks, the host's `mach_timebase_info`,
and its own monotonic elapsed time. One core is 100 percent. The result
records CPU by PID and type, interrupt/package idle wakeups, load before
and after, and process churn. A partial surviving-process total is labeled
`complete: false`; it does not establish budget acceptance.

The old task-manager sum remains as
`idle_cpu_10_tabs_task_manager_percent`; `idle_cpu_10_tabs_percent` now uses
the settled OS total. CEF refreshes CPU every two seconds on macOS. Waiting
ten seconds before reading does not produce a ten-second average. Its CPU
is process-wide but returned per task, so shared-process task rows can also
repeat CPU. The task-manager observer itself requests CPU, memory and GPU
refreshes while the automation call holds it. OS windows have no metrics
polling. Each process also records a cumulative `ps time` delta to check
the Mach tick conversion independently. They run before the corresponding task-manager sample.

Evidence: `Engine/OpenEngine/src/OEEngine.mm`,
`sampleProcessMetricsAfter:completion:`; pinned upstream CEF
[`task_manager_impl.cc`](https://github.com/chromiumembedded/cef/blob/4fa4ab5/libcef/browser/task_manager_impl.cc)
(`kRefreshTimeMS`, `GetRefreshTypes`, constructor/destructor);
`Vendor/cef/include/internal/cef_types.h`, `cef_task_info_t.cpu_usage`.

## Initial profiles and ownership (historical e949ff69)

The baseline batch launched isolated real App windows with one blank page,
then the same nine public sites as `measure` plus its start page. It sampled
process counters for 60 seconds and then ran `sample <pid> 10 1 -file ...`
on the App/browser, GPU and busiest renderer. Profiling was outside the CPU
windows. Every batch held the quiet lock outside the on-screen lock.

- Empty App main thread: 8,530 of 8,536 wall samples were blocked in
  `__CFRunLoopServiceMachPort` under `CefMainRunner::RunMessageLoop`.
  Chromium's `HangWatcher::Wait`, kqueue message pumps and worker waits
  appear on the other threads. These are wall samples, not percentages of
  consumed CPU. The sleep controller had one completed pass and no
  scheduled pass. No recurring Swift timer, display-link, animation or
  layout loop appeared in this profile.
- Ten-page App: the main thread again waited in Chromium's message loop.
  The state receipts show the controller continuing to run passes while
  frozen tabs wait for discard. This is the Open-owned wakeup fixed here;
  it is a small part of the total CPU, not the source of the active page's
  drawing cost.
- Busy renderer: `blink::TimerBase::RunInternal` to
  `blink::DOMTimer::Fired` to `blink::V8ScriptRunner::CallFunction`, CSS
  setters, `LayerTreeHost::SetNeedsAnimate`, and Blink painting. These are
  page timer callbacks and their resulting rendering.
- GPU: `gpu::Scheduler::RunNextTask`, Dawn/Metal command encoding,
  `AGX::RenderContext`, and Chromium `ZombieDealloc` backtrace work appear.
  The engine distribution's compositor/GPU work remains outside this fix.

Source audit also found only one-shot launch/theme display links
(`App/main.swift`, `FirstWindowFrameObserver.stop`;
`OpenDesign/ThemeBackgroundView.swift`, `displayFrame`). Automation uses
`DispatchSourceRead` socket events (`App/Automation/AutomationServer.swift`),
and media state uses engine callbacks (`App/Media/MediaCoordinator.swift`).
The repeating timer in `LittleOpenCoordinator` is not instantiated by the
current App, which still uses a stub; changing that timer would not reduce
this App's measured idle work.

Raw profiles and state receipts are under `.re/idle-cpu/before/`:
`{empty,ten}-{browser,gpu,renderer}-sample.txt`, `*-sleep-{start,end}.json`,
and `*-page-counters.json`. Raw data is not committed.

A sequential diagnostic that disabled page scripts reduced activity, and
freezing all pages reduced it further. That diagnostic crossed the default
300-second discard time and lost renderer processes. It is confounded by
aging/discard and is not used as a causal CPU reduction claim. The renderer
stacks above directly establish that page JavaScript was running.

## Reproduce

```sh
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main
OPEN_AUTOMATION=1 ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release
/usr/bin/lockf -k /tmp/open-m5-quiet.lock /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/engine_e2e.py --config Release --style chrome --only measure \
  --engine-sha256 f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939
```

The suite reports observations, not a new CPU threshold. The new regression
gate checks the real sleep policy's next configured deadline. The existing
sleep ladder still checks freeze and discard at their configured times.

## Historical observations (not the matched comparison)

Percentages below are of one core. The initial prototype stored Mach-tick
ratios rounded to four decimals. These baseline values apply the measured
125/3 nanoseconds-per-tick conversion; rounding uncertainty is at most
0.0021 percentage points per process. The matched-comparison sampler converts before
rounding and retains raw CPU tick deltas and `ps` deltas. A direct baseline
cross-check read 35,760,755 CPU ticks and `ps` CPU time 1.49 seconds:
35,760,755 x 125/3 / 1e9 = 1.49003 seconds.

| Before, 60-second window | App/browser | GPU | Renderers | Utility | Network | Total | Load start to end (1/5/15 min) |
|---|---:|---:|---:|---:|---:|---:|---|
| Blank, startup tail | 1.096% | 0.008% | 0.008% | 0.004% | 0.113% | 1.229% | 5.41/8.23/9.88 to 4.61/7.48/9.49 |
| Blank, later idle | 0.075% | 0.021% | 0.012% | 0.004% | 0.017% | 0.129% | 5.14/7.50/9.47 to 6.28/7.48/9.33 |
| Ten tabs, startup tail | 0.958% | 2.663% | 1.300% | 0.012% | 0.133% | 5.067% | 4.55/6.81/8.95 to 5.47/6.61/8.72 |
| Ten tabs, later idle | 0.062% | 2.887% | 1.312% | 0.004% | 0.012% | 4.279% | 5.28/6.51/8.65 to 7.48/6.94/8.67 |

The baseline `measure` task-manager sum was 0.81% at load
13.1/15.1/12.1. In the longer probe, ten model tabs included nine live
pages at the task-manager sample; phases and individual process rows are
retained in the raw receipts. The OS results include spare renderers and
network/storage helpers. These are shared-machine observations, not a
controlled CPU reduction claim across changing public pages. Those historical runs used `5782add4` and `c993c35d`, respectively. The final matched pair instead uses the same merged source base and
changes only the scheduling implementation. The older cross-run values
do not isolate the fix from page, load, main-merge or display effects.

In that historical sample only, the blank-page helper processes consumed about 0.054% in later idle. They
are Chromium processes. The shared App/browser process added about 0.075%,
which includes Swift, AppKit and Chromium. A wall-stack sample cannot split
that 0.075% reliably by owner. Thus the observed blank-window engine/system
floor for that sample was about 0.13% in total, with 0.075% an upper bound for the browser-side
Chromium contribution. The ten-tab GPU and renderer costs additionally
include work caused by page JavaScript and painting; they are not intrinsic
Chromium idle overhead. The pinned development engine's GPU/Dawn/Metal and
`ZombieDealloc` work should be re-profiled on an official engine build.

## Verification and deferred work

The final merge includes `18c14f33` (G2 restore/wake changes), with both
G2 and this branch's deadline scheduling retained. The final
`OPEN_AUTOMATION=1 heavy.sh tools/build.sh Release` succeeded against
`f34400e7`. The paired measurements above precede that G2 integration.

Per the user's final rule on 2026-11-05 at 10:47, remaining `sleep`,
`measure`, `shell`, full verification, main-comparison checks and Site
Control retries are deferred to Section 8's single final regression on
final main. The queued extra jobs were canceled before app launch; the
in-flight matched CPU sampling finished and cleaned up. No new baseline
images or thresholds were written.

Saved validation remains as it ran:

| Run | Result | Scope and remaining failures |
|---|---|---|
| Initial full `verify-all`, 2026-11-04, after c993c35d merge | 21 PASS, 1 FAIL, no SKIP | `sitecontrol-render`: idle 14.349 ms/2 s and editor panel did not open; 1468/1470 passed. |
| Isolated Site Control, 2026-11-05, old pin | FAIL | Prior two failures passed: idle 0.192 ms/2 s, native panel opened. F24 advanced popover position failed; 1468/1469 passed, load1 6.98. This branch does not change Site Control. |
| Initial fixed Release `sleep`, old pin | 14 PASS, 1 FAIL, 6 BLOCKED; cleanup PASS | Deadline check 269.98 s and timed ladder passed. F4 lacked its Debug-only quit timing line. The automation Release summary fix was built; its suite rerun was deferred. Legacy BLOCKED rows remain BLOCKED. |
| Matched f34400e7 CPU pair | completed; both cleanups PASS | Same display and viewport; every process sample complete; no CPU budget PASS is claimed. |
| Final build after 18c14f33 | PASS | Release + automation, provided f34400e7 distribution. |

The saved full table and review-checklist table are included in the PR.
Raw saved runs are `.re/idle-cpu/verify/`,
`.re/idle-cpu/verify-sitecontrol-repeat/`, and `.re/idle-cpu/matched/`.
