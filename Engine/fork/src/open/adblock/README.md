# Open ad-block build placeholder

No code until Step 8 of [fork-infra](../../../../../docs/plans/fork-infra.md).
The crate pin is `adblock = "=0.8.11"` (MPL-2.0), recorded in `VERSIONS`.

The target shape is `OpenAdBlockService` plus
`OpenAdBlockURLLoaderThrottle` under `//open/adblock`, as specified in
[adblock-design](../../../../../docs/adblock-design.md). This placeholder
does not enable a dependency or a GN target.

Step 8 follows fork-infra §7.4 R1–R6: merge the `.open` fragments, vendor
with Chromium's `gnrt`, generate GN files, build with Chromium's Rust
toolchain, review the full dependency closure, then capture the result in
`patches/rust/`. Normal apply uses the captured patch with no network.
