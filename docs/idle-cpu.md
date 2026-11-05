# Idle CPU: Section 8 item 12

Release Swift/AppKit shell, M5 Pro (18 logical CPUs), macOS 27.2 (26B123),
Baseline 2026-11-04; final validation 2026-11-05. The engine is main's recorded Chromium 156.0.8078.48 / CEF
156.0.14 distribution, SHA-256
`e949ff69abf556b46cf102a9fe4538a2e0eaa25eb68c45dd2711f2a13cc4229d`.
This is an automation-enabled Release shell, not an official PGO engine build.
No Chromium/CEF patch or engine source tree was changed.

## What changed

`SleepController.nextPassDelay()` used to return five seconds for every
eligible frozen tab, even when balanced discard was still minutes away.
The real-App negative proof on the baseline binary printed
`sleep_frozen_deadline FAIL` with phase `frozen`, delay `5`, load
8.95 / 7.81 / 8.45, and successful owned-process cleanup.

Frozen tabs now wait for their discard time, extended by any active audio,
load, form or retry deadline. The same shared task remains; there is no
per-tab timer. Visibility, settings, permission, audio, load and other event
hooks still request a pass within five seconds. Live hidden tabs retain the
existing five-second cadence while approaching freeze. Pressure handling
and freeze/discard policy stay the same.

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

## Profiles and ownership

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
/usr/bin/lockf /tmp/open-m5-quiet.lock /usr/bin/lockf /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/engine_e2e.py --config Release --style chrome --only measure \
  --engine-sha256 e949ff69abf556b46cf102a9fe4538a2e0eaa25eb68c45dd2711f2a13cc4229d
```

The suite reports observations, not a new CPU threshold. The new regression
gate checks the real sleep policy's next configured deadline. The existing
sleep ladder still checks freeze and discard at their configured times.

## Baseline observations

Percentages below are of one core. The initial prototype stored Mach-tick
ratios rounded to four decimals. These baseline values apply the measured
125/3 nanoseconds-per-tick conversion; rounding uncertainty is at most
0.0021 percentage points per process. The final sampler converts before
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
controlled CPU reduction claim across changing public pages. The before
app was built at `5782add4`; the after app includes the required merge of
`origin/main` at `c993c35d`. The deadline regression proof isolates the
changed scheduling rule; these cross-run CPU observations do not isolate
its small contribution from page, load or main-merge effects.

The blank-page helper processes consumed about 0.054% in later idle. They
are Chromium processes. The shared App/browser process added about 0.075%,
which includes Swift, AppKit and Chromium. A wall-stack sample cannot split
that 0.075% reliably by owner. Thus the observed blank-window engine/system
floor is about 0.13% in total, with 0.075% an upper bound for the browser-side
Chromium contribution. The ten-tab GPU and renderer costs additionally
include work caused by page JavaScript and painting; they are not intrinsic
Chromium idle overhead. The pinned development engine's GPU/Dawn/Metal and
`ZombieDealloc` work should be re-profiled on an official engine build.
