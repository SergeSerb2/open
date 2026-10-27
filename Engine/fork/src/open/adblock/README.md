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
  cannot help, and an allocation failure aborts too. A crate call that
  returns a `Result` can still panic or allocate without bound on hostile
  input (a DAT of 4 bytes or less panicked, review 98-3; a 14-byte DAT made
  `rmp-serde` allocate 512 MiB, review R2-1; a 42.7 MiB DAT and a 16 MiB
  list each made one request over PartitionAlloc's 2^31 − 2 MiB ceiling,
  review R3): guard each known case before the call, index nothing
  unchecked, bound the decoded result and not only the raw bytes, and fuzz
  the rest (`docs/followups.md`). A DAT passes a bounded MessagePack walk
  before the crate reads it (`check_dat` in `lib.rs`: lengths, counts,
  2^24 values, 32 levels, no trailing bytes), and a build refuses more than
  2^21 list lines or 64 MiB of cosmetic selector copies before it parses
  (`check_build_limits`).
- No CSS text is built in Rust: cosmetic results are sanitized, sorted hide
  selectors (adblock-fork §5.2, §8.3), and the renderer inserts one rule per
  selector. The crate's `:style()`, `:remove*()` and scriptlet output is
  discarded in the shim and counted (lead ruling 6).
- No free-form request type crosses the bridge (`OpenRequestType`), and a
  check matches at most `max_input_bytes` of a URL (§7.7; C++ passes
  16 KiB).
- `open_adblock_engine_format()` names everything a cached DAT depends on;
  bump `SHIM_VERSION` in `lib.rs` when `ParseOptions`, permissions, features
  or bridge semantics change.
- `OpenAdblockEngine` must stay `Send + Sync` (the assertion at the end of
  `lib.rs`); if it stops compiling, a thread-unsafe crate feature came back.
- Scriptlet and redirect resources arrive as the crate's own JSON
  `Vec<Resource>` (Step 7 produces it), not through the crate's
  path-based assembler, which panics on malformed files.
