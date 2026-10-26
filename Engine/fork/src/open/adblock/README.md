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

- A panic ends the browser process: Chromium builds Rust with
  `-Cpanic=abort` (`build/config/compiler/BUILD.gn`), so `catch_unwind`
  cannot help. A crate call that returns a `Result` can still panic on
  hostile input (a DAT of 4 bytes or less did, review 98-3): guard each known
  case before the call, index nothing unchecked, and fuzz the rest
  (`docs/followups.md`).
- No CSS text is built in Rust: cosmetic results are sanitized selector and
  declaration vectors (adblock-fork §8.3), and the renderer inserts one rule
  per selector.
- No free-form request type crosses the bridge (`OpenRequestType`), and a
  check matches at most the first 8 KiB of a URL (§7.7).
- `open_adblock_engine_format()` names everything a cached DAT depends on;
  bump `SHIM_VERSION` in `lib.rs` when `ParseOptions`, permissions, features
  or bridge semantics change.
- `OpenAdblockEngine` must stay `Send + Sync` (the assertion at the end of
  `lib.rs`); if it stops compiling, a thread-unsafe crate feature came back.
- Scriptlet and redirect resources arrive as the crate's own JSON
  `Vec<Resource>` (Step 7 produces it), not through the crate's
  path-based assembler, which panics on malformed files.
