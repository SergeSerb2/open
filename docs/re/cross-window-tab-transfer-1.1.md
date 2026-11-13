# Cross-window page preservation

The lead reopened this parked 1.1 investigation in the 2026-11-13 night lane.
The shell implementation is in `ns/nt-live-tab-transfer`. The private
`267b0ad8` engine passed the full Blank Window real-App suite (24/24) on a
rented Mac, including five document/identity preservation checks. Its scoped
build also passed. These receipts qualify the private transfer path; official
engine adoption remains separate. The shipping `b0cb685a` engine keeps URL
reload moves. If the engine is not adopted by 04:00 Vancouver, that fallback
stays and the no-reload feature returns to 1.1.

## Engine boundary

The original reload paths created a fresh tab and closed the source host
(`App/BlankWindow.swift` on main `6328035d`). Moving only its NSView was unsafe:
`OEBrowser.insert` refused content owned by another hidden browser, while source
browser close still owned the actual hosted tab. Evidence: the original
`Engine/OpenEngine/src/OEBrowser.mm` insert/remove/sync/close paths and
`OEWebContent.mm` hosted creation path at that revision.

E3 owns the engine implementation. The requested public OpenEngine operation is:

```objc
#define OE_HAS_WEB_CONTENT_TRANSFER 1
- (BOOL)transferWebContent:(OEWebContent*)webContent
              fromBrowser:(OEBrowser*)source
                  atIndex:(NSUInteger)index
    NS_SWIFT_NAME(transfer(_:from:at:));
```

It synchronously moves the existing hosted tab between open browsers of the
same context. It preserves the document, native view, content/chrome.tabs IDs,
history, scroll, typed text and media state. Index is inclusive 0...count.
Wrong owners, contexts, indices, closing objects and unsupported content refuse
without mutation. Empty destination and last-tab source are supported. No
synchronous lifecycle delegate callback may interrupt the shell transaction.
The caller retains both browsers and content throughout the call. Source close
after success must not close the moved tab. E3's public header documents these
rules; the Swift shell never imports or calls CEF.

## Shell handoff

`BrowserModel.transferTab` transfers the same Tab object and ID between the two
models without Archive or Undo entries. It stages both graphs, calls the
synchronous external-ownership operation, and rolls back without tree events
on refusal. Both graphs and host owners are final before tree observers run.

`EngineWebContentHostFactory.transferLiveTab` calls only OpenEngine. After YES
it removes the cached host from the old container without closing it, retires
old window-specific prompts/find/translation bindings, changes factory ownership,
renews the host generation and binds the existing view in the destination
container. Source-window teardown then cannot reach that host. Both drag and
the same-Profile Move to Space route use this path. Other profiles, unsupported
hosts and older engines keep the existing URL reload behavior.

`tools/build.sh` sets `OPEN_ENGINE_WEB_CONTENT_TRANSFER` only when the public
API marker exists, the actual copied distribution exposes the needed hosting
capability, and its framework hash matches the recorded distribution. Merely
editing a repository header cannot enable the Swift call with an older engine.

## Verification contract

The real-App `blank-window` suite types synthetic text into a loopback page,
records its document nonce, scroll, back-history capability, model ID, engine
and chrome.tabs IDs and native view identity, then drags normal → Blank Window
→ normal. It checks all identities/state after both moves and after the emptied
Blank Window closes. The Move to Space menu gets the same state check.

The test uses native rail windows and the existing socket drag transport, not
the system mouse or keyboard. `OPEN_REQUIRE_LIVE_TAB_TRANSFER=1` runs these
assertions against the older reload path for negative proof. Without a capable
engine, the feature rows report DEFERRED explicitly; the existing Blank Window
suite still exercises URL moves, Archive behavior and relaunch restoration.
Only capable-engine PASS receipts qualify the no-reload feature as ready.
