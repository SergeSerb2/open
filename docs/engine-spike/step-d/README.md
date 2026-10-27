# App shell Step D checkpoint

Paused on 2026-10-26 at the lead's request. **No PR is open.**
Implementation is on `t3/app-shell-page-chrome`, main merged through `49b5660`.
The final native-popover key fix builds but has no positive runtime receipt yet.
Do not treat this evidence bundle as merge acceptance for the checkpoint head.

The acceptance candidates named `r6-*` use the 21:23:54 fork distribution,
stamp `1793075034`, UUID `4C4C44C8-5555-3144-A168-35B709BBDA3A`. Both features
configs have 97 PASS plus two dependency BLOCKED rows. Their interrupted
attempts are retained in the JSON, never counted as PASS. These runs precede
the final popover-key fix and #120. Other numbered files retain earlier engines
and code revisions for diagnosis; their embedded engine identity is authoritative.

| Evidence | Meaning |
|---|---|
| `r6-debug-page-chrome.*` | 60 PASS, 2 dependency BLOCKED; no interruptions |
| `r6-debug-page-keys.*` | 19 PASS; no interruptions |
| `r6-debug-features.*` | 97 PASS, 2 dependency BLOCKED; one interrupted attempt |
| `r6-release-features.*` | 97 PASS, 2 dependency BLOCKED; two interrupted attempts |
| `r6-debug-sidebar.json` | 19 PASS; durable-profile row defers to profiles suite |
| `r6-results-window-debug.json` | 54 PASS, 1 pixel FAIL, 2 Debug timing SKIP; two interrupted attempts |
| `popovers-old.*` | Intentional red control: Return leaks into page, Escape fails, Cmd+W loses document context. Cleanup kills only the owned tree; no windows remain. |
| `forced-current.*` | Forced early prompt assertion FAIL; cleanup PASS, zero windows/forced root kills, source unchanged |
| `keys-cleanup-old.*` | Protected old prompt Return / Find-over-Peek Escape failures, unconditional cleanup |
| `main4c40-verify-21-pass.log`, `verify-all.log` | Completed pre-#120 gate: 21 PASS, no SKIP |
| `main49b-verify-interrupted.log` | New gate: 16 completed PASS rows, then cancelled in sidebar-render. Not a full PASS. |
| `build-debug.*`, `build-release.*` | Successful builds of the final popover fix on main #120; Debug refreshed at the checkpoint |

The PNGs are snapshots of Open's own synthetic fixtures from the R6 runs.
Downloads is the actual `_NSPopoverWindow`, not a document screenshot. Small
native sheets/popovers retain native pixel size. They prove presentation, not
Arc visual parity; missing Arc references remain explicit styling guesses.
No Arc pixels, private URLs, profile data or desktop captures are included.

Remaining: positive native popover Debug/Release checks; affected features,
window, shell, sidebar, Peek/actions/profiles as needed; complete merged gate;
then finish the review checklist. SCC sections/editor #96/#103 and the main
native extension API/popup integration #93/#94 remain dependencies. The artifact
contains #93 backend work; that does not claim its App/API merge is complete.
See [checkpoint status](../../app-shell.md) for the failure causes and focus
trace names. No suite was launched after the pause order.
