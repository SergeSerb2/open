# Guarded capture harness

Status: both backends passed the C0 capture-path smoke. Arc produced native
window PNGs, a complete Library tree and an AX-resolved Home press; Open used
only its real socket. C1 is complete for lead review, with explicit uncaptured
states in the private handoff. Earlier failed attempts
remain in the private receipts. Motion fits are image-change guesses; static,
sparse and changing-window recordings do not qualify layer animation.

These tools contain our own source only. Raw Arc images, accessibility dumps,
window titles and URLs belong under the ignored `.re/` capture root. Never add
them to a commit. This harness never modifies Arc's bundle. Temporary UI
appearance changes require an observed original state and verified restoration.

Compile the small helper before taking the screen lock:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh xcrun swiftc -O -swift-version 6 tools/capture/native.swift -o /tmp/open-capture-native
~/Library/Caches/OpenRE/scripts/heavy.sh xcrun swiftc -O -swift-version 6 -parse-as-library tools/capture/burst.swift -o /tmp/open-capture-burst
```

Run one short block per lock invocation:

```sh
/usr/bin/lockf -k -t 0 /tmp/open-onscreen-e2e.lock python3 tools/capture/session.py SCRIPT.json --backend arc --out PRIVATE/arc/BLOCK
/usr/bin/lockf -k -t 0 /tmp/open-onscreen-e2e.lock python3 tools/capture/session.py SCRIPT.json --backend open --out PRIVATE/open/BLOCK
```

For the M1, use the same runner through the lead's `m1.sh` transport:

```sh
python3 tools/capture/session.py SCRIPT.json --host m1 --prepare-only --out PRIVATE/m1-preflight
python3 tools/capture/session.py SCRIPT.json --host m1 --backend arc --out PRIVATE/arc/M1-BLOCK
```

Preparation compiles both Swift helpers through the M1's `heavy.sh` and reads
permissions/display state without launching Arc or Open. It uses the existing
`~/Applications/OpenCapture.app` to check the pixel grant. AX and input run in
the direct SSH process. Only pixel readers run under that fixed launcher; it
is never rebuilt, re-signed or replaced. Capture refuses to launch
until the supplied `--rulings` file contains an explicit `## LEAD ... M1 capture
ready` heading (or a standalone readiness line), and both permission contexts
pass. An active lead M1 screen HOLD also blocks preparation/capture until a
later M1 clear heading. Read all current rulings before starting a block.
The remote invocation takes the M1's screen lock itself; do not hold the M5
screen lock while it waits. Source, script and rulings are staged together in a
unique private M1 directory. Raw results are copied into `--out`; remote
originals remain available if transfer fails. `--remote-root` sets an absolute
M1 staging root. Open scripts must name an executable/data/socket on that host.
Host and display metadata stay with each block; do not combine M1 and M5 frames
into one display qualification.

The caller must hold the on-screen lock throughout launch, capture and cleanup.
Builds run outside that lock. Read the current lead rulings before each block.
`session.py` copies C's rulings into its private receipt and records their hash.
It refuses an existing Arc process or an existing Open socket. It never adopts
another session. Permissions are checked without requesting permission.

Work stops at 150 seconds to reserve cleanup time within the 170-second block.
A receipt over 170 seconds or incomplete restoration/quit fails the block. Each step and
event batch checks the display and the exact frontmost PID. Input stops when
another app takes focus. Cleanup sends normal quit to the captured PID. It
restores the pointer before restoring the previous app. If the user changes
the frontmost app, cleanup sends no more pointer events and does not activate
another app over the user's choice. The receipt records this interruption.
An incomplete quit is a blocker, not permission to kill an unknown process.

The isolated Downloads-consent block can set `download_prompt_handoff: true`.
It requires the recorded LEAD18:50 ruling before launch. If a system prompt
appears after that block requests its synthetic download, all input stops and
cleanup leaves the exact owned Arc PID running for the user. It writes
`arc-permission-handoff.json`, skips pointer/app restoration and returns a
nonzero incomplete-capture status. This exception preserves the consent prompt;
it does not grant permission to answer it or to launch a later block. The
screen lock is released, and the lead receives the time/PID and a pending
question. The prompt-handoff path still needs real-flow qualification.

A script has `max_seconds`, `steps` and an `open` configuration with
`executable`, `data_root` and `socket`. Each step has `op`. Supported operations:

| Operation | Fields |
|---|---|
| `launch` | Launch the assigned backend with ownership checks |
| `wait_ax` | `target` predicate, optional `timeout` |
| `click_ax`, `show_menu_ax`, `focus_ax`, `set_ax`, `select_ax`, `cancel_ax` | `target`; AX actions, `set_ax` takes `text` |
| `hover_ax` | `target`; pointer movement |
| `down_ax` | M1 only: fresh `target`, `name`, `expect: "change"`; optional `drag: true` starts an eight-point maximum drag inside that target; pair with `mouse_up` |
| `pointer_ax` | M1 only: fresh `target`, `name`, `expect: "change"` or `"menu"`, optional `button`/`count`; stop if no result within two seconds |
| `ensure_window` | Read AXWindows/main window and all CG windows; if empty, press New Window through AX |
| `ensure_surface` | `surface: "library"` or `"browser"`; resolve the current Library menu title and verify the native rail |
| `key` | `key`, `modifiers` using uidrive names |
| `mouse_up` | Release a captured `down_ax` press |
| `resize` | `width`, optional `height`, or `original: true`; AX window frame, restored on cleanup |
| `type` | `text`; requires an AX-focused text input |
| `scroll` | `target`, `dy`, optional `dx` |
| `shot`, `axdump` | `name`; shots can set `ax_depth` for an explicitly partial native tree |
| `burst` | `name`, `fps`, `duration`, optional `trigger`, `trigger_after` |
| `sleep` | `seconds`, limited to five per step |
| `fixture_download` | Serve one tiny synthetic loopback attachment; no personal content; owned server stops during cleanup |

Predicates match `role`, `title`, `identifier`, `desc`, `help`, etc. Prefix a
string with `re:` for a regular expression. Ambiguous matches refuse input.
An explicit zero-based `index` can select a previously observed repeated item.
Click locations are the freshly resolved AX frame centers. Fixed screen
coordinates are not accepted by the script.

Control actions prefer AXPress/AXShowMenu/AXFocused/AXValue/AXCancel; hover,
drag and scroll use the pointer helper. LEAD19:30 permits pointer clicks and
limited navigation keys on the M1 when AX has no working action. The runner
requires that recorded ruling and the M1 hostname. Each pointer click resolves
the target again, checks containment in an owned AX window, and checks the
current CG window ordering at its centre. A foreign covering window or any
visible system-consent window stops input. Named before/after frames preserve
the expected change or menu; a missing result after two seconds stops the block.
With the recorded LEAD19:52 ruling on M1, the guard excludes Dock windows,
negative-layer Notification Center widgets and negative-layer WindowManager /
Window Server desktop elements. It records their IDs. Positive system windows
still stop input. A Notification Center banner over the point permits two
six-second waits, with a fresh AX target and ownership check after each wait.
LEAD00:15 additionally excludes Window Server's cursor window only at layer
2147483630 with positive dimensions at most 64×64 points. Other positive-layer
windows keep their existing blocking checks. Ignored IDs and bounds are logged.
LEAD20:32 permits an owned drag image during our held gesture when it first
appears within one second and its drawn content is at the pointer. The runner
records AX/CG metadata and the transparent image bounds. Other new windows
still stop the block. A stop while our button is down sends Esc to the owned
foreground Arc, then releases our pending button before quit or handoff.
The observed thin Arc drag-target windows do not meet the image exception;
those states remain a documented capture limit. The same ruling permits AX
Quit TextEdit cleanup for files opened by this session. The native helper
requires only synthetic capture document titles and permits only Quit TextEdit
or the explicit save-sheet discard controls for those documents.
Image change alone does not prove selection or preview: inspect the saved
pixels and AX before accepting that state. Typing is limited to synthetic
capture strings in a focused Library search field. M5 synthetic clicks and
keys remain disabled. An optional AX action may record an unavailable target or
unsupported action as not captured. Focus loss and AX messaging failures still
stop the block. Screenshots carry accumulated capture gaps in their metadata.
Menu labels can change with window state. Resolve a currently observed stable
identifier where available, and retain the actual label in the action receipt.
An AX action can carry `restore: {target: PREDICATE, original: PREDICATE,
action: "AXPress"}` for a previously observed original menu state. `original`
must match exactly once before any temporary change is sent. Cleanup checks
that state, restores it when needed and polls it for up to two seconds before
quitting, with the same frontmost-app guard. Under LEAD19:30 an M1 appearance
checkmark miss is a receipt note; other cleanup failures still fail. Use this
for temporary appearance changes. The
Open backend saves/restores its app appearance through the socket separately.

Open input goes only through its automation socket. A step's `open` field is
one socket action (`cmd`, optional `args`) or a list of actions. Unsupported
steps are recorded as `Open: no action`. This indicates an automation gap;
it does not prove a missing product feature. Open snapshots retain its real
window geometry, accessibility text and existing per-surface state commands.
The socket does not currently return a full generic AX tree with element frames.
That limitation is explicit; the harness does not substitute system input.
For an existing Library section, `open` may specify `cmd: "mouse"`,
`lookup: "library-section"`, and `section`. The click then uses the point from
the real `space-manager-lifecycle` snapshot, not fixed coordinates. The Home
entry uses `download-home`, which invokes that real control's AX press action.

Each shot includes a native-scale own-window PNG, AX/state JSON, metadata and
a timestamped JSONL entry. Arc records AX before and after the PNG, and flags a
surface change across the capture. Frame names alone never prove state. Arc
context windows are captured separately when listed as visible. Arc bursts and
M1 Open bursts use the own-window ScreenCaptureKit stream when the compiled
recorder is present. `scope: "application"` selects only that process's windows
on the captured display. Use it for creating, closing or promoting a window;
an individual window stream ends when that window closes. Stills remain window
only. `format` is `png` or `movie`. A recorder that stops early retains an
interrupted receipt; a movie without finalized timestamps stays unqualified.
Bursts accept `ax_depth` for their before/after snapshots. A pointer trigger
reuses that before frame, then resolves its AX target and checks ownership
again. It does not take another full snapshot before dispatch. New stream
receipts map capture PTS to the same host's wall clock. `capture-context.json`
records dispatch intervals and requires at least 100 ms of recorded coverage
after them. An unavailable Open trigger remains an explicit no-action gap.
An interrupted trigger remains unqualified. A late trigger stops the block; `measure.py` refuses its motion fit. This
clock mapping proves capture coverage only. It does not measure input latency
or prove that an animation is visible; inspect the decoded frames as well.
Other captures use serial own-window snapshots;
requested and actual cadence, per-capture start/end and uncertainty are saved.
Do not treat this as a high-refresh smoothness or physical scanout measurement.
Native AX traversal has a node/depth budget and a short messaging timeout.
It preserves the page's AXWebArea node but omits page descendants because this
session measures native browser controls. Truncation is marked in the dump.

`measure.py FRAME.png [--spec SPEC.json]` writes geometry and optional pixel
measurements. `measure.py BURST_DIR` writes an explicitly qualified image-change
curve fit and its residual. A burst spec can add `motion_edge: {roi_pixels:
[x,y,width,height], axis: "x", pixels_per_point: 1}` to track a visually
identified pixel edge and fit its position in points with an RMS residual.
This does not identify an app layer or measure its opacity. Region specs are
documented in its help text.
Colors require an embedded ICC profile; missing profiles remain unqualified.
Corner and glyph fits are estimates, not font metadata or exact continuous
corner measurements. `compare.py ARC_DIR OPEN_DIR --out PRIVATE_DIR` makes
paired contact sheets and an evidence/gap inventory. It requires Pillow.
Only complete named shots with metadata are compared; interrupted burst PNGs
are excluded. Contact sheets use one common image scale for both sides and
mark preceding unavailable actions. Original raw receipts remain separate.
Saved Arc search placeholders/card structure identify the Library section;
Open's recorded socket state identifies its section. Different captured states
are explicit even when the filenames match. A matching name alone does not
qualify a same-state comparison.
Derived selections can retain per-frame source actions in
`capture-qualifications.json`; original blocks remain the source of truth.

Verify changes with the real Arc capture and Open socket flows. Do not add
unit tests or mock the apps. Session scripts and receipts can include private
data and must remain outside this tracked directory.


## Synthetic follow-up sessions

Session2 requires `capture_scope: "session2"` and the recorded LEAD23:45 ruling.
It retains the M1 exact-PID, CG window, system-dialog and block guards. `key`
modifiers are arrays, for example `["cmd"]`. Unsupported modifier formats stop
before input. The added navigation shortcuts cover New Tab, edit URL, Find,
pin and close; callers must first establish a synthetic page context.

`fixture_site` starts two owned loopback servers (default ports39171/39172).
They serve only original synthetic HTML, SVG favicons and text attachments.
`{{fixture}}` and `{{other}}` in subsequent steps expand to those loopback roots.
`external_fixture` permits only those roots and uses the existing external-link
route without changing routing preferences. Servers close during cleanup.
The same site runs for the Open replay; Open input remains socket-only.

Declare `synthetic_input_targets` from observed AX predicates and a literal
`synthetic_inputs` list. Typing requires the actual focused native text field
to match a declared predicate and the text to match that list. `focused_dump`
saves that single AX element. It does not traverse page descendants. A target
with `source: "focused"` uses the current focused element, for example a link
reached by Tab on the fixture page. Pointer input still checks its fresh AX
frame and the CG ownership guard; no stored page coordinates are accepted.
Long typing uses at most96 characters per event batch, with ownership and
focused-field checks between batches.

`paste` verifies the same synthetic field/text conditions, preserves the
clipboard privately, writes only the synthetic string, and posts Cmd+V to Arc.
It checks the focused field consumed the paste, then immediately restores the
clipboard if its change counter still matches our write. Cleanup retries a
pending restore. The private preservation file is removed before transfer.
A changed clipboard fails restoration instead of overwriting another change.
No clipboard contents are written to the action log.
`copy_fixture_url` takes `url`, verifies it in the actual current URL field,
and presses the observed Copy URL menu item. It verifies only the expected
synthetic URL, then restores the preserved clipboard under the same counter
guard. This supports a copy-feedback movie without retaining clipboard data.

The narrow LEAD00:00 ruling permits `manual_accessibility` only while the actual
current URL field matches the owned fixture. It records and restores the
process's AXManualAccessibility Boolean. With LEAD00:15 it records a write-only
original as unreadable, restores false explicitly and verifies the set-call
success; it never invents an original false value. `fixture_web` queries only the matching active AXWebArea, capped at
3000 nodes,30 levels and3seconds. Other pages are never descended into or saved.
`source: "fixture"` resolves a target there. A `remember` name holds only its
same-block geometry in memory. `source: "fixture-remembered"` may reuse it with
accessibility off only when the owned window geometry and active synthetic URL
are unchanged. CG ownership checks still run before the click. Frames and
movies state whether accessibility was on. Nothing changes AXEnhancedUserInterface.

Scripts are bounded to256KiB,300 steps,10000 values,20 nesting levels and2048
characters per string. Evidence names use safe short filenames. Automation
replies are capped at8MiB. Burst measurement accepts at most1000 frames and
20million pixels per frame, reads native frames one at a time, and retains only
small comparison thumbnails. These are capture-tool limits, not product limits.

## Session 3 additions

`capture_scope: "session3"` keeps every Session 2 guard and adds:

- `series.py` + `session.py --series A.json B.json …` (M1): one strict queue ticket
  (`heavy.sh /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock series.py`) runs several blocks, each still
  ≤ 170 s with its own launch/quit. A series stops at 15 minutes. After a script-level stop (missing or ambiguous
  AX target, unqualified movie, missing expected result) the next independent block runs; any guard stop ends the
  series. Changed Swift helpers compile inside the ticket. An Arc left running after a block (a modal dialog that
  refuses the normal quit) is ended with SIGTERM to that PID and recorded in the series receipt.
- `drag_ax` (`target`/`at`/`offset`, `to`/`to_at` or `by`, optional `hold_shot`, `kind: "divider"`): a full
  AX-anchored drag. Tab drags accept only Arc's own drop-target rails and drag layer first seen within 1 s of the
  first move (LEAD 13:00) and drop ≥ 20 pt from both rails; divider drags start on the sidebar edge.
- `swipe_ax`: phased, continuous pixel scroll (began/changed/ended, optional momentum) at a verified point.
- `at` fractions for `pointer_ax`/`hover_ax`; hover moves pass the same point guard as clicks.
- `expect: "selected"` for sidebar rows; `min_change` for subtle pixel changes; `click_ax` `action`
  (`AXIncrement`, `AXDecrement`, `AXShowMenu`, …) with `repeat`.
- Predicates: `anc` (ancestor role path), `min_h`/`max_h`; neighbouring Spaces' off-screen sidebars are excluded.
- Point guard: the LEAD 11:32 rule for the full-screen Notification Centre host of a persistent alert (AX alert
  frames read, 40 pt clearance, Arc next below, frames must not change).
- `allow_boost_editor`: the LEAD 18:00 capture-first rule for Arc's Boost editor panel (AXSystemDialog with Boost
  controls and no sign-in/account/permission text).
- Open snapshots also record `theme-get` and `sidebar-tree`. The fixture serves `/audio` (a quiet looping tone) and
  `/media` (link, image, selectable text).

## Session 4 additions

- `drag_ax kind: "canvas"`: a drag that stays inside the page area right of the sidebar (Easel drawing, capture area).
- Under session-3 scope, typing may target a focused `AXTextArea` (Easel title and text boxes) with the same
  declared-target and declared-text checks.
- Key allowlist adds ⌘= / ⌘− / ⌘0 (canvas zoom) and the Note shortcuts ⌃⇧N / ⌃⌥N / ⌃⇧E.
- `shot()` reuses a remembered window only while it is on screen (capture overlays close mid-block).
- An unfocused synthetic field is a script-level stop (exit 3), so the next independent block still runs.

## Sessions 5–9 additions

All of these need `"capture_scope": "session3"` and the lead rulings named in the code. Each one stops instead of
guessing.

- `deep_link` — runs `/usr/bin/open URL` for a URL on the `DEEP_LINKS` allowlist only.
- `open_cover` / `open_uncover` — start an owned capture build of Open on a **new, empty** data folder, place its
  window over Arc's window through the automation socket (`window-frame`, `activate`), and end it with SIGTERM to
  that exact PID. No input event goes to Open.
- `arc_windows` — window list plus one frame for every visible Arc window (menus, popovers, PiP).
- `pip_window_exception` + `pip_title_re` (script keys) — record, never click, one Arc-owned `AXSystemDialog` window
  that has an empty or matching title, no text field or sign-in/allow/OK button, a layer above 0, and less than half
  the screen. Every other dialog still stops the block.
- `pointer_ax` — `modifiers` (`cmd`, `opt`, `shift`) for ⌘-click selection, and `expect: "observe"` for a right-click
  that may open no menu (the result is recorded, the block continues).
- `modkey` — Option down/up while an owned menu is open; released again in cleanup.
- `arc_log` — a read-only `log stream` of the owned Arc process with `mark` labels (sound mapping).
- A guard stop on a dialog now saves the owned app's AX windows and CG window list (passive reads).
- Fixture: `/video` (muted canvas stream), `/download.pdf`, `/large.bin` (8 MiB over about 60 s) and `/fail.bin`
  (announces 4 MiB, closes after 512 KiB). All content is synthetic filler.

Menus of the Library sections have no AX items. Read their titles from the `*-window-<id>.png` frames.
Keep Arc 1080 pt wide (right edge at x 1100) when a target is near the macOS alert at the screen's top right.
