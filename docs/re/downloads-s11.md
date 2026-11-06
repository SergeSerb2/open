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
