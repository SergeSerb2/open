# License audit: 2026-11-07

This audit implements release §7 and extends §5.3 so normal Debug and
Release builds also generate acknowledgements. It does not authorize a
public release. The official engine's complete Chromium credits, U-8's
public source location and U-6's written review remain open. The repository
is still PRIVATE (`gh repo view --json visibility`, 2026-11-07).

## Source evidence

- Baseline main: `df4767ad`. `Engine/fork/VERSIONS` pins Chromium
  `156.0.8078.48`, commit `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`,
  and CEF `4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f`.
- `Packages/OpenKit/Package.swift` has no remote dependencies.
  `project.yml` pins Sparkle `2.10.1`; its resolved source commit is
  `ab7d71291238df6e0492143b120c9b696a35f603`. Its package declares one
  binary target, artifact SHA-256
  `4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`.
  `cmp` confirms the committed whole Sparkle license equals that checkout's
  LICENSE, including its external notices. CEF LICENSE.txt also matches.
- The adblock dependency walk follows the pinned Chromium GN files after
  `Engine/fork/patches/rust/0001-adblock-vendor.patch`: 70 crate/version
  entries, of which 57 are runtime dependencies and 13 are host-only tools.
  Each has its own inventory row. `nm -m` on the shipped CEF binary also shows Open adblock and
  regex-automata symbols. The 23 added crate archive SHA-256 values
  in `docs/engine-patches.md` all match the local crates.io cache: **23/23**.
  No engine source tree was edited or built.
- The vendored adblock source attributes a json-rust string-escaping
  implementation in `src/resources/resource_storage.rs:23` and rust-url
  parser code in `src/url_parser/parser.rs`. Their upstream notices are
  included separately. The json-rust excerpt's original revision is not
  recorded by adblock; the inventory says so instead of inventing one.
- The regex syntax tables' generated headers name Unicode 16.0.0.
  unicode-bidi's constant is 16.0.0; unicode-normalization's vendored
  constant is 18.0.0. These are source labels, not the macOS Unicode version.
  Their Unicode notices are included along with the crate licenses.
- The two Swift PSL files are byte-identical, SHA-256
  `0232f4df0831911356e8ee1f4d5c3b6b12c0ed3f6bd66b0f81c8ab5d3d49e9ca`.
  The psl crate embeds a separate generated list; its original list commit
  is not recorded. U-8 must expose all exact shipped MPL sources.
- FFmpeg's exact revision comes from Chromium's pinned DEPS:
  `9db86ce5b5b454dfc96c435f9f0723012980c37f`. Its README.chromium selects
  CREDITS.chromium. That whole text and COPYING.LGPLv2.1 are committed.
- `tools/generate-sounds.py` synthesizes the two CAF files from seeded PCM.
  `tools/gen-emoji-index.py` pins the Unicode 17.0 emoji input and hash.
  No font or third-party sound is declared by the shell target. The source
  and bundle maps are in [the inventory](licenses.md).

## uBO decision: §7.3(b)

Superseded by #262 (Section 13, 2026-11-08). The App now ships the pinned
uBlock Origin redirect resources (uBO 3762a26f, 47 redirect stubs, no
scriptlet templates) as `AdBlock/resources.json` (SHA-256 6d4a87b8…), with
the original text sources and uBO's LICENSE.txt under `AdBlock/Source`. They
are separate, unmodified data files that the engine reads at run time; they
are not compiled or linked into Open's code. The build passes `AdBlock/Source`
to the generator as `--ubo-source`, so the GPL-3.0 row and the full GPL-3.0
text appear in the generated acknowledgements. The exact upstream source
archive and pins are in [the inventory](licenses.md) ("uBlock redirect
assets"). Public distribution review stays with U-6.

## Official-engine blocker

The read-only main engine distribution's CREDITS.html is **401 bytes** and
contains `This is sample credits page` and `generate_about_credits=true`.
The engine owner must supply generated credits from the exact engine build.
The generator preserves that HTML as a twin, labels previews incomplete,
and refuses release mode. The inventory does not claim that its explicit
Rust rows replace Chromium's missing full third-party inventory.

## Real CLI and native format checks

The real generator command was run against the inventory and recorded
engine distribution. Preview mode returned 0 and emitted RTF, TXT and an
HTML twin byte-identical to the input. Release mode returned 1 for the
sample credits and unset public source location, with no new RTF output.
A changed license hash returned 1. An empty inventory returned 1 with no
output. Temporary GPL rows without source input or full license text
returned 1. An output path that would overwrite the HTML twin returned 1. These are command-line flows, not unit tests.

Before/after proof: the old generator run against the new inventory omitted
the full Apache terms and acknowledged excluded aho-corasick. The changed
generator includes the terms and omits that nonshipped row. The native
`/usr/bin/textutil -convert txt -stdout Credits.rtf` conversion exactly
matches Acknowledgements.txt, including Unicode characters.

The build-tool input limits are 2 MiB / 2,048 inventory rows, 4 MiB per
license / 16 MiB total / 256 distinct texts, and 32 MiB for Chromium HTML.
A future uBO source input is capped at 16 MiB per file, 64 MiB total,
8,192 paths and 64 directory levels. Reads stop at the limit plus one byte,
before decoding. The real CLI accepted an inventory at 2,097,152 bytes and
refused 2,097,153 bytes (load 28.28 / 32.77 / 26.28). These are build inputs;
there is no new runtime page, file or network parser in the app.

## About panel load contract

`Packages/OpenKit/Sources/OpenCommands/MenuBuilder.swift` maps `about-open`
to `orderFrontStandardAboutPanel:`. The App has no override that supplies
custom credits. The installed macOS AppKit SDK's `NSApplication.h`, beside
`NSAboutPanelOptionCredits`, states:

> If not specified, contents obtained from "Credits.rtf" (.rtfd, .html) in
> [NSBundle mainBundle]; if not available, blank.

The file and selector path are the explicit non-desktop verification route
in the task brief. Native RTF decoding checks the actual app resource. No
mouse, keyboard, desktop automation or app launch is needed for this route.
This proves the resource/load contract; it is not a visual-layout receipt
or signed release acceptance.

## Final build and artifact receipts

The code head `236e3888` merges `origin/main` through `b082d35c`.
All app builds and verify-all runs used `heavy.sh` and
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Raw logs and JSON
receipts are in the project root's git-ignored `.re/s16/licenses/`.
Times include queues, not app performance.

Final psl review: Cargo.toml declares `MIT/Apache-2.0`, README.chromium
selects Apache, and the vendored LICENSE is MIT. The inventory records
both alternatives and includes both full texts, plus MPL for the data.
No legal-file bytes changed.

| Final normal build | Result | Wall seconds | Start load (1/5/15 min) | End load |
|---|---|---:|---|---|
| Release | PASS | 101.8 | 18.14 / 28.24 / 27.27 | 15.30 / 24.33 / 25.84 |
| Debug | PASS | 23.24 | 15.10 / 23.99 / 25.70 | 14.87 / 23.21 / 25.37 |

Both real apps have 356 files/links. All 13 repository data resources match
their packaged copies. All 22 needed full legal texts appear in both apps;
all 70 crate/text source links match upstream bytes. Native `textutil`
conversion matches TXT exactly, and `codesign --verify --deep --strict`
passes for both. Release artifact audit load was 14.77 / 23.77 / 25.62;
Debug and the full-text presence audit were 12.96 / 21.48 / 24.62.
Each app's first two decoded credit lines are:

```text
Open 0.1.0 (1)
Chromium 156.0.8078.48 · CEF 4fa4ab5
```

Both apps have these identical acknowledgement hashes:

- Credits.rtf: `4d3f9f8a71bd1e93a15e9971f98d7cb1c79d0c5f1e652e474f7c44df3e75bdb8`
- Acknowledgements.txt: `7b84ee8923540299e06902db0c01418f00100ce9ea611891b9d8dd19c57c49fc`
- CREDITS.html: `c2a338c4f1f5f5e19d3020a25f8dc47e394ba4fed1ec2d8dc5b2a915170e02bc` (sample; release blocked)

## Incremental signing proof

An inventory-only update exposed an Xcode dependency bug: the build passed,
but deep signature verification refused modified Credits.rtf and
Acknowledgements.txt. Declaring the built Info.plist input and all three
resource outputs fixes signing order and incremental dependency tracking.
No app was launched. The real normal-build flow then passed all three steps:

| Real Release flow | Build and deep signature | Seconds | Start load | End load |
|---|---|---:|---|---|
| declared phase outputs | PASS | 78.78 | 33.44 / 36.45 / 28.27 | 34.53 / 35.92 / 28.80 |
| incremental inventory-only change | PASS | 10.55 | 34.53 / 35.92 / 28.80 | 32.15 / 35.36 / 28.68 |
| restored committed inventory | PASS | 10.88 | 32.15 / 35.36 / 28.68 | 36.92 / 36.31 / 29.10 |

The probe changed only the Open-owned inventory row's version text. The
second build contained that marker and had a valid signature; the third
restored the exact inventory and removed the marker. This proves the
incremental path, not just the first build after editing project.yml.

Earlier normal-build receipts are retained for completeness. The psl-update
Release build exposed the resource-seal failure described above; that app
was never launched.

| Earlier build | Build result / artifact note | Seconds | Start load | End load |
|---|---|---:|---|---|
| Initial Release | PASS | 339.37 | 12.82 / 13.08 / 11.69 | 58.27 / 41.26 / 24.38 |
| Pre-correction Release | PASS; deep signature PASS | 538.48 | 10.66 / 27.02 / 21.65 | 10.98 / 23.97 / 23.74 |
| Pre-correction Debug | PASS; deep signature PASS | 118.29 | 9.78 / 22.23 / 23.11 | 14.76 / 19.63 / 21.93 |
| psl-update Release | PASS build; FAIL resource seal | 81.86 | 25.89 / 26.44 / 22.35 | 63.16 / 38.88 / 27.49 |
| psl-update Debug | PASS build; signature not checked before fix | 17.58 | 49.93 / 37.45 / 27.24 | 51.10 / 38.31 / 27.72 |
| Phase-fix Debug | PASS; deep signature PASS | 15.17 | 36.18 / 36.18 / 29.18 | 34.07 / 35.75 / 29.15 |

## CLI boundary and release gates

The final CLI flows passed at load 26.45 / 33.46 / 28.64. Independent
release-gate checks refused the actual sample even with a temporary source
URL, and refused actual UNSET with `--require-public-source`, at load
11.86 / 14.50 / 18.72. The inventory-byte boundary passed earlier at load
28.28 / 32.77 / 26.28. All 20 additional at/over-limit CLI cases passed in
5.56 s at load 20.64 / 30.11 / 27.83 → 21.87 / 30.21 / 27.88:

| CLI input | Accepted | Refused |
|---|---:|---:|
| Inventory component count | 2,048 | 2,049 |
| Built Info.plist | 1 MiB | +1 byte |
| One legal file | 4 MiB | +1 byte |
| Total legal bytes | 16 MiB | +1 byte |
| Distinct legal files | 256 | 257 |
| Chromium HTML | 32 MiB | +1 byte |
| One conditional GPL source file | 16 MiB | +1 byte |
| Total conditional GPL source | 64 MiB | +1 byte |
| Conditional GPL source paths | 8,192 | 8,193 |
| Conditional GPL source depth | 64 | 65 |

The first extended boundary invocation stopped in fixture setup after 12
PASS cases because it assumed a current uBO table row. The corrected
fixture inserts the future conditional row; all 20 cases then pass. No
product code changed for that fixture correction. No unit tests were added.

## Verification history

The initial full `heavy.sh tools/verify-all.sh --with-arc-data` finished
in 1,170.93 s: **24 PASS, 1 timing FAIL** (exit 1). Start load was
18.36 / 20.07 / 22.03; end was 6.80 / 15.77 / 18.27.

| Check | Initial result | Seconds |
|---|---|---:|
| build | PASS | 104 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 201 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 25 |
| commands-dump | PASS | 1 |
| route | PASS | 5 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| settings-preview | PASS | 92 |
| sidebar-render | PASS | 112 |
| sidebar-compare | PASS | 162 |
| commandbar-render | FAIL | 40 |
| features-render | PASS | 94 |
| extensions-render | PASS | 8 |
| sitecontrol-render | PASS | 261 |
| boosts | PASS | 4 |
| import-arc | PASS | 1 |
| verify-secrets-fixture | PASS | 5 |

The initial commandbar run passed 150/151 rows: CPU p95 7.40 ms (<8),
completion overhead p95 +0.375 ms (>+0.3), paired median +0.136 ms.
Printed load was 16.0 / 19.2 / 19.7. The measured quiet replacement also
passed 150/151: CPU p95 5.95 ms, completion +0.311 ms, paired median
+0.100 ms, layout max 1, printed load 14.9 / 12.2 / 11.9 (above §4b's
load1 limit). Its build passed (3 s), check took 37 s; outer wall time was
528.64 s including 485 s in the heavy queue. Outer loads were
11.74 / 8.75 / 10.99 → 14.91 / 12.20 / 11.89. Both FAILs remain recorded.

One first quiet invocation was cancelled before acquiring its lock to add
a load gate. Its replacement was stopped by the lead at 16:36 while waiting
for a heavy slot. Both ran no timing rows. A later native-only load gate
waited 940.10 s without reaching load1 ≤12, then was cancelled before any
measurement for the source correction and App rebuilds. These are
INTERRUPTED / not measured, not timing FAILs. Subsequent timing follows the
current rule: build first, then take the quiet lock only for the already-built
native command. The lead's 17:27 ruling caps dedicated timing runs at load1
≤20 and classifies timing misses under load as nonblocking (TANDEM 4l).
Future heavy calls must use the Section 16 token wrapper. The running full
gate was allowed to finish; no further high-load timing run is started.

## Final full gate

The final command was `heavy.sh tools/verify-all.sh --with-arc-data` on
code head `236e3888`, after merging `b082d35c`. It finished in
1638.2 s (including screen queues), exit 1: **23 PASS, 2 timing-only
FAIL checks; all functional rows PASS**. Start load was
13.05 / 21.64 / 24.69; end was 24.03 / 21.65 / 38.11.

| Check | Final result | Seconds |
|---|---|---:|
| build | PASS | 49 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 3 |
| space-editor | PASS | 248 |
| space-pad-compare | PASS | 3 |
| suggest-check | PASS | 38 |
| commands-dump | PASS | 0 |
| route | PASS | 26 |
| favicons | PASS | 5 |
| media-demo | PASS | 1 |
| sleep-demo | FAIL | 8 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 1 |
| profiles | PASS | 5 |
| settings-preview | PASS | 102 |
| sidebar-render | PASS | 118 |
| sidebar-compare | PASS | 218 |
| commandbar-render | FAIL | 43 |
| features-render | PASS | 101 |
| extensions-render | PASS | 9 |
| sitecontrol-render | PASS | 636 |
| boosts | PASS | 4 |
| import-arc | PASS | 3 |
| verify-secrets-fixture | PASS | 8 |

- `sleep-demo`: 171 functional checks PASS; controller CPU p95 2.221 ms
  against <2 ms. The CLI does not print per-check load. The nearest
  foreground load polls after its failure were 108.75 / 41.32 / 29.72
  and 138.33 / 50.93 / 33.34. Peak observed during the full run was
  205.28 / 98.50 / 53.60. These are surrounding machine observations,
  not an invented exact benchmark load.
- `commandbar-render`: 150/151 PASS; CPU p95 7.92 ms (<8), completion
  overhead p95 +0.408 ms (>+0.3), paired median +0.100 ms, layout max 1.
  Its printed load was 36.7 / 89.8 / 68.7. Every functional/render row passed.

The lead's 17:27 ruling accepts these timing misses under load as
nonblocking (TANDEM 4l) and says to open the PR once functional checks finish.
No dedicated timing run starts above load1 20. The final full job began
before that ruling and was explicitly allowed to finish. No thresholds,
baselines or out-of-scope code changed for these results.
