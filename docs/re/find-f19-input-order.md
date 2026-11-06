# F19: synthetic click left AppKit tracking a control gesture

The failure is in the e2e click sequence. F19 now uses the existing
`mouse queued=True` path. The product's Find implementation is unchanged, and
F19 still requires the visible count to become exactly `1/2` after Return.

## Runtime evidence (2026-11-06)

Real Debug Open, engine framework SHA-256
`af4b3cc3ad1b42439b229d79c8f7a869b13b0d3165733fba6c023e202340d1a5`,
AW2726DM at 1x. Each valid launch set
`OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`; preserved raw launch logs confirm
`OpenEngine: automation macOS notification setup skipped`. Interrupted runs
were excluded. These are new reproductions, independent of the lead's soak.

The stress flow repeats the real F17–F19 tab switch, navigation, Find-field
click and Return. Navigation waits for the exact new URL and
`document.readyState === "complete"`. Cheap in-process probes record dispatch
boundaries and dump only when Return does not reach the field editor.

| Probe | First failed cycle (zero based) | Evidence under `.re/find-f19/` |
|---|---:|---|
| Editor/request counters | 37 | `first-failure.json`, `first-failure.log` |
| Local monitor consumption | 16 | `stress-monitor-01.json` |
| Application/window/editor boundaries | 26 | `drop-probe.log`, `stress-dispatch-01.json` |
| Window's internal dispatch boundary | 145 | `deep-drop.log`, `stress-deep-01.json` |
| AppKit gesture filtering | 75 | `gesture-drop.log`, `stress-gesture-01.json` |
| In-memory event-order ring | 216 | `order-drop.log`, `stress-order-01.json` |

In each failure, Find retained `orbit`, owned first responder before and after
Return, and had zero new requests and results. The editor's Return count did
not increase. There was no new navigation revision during Return. Thus the
Find controller did not issue a request and then discard its result.

`gesture-drop.log` shows
`_NSGestureEnvironmentBase.sendEventToGestureRecognizers:requireAcceptsFirstMouse:`
returning nil for Return. Its active recognizer was `NSControlGestureRecognizer`
on `FindQueryField`, in `Began`, with `delaysPrimaryMouseButtonEvents = YES`.
`NSWindow.sendEvent` returned before `_reallySendEvent:isDelayedEvent:`,
`NSTextInputContext.handleEvent`, or `FindFieldEditor.keyDown` ran. A local
application event monitor did not consume Return.

The event ring distinguishes this from a navigation or field-editor race.
Successful cycles show application dispatch of down, up, then Return. In the
failed cycle, records 3878–3883 show direct mouse-down enter and leave; records
3884–3886 show Return enter the window and gesture filter. There is no
application dispatch of mouse-up between them. Return was injected while the
control gesture still tracked the click. `NSApp.currentEvent` was mouse-up,
rather than the directly injected key. The ring does not establish whether the
missing up was still queued or was taken by a nested tracking loop.

The old helper (`AutomationController.sendMouse`) posts up first, then directly
calls `NSApp.sendEvent(down)`. It also stamps up before down. Native clicks
arrive through the event queue in down/up order, with each dequeued event as
`NSApp.currentEvent`. F19 now queues both halves and waits for up delivery using
the existing helper. With this single change, 500 consecutive stress cycles
passed, at starting load 6.06/8.11/8.87, with no interrupted attempts or failed
row (`stress-queued-click-01.json`). Broad socket/event logging also produced
500 passes on the old path, so it was not used as evidence of a fix.

## Deterministic negative control

`tools/e2e/find-input-order-probe.m` is loaded only when the Find suite runs with
`OPEN_FIND_INPUT_ORDER_NEGATIVE=1`. For a direct synthetic down on the `orbit`
field, it takes the already queued up and dispatches it before down. This forces
the invalid ordering at the old helper's scheduling boundary. It never handles
or consumes a key. Queued native down is the application's current event and
bypasses the hook.

Run the normal Find suite with that variable and `--keep`. To break the fix,
remove only `queued=True` from the F19 field click in a temporary copy of the
suite. The original `1/2` assertion must fail, and the raw launch log must contain
`F19_FORCE early mouse-up before direct mouse-down`. Restore the queued click
and repeat with the same probe: F19 must pass. The normal suite needs no probe.
The task's private proof driver retains copies of raw launch logs before the
harness's later stale-run sweep can remove kept run directories.

Three separate old-click controls failed only F19, with no interrupted attempt
and successful owned-process cleanup: `negative-old-01.json`,
`negative-control-old-01.json`, and `negative-control-old-02.json`. The fixed
click passed with the same hook (`negative-control-fixed-01.json`). These
controls run the real setup through F19 with one timing window; the normal
suite retains its twenty-window timing gate and all later checks.
