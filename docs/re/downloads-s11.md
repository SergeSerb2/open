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

`DownloadsCenter` owns live session rows and a lazy per-Profile terminal-history
store. Active transfers are not evicted.
Settings removes finished, cancelled and failed entries
for the chosen Profile and range, using their start time. Running and paused
transfers stay in the list, and downloaded files stay on disk. Library Downloads
reads the same provider, so cleared rows disappear there too.

`OEBrowserContext.h` exposes a read-only `downloads` array (“Every download of
this context since launch”). The required main merge brought Section 10's #222
`clearBrowsingData(_:from:to:completion:)` API, whose download kind clears
engine records without deleting files. Settings now invokes that API for the
selected Profile and range, then clears the matching App rows after successful
engine completion. It preserves main's independent cookies/cache choices and
its additional Last 4 weeks range. API evidence:
`Engine/OpenEngine/include/OpenEngine/OEBrowserContext.h`; native download
removal maps to `Remover::DATA_TYPE_DOWNLOADS` in
`Engine/fork/src/open/browser/profiles/open_profile_context.cc` (Section 10,
#222).

## Persistent history and Profile filter (2026-11-09 implementation)

The existing Arc evidence establishes the Profile filter: **FACT**, the strings
`Filter Downloads` and `Download list filter - profiles section`,
`DownloadsPageReducer`, and Library Downloads filter titles are recorded in
[features-advanced DL-1 and §9.6](features-advanced.md#95-downloads).
The existing menu/action facts are in [page-chrome §4](page-chrome.md#4-downloads).
No new Arc runtime or reverse-engineering claim is made here.

Open stores terminal downloads in
`Profiles/<dataDirectoryName>/State/downloads.sqlite3`, beside Archive and History.
`DownloadHistoryStore` follows ArchiveStore's private serial queue and
FULL-synchronous SQLite transaction pattern. The insert and pruning commit
together. The file keeps the newest **1,000 terminal rows per Profile**, ordered
by end time with a stable ID tie-break. The data includes display name, source
URL and host, local path, received and total bytes, start/end times, terminal
state, and Profile ID. Live identifiers include a launch UUID so the engine's
numeric IDs cannot collide with records from another launch.

The store refuses a database or SQLite sidecar above **32 MiB** before opening
it, caps SQLite page growth to 32 MiB, runs `quick_check`, and refuses unknown
schema versions, more than 1,000 decoded rows, invalid terminal states, invalid
Profile ownership, and oversized fields. A JSON row has a 96 KiB limit; names,
IDs, source URLs, hosts and local paths also have separate limits. SQLite's
value/row allocation limit is 100 KiB, set before its first schema read. Errors appear
in the Downloads section. A failed read returns no partial page. Damaged files
are kept for recovery, and a failed write does not hide the live row.

There is no history read during launch. Opening Library ▸ Downloads loads each
Profile once on the store queue. Live session rows come first; stored rows whose
IDs already have session entries are suppressed. Remove/clear generations reject
stale in-flight reads. File existence checks run on the file actor when Library
opens or regains focus, and before file actions. No file watcher or idle timer is
added. Regular-context guards refuse ephemeral contexts and contexts with an
`originalContext`; Incognito keeps its separate destination-only path.

Historical rows reuse Open/Copy/Show in Finder/Move to Trash/Hide from Open and
offer the existing **Retry** action for their source URL under the recorded
Profile. **Open wording, unproven in Arc:** `File moved or deleted.` is the
existing Open missing-file subtitle. Missing rows disable file actions and stay
removable and retryable. The Profile menu appears with two or more Profiles.
`All Profiles` and Profile names reuse the existing Library choices; exact Arc
menu geometry remains unverified.

Settings' Downloads choice clears the selected Profile and start-time range
after the engine clear succeeds; it waits for the store commit before reporting
Done. Downloaded files and active transfers remain. Hide/Trash removals also
delete the stored row. Quit drains accepted history writes. Approved quit
cancellations enter the history before the engine shuts down. The registered
`ProfileDataOwner` retires the queue and closes its database before Profile
deletion removes the folder, so pending work cannot recreate it.

### Verification state

**Ready for first build; runtime acceptance is pending.** The S11 lead's disk
hold (03:39) forbids builds and verify-all until explicit clearance. The M5 and
M1 screen holds also remain active. Only source review, `git diff --check`, and
in-memory Python syntax parsing were performed. No Open or Arc launch, render
run, compiler run, defaults command, debugger, or crash probe was performed.

The existing `tools/e2e/downloads.py` now has `history` and `history-errors`
diagnostic cases. The suite uses its own bundle/domain and transient launch
arguments for quit-preference variants; it issues no `defaults` commands. All
rows below are **NOT RUN**, including negative proofs:

| Pending real-App row | Coverage written |
|---|---|
| Two Profiles and relaunch | Real transfers; same root; stable IDs; terminal states and metadata persist; no duplicate rows |
| Profile filter | Hidden with one Profile; native menu with two; first, second and all Profile choices |
| Private downloads | Real Incognito transfer reaches disk but neither store nor relaunched list contains it |
| Historical actions | Real file opener receipt, copy URL, recorded reveal, retry URL/Profile and Trash |
| Missing file | Delete fixture file; reopen Library; missing subtitle, disabled file actions, removable row |
| Remove and clear | Hide/Trash; Last hour with an older survivor and another Profile; All time; relaunch after each |
| Profile deletion | Real typed Settings sheet; folder and rows stay absent after Library reopen and relaunch |
| Bounds and corruption | 1,000-row file accepted; new terminal prunes oldest; 1,001 rows, invalid record, corrupt SQLite and 32 MiB + 1 byte file refused; valid file restored |
| Existing downloads regression | Controls, destination uniqueness/fallback, native save sheets, per-Profile destination, badge/idle, clear ranges and quit |

After both holds end, build only through the requested S11/heavy wrappers with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Run one downloads suite
per on-screen lock invocation with `OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`.
The new diagnostic selection is `OPEN_DOWNLOADS_CASE=history,history-errors`.
Then run the full downloads suite and the affected off-screen settings checks.
If the second-Profile callback is missing, compare the existing `profiles` case
on unchanged main before attributing it to this change. That comparison and
break-and-revert negative proofs remain pending with the screen hold.

Source review against `docs/review-checklist.md`: input bounds, transaction and
queue ordering, private-context exclusion, stable IDs, and Profile-owner teardown
were reviewed. Runtime lifetimes, native control presentation, limits/corruption
acceptance, quiet idle behavior, and negative proofs remain **UNVERIFIED**. No
new dependencies or engine patches were added.
