# Section 9 Peek: real App receipt — 2026-11-05

Base: `7254c0a3`. Branch: `s9/peek-app`. Engine distribution: `f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939` from `open-engine-s8-main`. Only the OpenEngine Xcode wrapper changes; no Chromium tree, fork patch, or distribution changes.

## Audit of the starting App

The original `peek` suite passes 8/8 on the starting commit. It covers explicit `peek-open`, promotion/host ownership, two screenshots, close Undo (including a hovered toast), and pane page color. It does not prove link interception. The extended audit and negative run exercise the real App with synthetic pages and the same engine.

| Item | Starting App | Evidence and change |
|---|---|---|
| Pinned/favorite cross-site click (eTLD+1) | FAIL | Real link clicks navigate instead. `EngineWebContentHost.shouldNavigate` has no caller. Add `OEClient::OnBeforeBrowse` → optional OpenEngine delegate → the existing host policy. |
| Same-site, including a subdomain | PASS | `peek_policy_same_site`; `a.localhost` → `docs.a.localhost` navigates in place. |
| Shift-click from Today | FAIL | Chromium opens a standard window. Route its `NEW_WINDOW` disposition through the same policy with Shift. The lazy window path now creates Peek for a Today Shift-click. |
| Both Links switches off | PASS | Each switch independently prevents its trigger. Shift off retains the default new-window action; a plain click with other-sites off navigates in place. |
| Overlay geometry, dim, three buttons | PASS | `peek_overlay_geometry_dim_buttons`; measured metrics unchanged. `features-render` retains the visual gates. |
| Esc/click outside, close toast and Undo | PASS | Existing real Esc/Undo/hovered-Undo rows; new native backdrop click row. |
| Expand with page state | PASS (Alloy); incomplete Chrome fallback | Existing same-ID/JS state row. Chrome previously loaded only the URL. The new fallback captures and restores engine history, scroll and form state (M4 Q5). JavaScript heap state is kept only by same-host Alloy promotion. |
| Split beside source; favorite refusal | PASS | Real Split button, source split membership, page URL/state, no new favorite tab on refusal. |
| Native nested links, cap 5 | FAIL | Same missing navigation callback. `peek_nesting_cap` now clicks each real nested link, then navigates the fifth host in place. |
| Badge; source becomes a split | PASS | `peek_badge_sidebar_state`, `peek_source_selection_hides`, `peek_follows_source_split` read the real sidebar state. |
| Cmd+O current/chosen Space, Today top | PASS | Real App key route, native menu tracking and its selected menu action; `peek_cmd_o_current/chosen`. |
| Sleep visibility | FAIL for native shown-state consistency; feed/ticker PASS | The snapshot already includes the top transient ID and source. The ticker advances and rejects freeze, but `hostHidden` is true: the factory creates the host hidden and Peek never clears it. Refresh now aligns the native view flag with the shown top Peek and hides lower/source-hidden pages. |
| View > Exit / App Esc | FAIL as a menu command | `exit-modal` is absent from `AppCommand.implemented`. One App handler now uses Peek → maximized split → no action. The item is enabled only in the key standard window with such a surface. Plain Esc reaches the page. |
| Peek swipe indicator | Missing | The wrapper already forwards swipe events. Route the visible Peek to the existing lazy `SwipeIndicatorView`, using its Space style. No new visual metrics. |
| Peek Email | Disabled | It remains outside `AppCommand.implemented`; `peek_email_disabled`. |

## Real interface and fixture method

The harness launches the actual Debug `Open.app` with fresh data/cache roots and an ephemeral HTTP server. Links are real anchor elements on loopback pages. `Input.dispatchMouseEvent` presses/releases their centers, with Chromium user gestures and modifier flags. No desktop input is used. App keys use `key route=app` (`OEApplication.sendEvent`); menu actions use the real AppKit menu/button. The Space-picker helper waits for `NSMenu.didBeginTrackingNotification`, closes tracking and invokes the chosen menu item's existing action.

`peek-ui` reads actual overlay geometry, sidebar badges and the shared `app.media.visibility` snapshot without refreshing that feed. The ticker advances the sleep controller clock 31 seconds, runs a real sleep pass, checks that the source freeze gate stays visible, checks that the Peek ticker still advances, and checks that the engine refuses to freeze the visible Peek. Dismiss, source hide, nesting, expand and split check transient membership at the transition.

Peek IDs remain transient and are not inserted into the sidebar model (M4 §7). OpenSleep applies its phase policy to model tabs; the extra Peek set is the visibility contract for transient surfaces. Native view visibility drives the current renderer visibility. The ticker/engine assertions and snapshot membership assertions verify both parts separately.

Preferences use the shared application domain. The suite saves persistent values, resets the two Peek keys at start and restores them in `finally`. Every owned process is cleaned up by the harness.

## Acceptance

The starting production code, restored for the audit with observation hooks only, produced 20 PASS and 10 FAIL in the 30 new Chrome rows. Cleanup passed. The failures are the fresh-window Shift trigger, pinned/favorite/Today Shift triggers, native nesting and nested visibility, Exit menu priority, native Peek shown-state, swipe indicator, and Chrome saved page state. Both Exit and visibility therefore have an old-code negative proof. A separate mutation removed only `peek.insert(id)` from the provider. `peek_visibility_ticker` and `peek_nested_visibility` FAIL (the remaining 28 rows PASS). Both transient-set checks therefore detect a missing feed. The provider was restored byte for byte.

Final acceptance counts are recorded below after the runs. Raw logs and JSON copies: `.re/s9-peek/` in this worktree. The final snapshot is saved there for the lead.

## Find first refusal (lead update)

The App Exit route closes the current window's Find before it reaches Peek or split restoration. `PeekController.escape` also preserves Section 11's `onPageEscape` seam. The pre-fix wrapper/App run fails `peek_find_first_app` and `peek_find_first_menu`: Peek closes while Find remains. The window-only Find case passes. Final coverage also keeps a maximized split unchanged on the first Find Esc, then restores it on the next Esc. The final head must retain this contract when the Section 11 coordinator merges.

## Guesses and limits

No new design guesses. Existing measured geometry and colors are unchanged. The prior provisional Peek motion, always-on dim and favorite badge limits remain as documented in `docs/m4.md`. Q4 Split semantics and the Chrome Q5 history fallback follow the lead decisions. Native trackpad recognition remains the existing U-S1 hand check; the suite replays engine swipe events.
