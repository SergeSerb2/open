# Release idle CPU investigation (2026-11-10)

The failing row is `import-robust/idle_after_import`. Its limit remains less
than 1% of one core for the App process. Helper CPU is reported separately.
This investigation uses the original Settings import flow, including the
existing ten-second wait after import. Completing Welcome before the row is
a diagnostic control and does not replace that flow.

## Method and receipts

All measurements use Release with automation, Chrome style, synthetic import
stores, and engine distribution SHA-256
`891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67`.
The M1 holds its FIFO build slot and on-screen lock for each sample. The
lead's 20:35 rule requires two load1 readings at most 3.0, ten seconds apart,
before the run, and foreign CPU at most 100% immediately before the run and
after the idle row. There is no after-run load condition. Foreign CPU includes
the user's background transcription job; the investigation does not change it.

Private receipts are on the M1 in
`m1-idle-bisect/.re/gate-health/idle-bisect/`. Each attempt retains `quiet.json`,
the real suite result, cleanup, crash and system-window checks, and OS process
and thread counters from libproc. No debugger or sampling tool attaches to Open.
The two main commits have identical `tools/e2e/import_robust.py` bytes:
SHA-256 `c2e886c7bcb517ebfb5a220286248f89350e4779bef8cd9c6077c6c6bf139e3d`.

| Main commit | Attempt | Valid | App CPU | Before load1 | Foreign CPU before / after row |
|---|---|---|---|---|---|
| `44b19f3d` (before PR 306) | `pre306-r3` | yes | 0.593% PASS | 2.958 / 2.871 | 39.8% / 40.5% |
| `b0ebbacf` (PR 306) | `post306-r3` | yes | 3.370% FAIL | 2.466 / 2.160 | 82.2% / 97.9% |

Earlier `pre306-r1` and `pre306-r2` attempts exceeded the foreign CPU limit
after the row and do not qualify. The original limits were not changed.
`post306-r1` and `post306-r2` likewise do not qualify. The valid pair brackets
one main merge: **PR 306, `b0ebbacff879a58f49078d9972181abb4cbdf792`, is the first
bad main merge**. History and main-thread lag pass on both sides (1,024 / 1,172 ms
and 26.3 / 31.6 ms). Cleanup passes and there are no new crashes or system windows.

In the bad sample, libproc measures 3.452% for Open over 5.045 seconds, with
2.519% on `CrBrowserMain` and 0.367% on `StackSamplingProfiler`. The App-only
assertion uses its existing `ps time` counters and measures 3.370%; the extra
OS counter reads have their own recorded interval. Helpers use 0.529%, 0.209%,
and 0.000% and are not charged to that assertion.

## Why StackSamplingProfiler starts in Release

The following source paths are relative to the engine's Chromium and CEF
checkouts. The files were inspected read-only. No engine source, patch, or
distribution was changed.

1. `cef/libcef/browser/main_runner.cc:452-456`,
   `CefMainRunner::BeforeUIThreadInitialize`, gives the browser client a new
   `MainThreadStackSamplingProfiler`.
2. `chrome/common/profiler/main_thread_stack_sampling_profiler.cc:18-40`
   constructs the browser main-thread `sampling_profiler::ThreadProfiler`.
   `chrome/app/chrome_main_delegate.cc:1075-1085` installs its Chrome client;
   CEF starts the main-thread profiler later than regular Chrome startup.
3. `chrome/common/profiler/thread_profiler_configuration.cc:43-49` defines a
   Chrome release channel only for `OFFICIAL_BUILD` **and** Google Chrome
   branding. A Release configuration of this unbranded fork takes the local
   build path. `thread_profiler_platform_configuration.cc:64-67` enables
   profiling for 100% of that population.
4. `thread_profiler_configuration.cc:61-74` specifies a 100 ms sample interval
   and a 30-second startup collection. `components/sampling_profiler/thread_profiler.cc:192-230`
   starts that collection, then schedules periodic collections.

An existing switch disables it without an engine build:
`--disable-stack-profiler`. Its definition and performance-comparison comment
are in `chrome/common/chrome_switches.h:275-278`.
`thread_profiler_configuration.cc:222-223` checks it before enabling sampling.
`App/LaunchOptions.swift` leaves unknown switches in the process command line.
The switch is used only for a diagnostic comparison in this investigation.
It has not been added to product defaults or the acceptance run.

## Scene lifetime observation

The first post-306 diagnostic state receipt shows that onboarding's controller,
intro, sound, steps, preview, miniature, model, sidebar, and icons are all
released. Welcome remains visible and plays card 3. It reports six animation
entries and a pending completion timer. Its Space demonstration has two native
miniature windows; the first contains an `OpenSidebar.PagerStrip` `slide`
animation. Thus this original row overlaps finite Welcome playback. This state
observation does not qualify the CPU timing from an otherwise invalid attempt.

The temporary `post306-noprofile-counters-r1` App counters distinguish the
responsible scene from a layout loop. Across the failing five-second window,
Welcome advances from card 2's lifted native row to card 3's two
`OnboardingMiniature` instances. Only three miniature layouts occur (less than
1.1 ms combined), no miniature theme display callback occurs, and two native
Space pages are constructed. There is no repeated miniature layout or theme
display-link wakeup. The work belongs to the finite native Welcome demonstration
on `CrBrowserMain`, rather than an onboarding object retained after handoff.
Its original four 8.5-second cards take 34 seconds, so the old ten-second
post-import delay overlaps the demonstration. That run is valid (load1
2.928 / 2.631, foreign CPU 31.9% / 32.6%) and still fails at 3.538% without
the stack profiler. All temporary counters were removed.

## Approved behavior and repair

The lead's 21:40 design ruling sets a 20-second budget for one automatic
Welcome pass. The repaired pass takes a planned 19 seconds: 4.2, 4.0, 6.8, and
4.0 seconds. It shortens holds and keeps typing cadence, native drag travel
(3.4 / 3.23 seconds), window-swipe travel (3.4 / 2.975 seconds), and easing.
Hiding the window or tab cancels automatic playback and its pending work.
Restoring it does not restart the playlist; explicit hover/click replays one
card. At rest, the cards have no animation, completion timer, or pending theme
display link.

The import idle row now waits for that work to settle, with a separate failing
row if it has not settled within 30 seconds of first appearance. It never
stops the playlist. Five-second CPU limits remain unchanged. The Welcome flow
also checks idle after completion, hides a playing window through the socket,
checks zero work within one second and five-second CPU below 1%, restores it,
and checks that only explicit replay starts motion. A fresh-launch OS thread
enumeration rejects `StackSamplingProfiler`. Open passes the existing disable
switch in its engine configuration in both ordinary and automation builds.

## Repair verification

Release candidate `e28eef3d` passes the original import flow under the revised
settle contract on the M1 (`fixed-import-r1`). Its automatic pass takes
19.065 seconds and plays cards 1–4 once. Welcome remains visible at the end,
with zero animations, no completion timer, and zero pending theme display
updates. App idle is 0.592% over the existing five-second sample. History takes
977.6 ms and main-thread lag is 18.8 ms. Pre-load1 is 1.942 / 1.803, and foreign
CPU is 27.3% before / 33.9% after the idle row. Cleanup passes with no new
crash or system window. OS counters list zero `StackSamplingProfiler` threads
in the App and helpers without a diagnostic CLI override.

The same new real-App contract rejects the old binary. `old-welcome-contract`
fails `no_stack_sampling_after_launch`. `old-playlist-contract` uses the
diagnostic switch to pass that assertion, then fails `playlist_settles` at the
30-second cap. Both negative runs clean up successfully without a new crash or
system window. Their complete private receipts remain beside the bisect data.

## Profiler and visibility controls

`post306-noprofile-isolate-r2` repeats the original row with the existing
`--disable-stack-profiler` switch. It still fails at 2.963%, with pre-load1
1.978 / 1.747 and foreign CPU 22.1% / 34.9%. libproc lists no
`StackSamplingProfiler` thread in the App or its helpers. This proves that the
switch works, and that sampling overhead is not the cause of PR 306's increase.
The default launch arguments remain unchanged.

After that row, the same probe directly miniaturizes the browser through
`window-miniaturize`. It verifies that the browser is miniaturized and Welcome
is invisible with zero animations. Over the next five-second diagnostic
interval, App CPU is 0.524% and `CrBrowserMain` is 0.023%. Restoring the browser
resumes card 3; App CPU rises to 1.909% and `CrBrowserMain` to 1.245%. Foreign
CPU remains below one core during both intervals. These visibility intervals
isolate the scene but are not separate acceptance samples: they do not repeat
the two-reading load preflight. Cleanup passes; no new crash or system window
appears. The earlier `post306-noprofile-isolate-r1` menu-minimize attempt did not
hide Welcome, so it is not visibility-isolation proof.
