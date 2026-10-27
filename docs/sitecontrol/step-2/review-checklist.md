# Review checklist — Step 2 migration

| Item | Result | Evidence / scope |
|---|---|---|
| External size/count/depth/length limits | N/A | No new external ingest. The library consumes in-process snapshots; extension payload integration remains with OpenExtensionsUI. Native resource caches have fixed entry ceilings. The bundled performance fixture is limited to 16 KiB / 32 entries. |
| Worst single allocation | PASS | `SiteControlDrawing`: fixed 236×32 row bitmap at 2x = 120,832 bytes; 48 entries ≈5.6 MiB. Glyph/text caches are bounded. |
| Ingest boundary cases | N/A | No new external file/network/page input path in this library step. |
| Trailing/unknown parsed data | N/A | No external parser. The performance baseline is a versioned bundled fixture, not caller-provided data. Invalid fixture versions and duplicate machine keys fail. |
| Callback may replace caller | PASS | `SiteControlDataSource.swift` documents host callback lifetime. Controller revalidates tab and presentation generation after toggle/clear-data callbacks. |
| Repeated/interrupted close lifetime | PASS | ARC-managed views; generation-guarded completion. Native flow repeated closes and motion runs complete without a stale close hiding a later presentation. |
| Stale IDs / generations | PASS | Retained NSMenu item from a prior presentation cannot invoke; `flows.txt` records the native stale-menu flow. |
| Flush state before dependent action | N/A | This panel owns no persistence/debounced shell state; the host protocols own writes. |
| Full app key router | N/A | Deferred to Step 3 per plan §12/§11, including S11–S13. Here keys enter the native `window.sendEvent` path; no App hook is added. |
| Key ownership after merge | PASS | Command-Return/Space do not activate. Return/Space without focused controls are not swallowed. Native menu Return and Esc paths pass after the main merge. |
| Hidden item cannot run | PASS | Effective ancestor visibility filters keyboard controls. Non-http(s) security has no AX item. Creation/private-window capability guards also apply to menus. |
| Checks fail without fixes | PASS | `negative-proof.txt`: wrong focus/menu/picker/stale-generation/cut-out implementations fail native flows, probes and ΔE00 comparison. Instruction gate has its own deliberate O(n) work proof. |
| Pixel evidence | PASS | 1048/1048 probes. `comparison-base.md`: 62 PASS; `comparison-hover.md`: 61 PASS + one lead-qualified deferral; `comparison-boost.md`: 5 PASS. Limits unchanged. |
| Specific window readiness | PASS | Native menu render waits for its actual popup surface, not any window, then captures it. Editor windows are outside this step. |
| Scheduled motion / performance | PASS | Animation duration captured in the initiating turn. The instruction gate uses the machine/build median and unchanged 10% ceiling. CPU/wall/load are printed diagnostics; quiet <8 ms product acceptance belongs to the lead. |
| Run isolation | PASS | Synthetic in-memory sources, per-process windows, no persistent store/profile/port. Native popup runs use the machine-wide on-screen lock. Full runner uses a fresh scratch root. |
| Reduce Motion | PASS | Source branches skip scale/spring under `accessibilityDisplayShouldReduceMotion`; row-height change uses opacity transition. Normal native motion path is exercised here; system preference is not changed. |
| Interrupted motion | PASS | Height choreography captures presentation-layer values before the structure changes. Close uses presentation opacity/scale. Step 1 open/close foundation is inherited. |
| Resize / sidebar movement | PASS | Native resize flow clears structure animations and applies the current clamp. App sidebar movement integration is deferred to Step 3. |
| Real-app snapshots | N/A | Deferred to Step 3 per plan §12/§11; no Site Control app hook exists in this PR. All assigned offscreen element comparisons are complete. |
| Accurate docs/comments/numbers | PASS | Plan §3.7/§12.3 agree on the guessed note geometry; measured +35 separator rule is cited. Performance evidence records exact source/binary identities and the method change. |
| Plan/followups/PR agree | PASS | Global-off baseline calibration remains in followups. Share hover/press glyph and real-app checks remain explicitly deferred. No engine/App work is claimed. |
