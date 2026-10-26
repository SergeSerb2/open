# Open ad-block engine (`//open/adblock`)

Native ad blocking in the browser process, built on Brave's `adblock` crate
0.8.11 (MPL-2.0), vendored with Chromium's `gnrt`
(`Engine/fork/patches/rust/0001-adblock-vendor.patch`). The plan is
[adblock-fork](../../../../../docs/plans/adblock-fork.md); the security
review is in [engine-patches.md](../../../../../docs/engine-patches.md) P8.

| Path | What | Step |
|---|---|---|
| `rust/` | `//open/adblock/rust:open_adblock_rust`: the CXX bridge (`src/lib.rs`). C++ includes `open/adblock/rust/src/lib.rs.h`, namespace `open_adblock`. | 2 |
| `//open:open` (`../BUILD.gn`) | Group of every Open GN target. | 2 |

Rules for the Rust shim:

- Nothing in it may panic: Chromium builds Rust with `-Cpanic=abort`
  (`build/config/compiler/BUILD.gn`), so a panic ends the browser process.
  Use only crate calls that return a `Result` or an empty value.
- `OpenAdblockEngine` must stay `Send + Sync` (the assertion at the end of
  `lib.rs`); if it stops compiling, a thread-unsafe crate feature came back.
- Scriptlet and redirect resources arrive as the crate's own JSON
  `Vec<Resource>` (Step 7 produces it), not through the crate's
  path-based assembler, which panics on malformed files.
