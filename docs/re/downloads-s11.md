# Downloads evidence follow-up (2026-11-05)

Target: Arc 1.170.0 (89123). This is read-only static evidence. No Arc launch,
user-data read, or runtime observation was used.

| Status | Finding | Evidence |
|---|---|---|
| FACT | `shouldWarnBeforeQuitting` is a registered preference key. This registration does not establish a warning window or its text. | Shared `ArcMain` snapshot, `FUN_1005a4098`, assignment at `0x1005a427c` onward to string `0x10396ba70`. |
| FACT | `onShouldWarnBeforeQuitting` occurs in an action renderer. This scan did not identify a generic quit-warning presentation. | Shared snapshot `FUN_100ff5350`, references `0x100ff55fc`–`0x100ff57cc` to `0x1039975d0` / Swift string form `0x1039975b0`. |
| UNVERIFIED | Ring diameter, inset and stroke were not established by the `HomeButtonBadgingConstants` string reference. Open uses the lead's explicit guess: 32 pt plate, 2 pt inset, 2 pt stroke. | `FUN_1026aaa68`, `0x1026ab270` / `0x1026ab290`, HomeBadging.HomeButton initialization and Combine subscriptions. Type presence is not a geometry measurement. |

Command (after `source tools/rea-env.sh`; installed Ghidra is 12.2, so the
stable `/opt/homebrew/opt/ghidra` path replaces the stale 12.1.4 path):

```sh
/opt/homebrew/opt/ghidra/libexec/support/analyzeHeadless \
  "$OPEN_GHIDRA_DIR" ArcMain -process Arc-arm64 -noanalysis -readOnly \
  -scriptPath ~/Library/Caches/OpenRE/ghidra-scripts-s11 \
  -postScript S11Strings.java "$PWD/.re/downloads/quit-badge.txt" \
  '3|shouldWarnBeforeQuitting' '3|onShouldWarnBeforeQuitting' \
  '3|HomeButtonBadgingConstants' '2|DownloadProgressBadge'
```

The log confirms “Processing read-only project file” and “Discarding changes”.
Ghidra reports its existing missing AppleSilicon `swift` compiler specification
and uses the default. No analysis/import or project modification was requested.
Raw decompilation remains in `.re/downloads/` only. Generic quit-warning UI is
not implemented. Download-warning strings and completion timings come from
[page-chrome §4](page-chrome.md#4-downloads).

## Quit-warning setting consumer audit (2026-11-07)

**Result: INCONCLUSIVE.** The traced download-warning presentation does not
establish a gate on `shouldWarnBeforeQuitting`. Open therefore keeps its
download-specific alert for both values of `open.general.warnBeforeQuitting`.
No generic warning UI is proved or implemented. Automation owner-death quit
continues to cancel transfers without a prompt.

| Status | Finding | Evidence in the shared, read-only `ArcMain` snapshot |
|---|---|---|
| FACT | The quit path checks an aggregate condition, resolves a presentation window, then calls an indirect policy with argument `0xb`. A false result enters the download-alert subscription; a true result takes another branch. | `FUN_10023e994`: aggregate call `0x10023ea30` → `FUN_10023e55c`; window resolver `FUN_100101b7c`; subscription call `0x10023edb4` → `FUN_100232938`. The dependency closure comes through `FUN_1006f2ba0`. |
| FACT | The subscription supplies a closure that directly enters the downloads alert presenter. The presenter constructs the exact title, cancellation body and Close/Keep buttons recorded in page-chrome §4; it does not directly read the warning preference. | `FUN_100232938`, closure reference at `0x1002329c0` → `FUN_100240140` (`0x100240140`–`0x100240144`) → `FUN_100232ae0` → presentation helper `FUN_100fc5d64`. |
| FACT | The aggregate condition iterates a collection and calls a method at vtable offset `0x108`. It does not directly read the warning preference in this recovered function. | `FUN_10023e55c`, shared-snapshot listing/decompilation. The meaning of the indirect method is not established by this trace. |
| INCONCLUSIVE | Neither the indirect policy argument `0xb` nor its dependency closure is proved to mean `shouldWarnBeforeQuitting`. The registration and action renderer above prove names, not a binding to this quit path. An absence of a direct read is not proof that no upstream gate exists. | Compare the caller/subscription chain above with preference registration `FUN_1005a4098` (`0x1005a427c` onward) and action renderer `FUN_100ff5350` (`0x100ff55fc`–`0x100ff57cc`). |

Commands, after `source tools/rea-env.sh` and selecting the installed Ghidra
12.2 path (no import, analysis, debugger, Arc launch, or project write):

```sh
GHIDRA_HEADLESS_MAXMEM=16G /opt/homebrew/opt/ghidra/libexec/support/analyzeHeadless \
  "$OPEN_GHIDRA_DIR" ArcMain -process Arc-arm64 -noanalysis -readOnly \
  -scriptPath ~/Library/Caches/OpenRE/ghidra-scripts-s11 \
  -postScript ListingDecomp.java "$PWD/.re/settings-consumers/quit-initial.txt" \
  100232ae0 1005a4098 100ff5350
# Same read-only invocation, with these scripts/arguments:
# DataRefs.java quit-refs.txt 100240140 100232ae0
# DataRefs.java quit-upstream.txt 100232938
# ListingDecomp.java quit-gates.txt 10023e55c 100101b7c 1006f2ba0 10023e994
```

Successful logs say “Processing read-only project file” and “Discarding
changes”. One overlapping request was refused with “Unable to lock project”;
it was retried after the earlier read finished. Raw output stays in `.re/`.

## Clear download history

`DownloadsCenter` owns a bounded, session-only list; the App has no persisted
download-history store. Settings removes finished, cancelled and failed entries
for the chosen Profile and range, using their start time. Running and paused
transfers stay in the list, and downloaded files stay on disk. Library Downloads
reads the same provider, so cleared rows disappear there too.

`OEBrowserContext.h` exposes a read-only `downloads` array (“Every download of
this context since launch”). The required main merge brought Section 10's #222
`clearBrowsingData(_:from:to:completion:)` API, whose download kind clears
engine records without deleting files. Settings now invokes that API for the
selected Profile and range, then clears the matching App rows after successful
engine completion. It preserves main's independent cookies/cache choices and
its additional Last 4 weeks range.
