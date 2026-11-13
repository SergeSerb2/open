# Cross-window page preservation — parked for 1.1

Status: deferred by the lead's 22:00 ruling on 2026-11-12. This branch
contains an investigation only. No engine API, shell transfer implementation,
or new e2e row has been added. There is no active request for E3.

Branch: `ns/nt-live-tab-transfer`, based on main `6328035d`.

## Current behavior

Blank Window drag works in both directions. The destination gets a new model
tab and loads its URL. The original host closes. Moving a Blank Window tab to
a Space takes the same approach. Page state therefore does not survive.

Evidence: `App/BlankWindow.swift:150–154`, `:165–170`, and `:178–182` on the
base commit. These paths create a model tab, then close the source host through
`releaseTabToAnotherWindow`.

## Why a shell-only view move is insufficient

`EngineWebContentHost.view` exposes `OEWebContent.view`.
`WebContentContainer.takeHost(for:)` can remove a cached host without closing
it. Its `adopt(_:for:)` method binds the host to container callbacks. The
factory's `adoptHost(_:as:)` currently accepts only its own hosts. A future
transfer must update factory ownership, model membership, tab and Space IDs,
and window-specific presenters and callbacks.

The engine also owns the actual hosted tab:

- `Engine/OpenEngine/src/OEBrowser.mm:379–386` refuses insertion when the
  content's actual host browser is another window's browser.
- `removeWebContent` at lines 404–415 removes strip bookkeeping but keeps the
  actual host owner. `oe_syncTabStrip` at lines 546–576 only orders and
  activates pages owned by that browser.
- `Engine/OpenEngine/src/OEWebContent.mm:581–600` creates the hosted tab in
  its original hidden browser strip and sets its host owner.
- `OEBrowser.close` at lines 469–499 closes its underlying strip. Reparenting
  only the NSView could leave the page subject to source-window teardown.

## Proposed OpenEngine API for 1.1

The destination `OEBrowser` needs a main-actor operation:

```objc
- (BOOL)transferWebContent:(OEWebContent*)webContent
              fromBrowser:(OEBrowser*)source
                  atIndex:(NSUInteger)index
    NS_SWIFT_NAME(transfer(_:from:at:));
```

The operation must move the existing hosted Chrome tab between open browsers
of the same `OEBrowserContext`. It must keep the page, native view, engine and
chrome.tabs IDs, JavaScript document, form values, history, scroll, and media
state. It must update actual engine ownership and both strip memberships.
Pending strip changes must be flushed before transfer. Existing APIs can then
apply destination pinning and selection, and the shell can reparent the view.

An empty destination and a source losing its last tab must work. Closing the
source afterwards must not close or mark the moved page as closing. Failure
must leave both sides intact and return `false`; a reload is not a successful
transfer. Reject wrong ownership, mismatched contexts, closing objects, and
unsupported content. Lifecycle callbacks must not interrupt the shell's
ownership transaction synchronously. The public header must state that rule.

## Remaining work

E3 would implement the engine operation under a future 1.1 assignment. NT
would then transfer shell host ownership for Blank Window drags and the
same-Profile Move to Space route. Cross-Profile moves need separate handling.
The Swift shell must continue to use only OpenEngine APIs.

Add a real-App socket row that types text into a synthetic loopback form,
records a document nonce and content identifier, and drags normal → Blank
Window → normal. Assert that the text and both identities survive each move.
Cover closing an emptied source window and a refused transfer where practical.
Prove the new row fails on the original app, then run the build and touched
suites. None of that implementation or verification has run on this branch.
