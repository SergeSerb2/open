# Guarded capture harness

Status: C0 work in progress. Source compilation passed, but the first real
capture qualification produced no PNGs. Arc AX traversal timed out and the
first Open launch did not obtain foreground. The latest launch/AX changes
still need a successful C0 run. Do not treat this harness as qualified yet.

These tools contain our own source only. Raw Arc images, accessibility dumps,
window titles and URLs belong under the ignored `.re/` capture root. Never add
them to a commit. This harness does not modify Arc's bundle or preferences.

Compile the small helper before taking the screen lock:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh xcrun swiftc -O tools/capture/native.swift -o /tmp/open-capture-native
~/Library/Caches/OpenRE/scripts/heavy.sh xcrun swiftc -O -parse-as-library tools/capture/burst.swift -o /tmp/open-capture-burst
```

Run one short block per lock invocation:

```sh
/usr/bin/lockf -k -t 0 /tmp/open-onscreen-e2e.lock python3 tools/capture/session.py SCRIPT.json --backend arc --out PRIVATE/arc/BLOCK
/usr/bin/lockf -k -t 0 /tmp/open-onscreen-e2e.lock python3 tools/capture/session.py SCRIPT.json --backend open --out PRIVATE/open/BLOCK
```

The caller must hold the on-screen lock throughout launch, capture and cleanup.
Builds run outside that lock. Read the current lead rulings before each block.
`session.py` copies C's rulings into its private receipt and records their hash.
It refuses an existing Arc process or an existing Open socket. It never adopts
another session. Permissions are checked without requesting permission.

The default deadline is 170 seconds and the hard limit is 180. Each step and
event batch checks the display and the exact frontmost PID. Input stops when
another app takes focus. Cleanup sends normal quit to the captured PID. It
restores the pointer before restoring the previous app. If the user changes
the frontmost app, cleanup sends no more pointer events and does not activate
another app over the user's choice. The receipt records this interruption.
An incomplete quit is a blocker, not permission to kill an unknown process.

A script has `max_seconds`, `steps` and an `open` configuration with
`executable`, `data_root` and `socket`. Each step has `op`. Supported operations:

| Operation | Fields |
|---|---|
| `launch` | Launch the assigned backend with ownership checks |
| `wait_ax` | `target` predicate, optional `timeout` |
| `click_ax`, `hover_ax`, `down_ax` | `target`; click supports `button`, `count` |
| `key` | `key`, `modifiers` using uidrive names |
| `mouse_up` | Release a captured `down_ax` press |
| `resize` | `width`, optional `height`; AX window frame, restored on cleanup |
| `type` | `text`; requires an AX-focused text input |
| `scroll` | `target`, `dy`, optional `dx` |
| `shot`, `axdump` | `name` |
| `burst` | `name`, `fps`, `duration`, optional `trigger`, `trigger_after` |
| `sleep` | `seconds`, limited to five per step |

Predicates match `role`, `title`, `identifier`, `desc`, `help`, etc. Prefix a
string with `re:` for a regular expression. Ambiguous matches refuse input.
An explicit zero-based `index` can select a previously observed repeated item.
Click locations are the freshly resolved AX frame centers. Fixed screen
coordinates are not accepted by the script.

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
a timestamped JSONL entry. Arc context windows are captured separately when
listed as visible. Arc burst capture uses the own-window ScreenCaptureKit
stream when the compiled recorder is present. Otherwise, and for Open,
it uses serial own-window captures;
requested and actual cadence, per-capture start/end and uncertainty are saved.
Do not treat this as a high-refresh smoothness or physical scanout measurement.
Native AX traversal has a node/depth budget and a short messaging timeout.
It preserves the page's AXWebArea node but omits page descendants because this
session measures native browser controls. Truncation is marked in the dump.

`measure.py FRAME.png [--spec SPEC.json]` writes geometry and optional pixel
measurements. `measure.py BURST_DIR` writes an explicitly qualified image-change
curve fit and its residual. Region specs are documented in its help text.
Colors require an embedded ICC profile; missing profiles remain unqualified.
Corner and glyph fits are estimates, not font metadata or exact continuous
corner measurements. `compare.py ARC_DIR OPEN_DIR --out PRIVATE_DIR` makes
paired contact sheets and an evidence/gap inventory. It requires Pillow.

Verify changes with the real Arc capture and Open socket flows. Do not add
unit tests or mock the apps. Session scripts and receipts can include private
data and must remain outside this tracked directory.
