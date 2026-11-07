# License audit: 2026-11-07

This audit implements release §7 and extends §5.3 so normal Debug and
Release builds also generate acknowledgements. It does not authorize a
public release. The official engine's complete Chromium credits, U-8's
public source location and U-6's written review remain open.

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
  Each has its own inventory row. The 23 added crate archive SHA-256 values
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

Do not ship uBlock Origin resources/scriptlets. The adblock crate has a
parser/assembler, but `ResourceStorage` starts with empty maps. The only
scriptlet file reference in its assembler is a noncompiled test fixture;
there is no `include_str!` or `include_bytes!` asset payload in its src tree.
The OpenAdBlock Swift resource bundle has only catalog.json, list-pins.txt
and public_suffix_list.dat. Neither the application nor the recorded engine
distribution contains a uBO resource/scriptlet payload or seed filter DAT.
Catalog URLs and user-installed extensions do not change this bundle fact.
The generator omits GPL-3.0 for the current inventory. A future shipped GPL
row requires the full text, a source URL and explicit source input.

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
A changed license hash returned 1. A temporary GPL inventory row without
source input returned 1. These are command-line flows, not unit tests.

Before/after proof: the old generator run against the new inventory omitted
the full Apache terms and acknowledged excluded aho-corasick. The changed
generator includes the terms and omits that nonshipped row. The native
`/usr/bin/textutil -convert txt -stdout Credits.rtf` conversion exactly
matches Acknowledgements.txt, including Unicode characters.

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

## Build and full-gate receipts

Final build, bundle and full-gate results are recorded here after the
required merge of origin/main. Raw logs are in the git-ignored
`.re/s16/licenses/` handoff area of the project root.
