# Release license inventory

Source audit: 2026-11-07, main `df4767ad` (before the initial license change).
Filter-list update: 2026-11-08, after #241 bundled the pinned seeds.
Pins come from `Engine/fork/VERSIONS`, `project.yml`, the vendor patch and
Chromium's pinned GN files. Update a row whenever its component changes.

The use column starts with `Ships:`, `Build only:` or `Not shipped:`.
The generator includes shipped rows and the texts for shipped/build-only
rows. Build tools are recorded because their generated code can carry
notices; their host binaries are not in Open.app. License choices for Rust
follow each `README.chromium` (usually the Apache choice for dual licenses),
except psl: its Cargo metadata declares MIT/Apache-2.0, its vendored LICENSE
is MIT, and this inventory retains both alternatives and full texts.
The source paths beginning `third_party/` are relative to Chromium src.
New crates are in `Engine/fork/patches/rust/0001-adblock-vendor.patch`;
existing Chromium crates use pin `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`.

**Release status: incomplete.** The recorded main distribution contains
sample Chromium credits. The app artifacts below are useful local previews;
they are not permission to distribute. Full Chromium third-party inventory
and notices require generated credits from the exact shipped engine. U-6
review and the U-8 public source location also remain open.

| Component | Version | License | How Open uses it | Source / offer |
|---|---|---|---|---|
| Chromium | 156.0.8078.48 | BSD-3-Clause | Ships: engine core and its third-party libraries, fonts, locale packs, ICU/V8/graphics data. Full transitive credits are BLOCKED (sample HTML; see audit below). | Pinned source `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`, `LICENSE`; licenses/BSD-Chromium.txt. Exact third-party texts must come from the matching distribution CREDITS.html; no substitute upstream browser credits. |
| CEF | 156.0.14+g4fa4ab5 (branch 8078) | BSD-3-Clause | Ships: embedding layer, framework and C++ wrapper. | `Engine/fork/VERSIONS`; source https://github.com/chromiumembedded/cef/tree/4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f ; `Vendor/cef/LICENSE.txt`; licenses/BSD-CEF.txt. |
| FFmpeg (Chromium bundled) | Chromium 156.0.8078.48; FFmpeg 9db86ce5b5b454dfc96c435f9f0723012980c37f | LGPL-2.1-or-later; BSD-2-Clause; BSD-3-Clause; ISC; MIT | Ships: engine codecs; proprietary_codecs=true, ffmpeg_branding="Chrome". Patent review remains U-6. | Chromium DEPS -> `third_party/ffmpeg` at 9db86ce5b5b454dfc96c435f9f0723012980c37f; `README.chromium` selects `CREDITS.chromium` (all notices copied to licenses/FFmpeg-CREDITS.txt); full terms also in licenses/LGPL-2.1-FFmpeg.txt. https://chromium.googlesource.com/chromium/third_party/ffmpeg/+/9db86ce5b5b454dfc96c435f9f0723012980c37f/ . Review LGPL source/relink obligations before distribution. |
| Sparkle | 2.10.1 | MIT; bundled external notices | Ships: update framework and its updater/XPC tools. | `project.yml` exactVersion; https://github.com/sparkle-project/Sparkle/tree/ab7d71291238df6e0492143b120c9b696a35f603 ; checkout `LICENSE`, copied whole (including external licenses) to licenses/MIT-Sparkle.txt. |
| bsdiff/bspatch | 4.3 (Sparkle 2.10.1) | BSD-2-Clause | Ships: bspatch applies binary update patches. The bsdiff creation tool is not embedded; its combined notice is retained. | Sparkle commit `ab7d71291238df6e0492143b120c9b696a35f603`, LICENSE external notices, bsdiff.c/bspatch.c; licenses/MIT-Sparkle.txt. |
| sais-lite | 2010-08-07 (Sparkle 2.10.1) | MIT | Not shipped: suffix sorting in Sparkle delta-creation tools; its notice stays in the whole Sparkle LICENSE. | Sparkle commit `ab7d71291238df6e0492143b120c9b696a35f603`, LICENSE external notices, sais.c/sais.h; licenses/MIT-Sparkle.txt. |
| Ed25519 C implementation | Sparkle 2.10.1 bundled snapshot | Zlib | Ships: update signature verification. | Sparkle commit `ab7d71291238df6e0492143b120c9b696a35f603`, LICENSE external notices, orlp/ed25519; licenses/MIT-Sparkle.txt. |
| SUSignatureVerifier | Sparkle 2.10.1 bundled snapshot | BSD-2-Clause | Ships: Sparkle signature verifier; upstream BSD notice retained. | Sparkle commit `ab7d71291238df6e0492143b120c9b696a35f603`, LICENSE external notices, SUSignatureVerifier.m; licenses/MIT-Sparkle.txt. |
| Public Suffix List | 2026-10-22_08-36-41_UTC; commit 8437e5262f13305f94087abe699b4fe2be1d1de8 | MPL-2.0 | Ships: two byte-identical Swift resource files, in OpenSuggest and OpenAdBlock. | `Packages/OpenKit/Sources/OpenSuggest/Resources/public_suffix_list.dat` and `OpenAdBlock/Resources/public_suffix_list.dat`; https://publicsuffix.org/list/public_suffix_list.dat ; licenses/MPL-2.0.txt. Public exact-snapshot source location is UNSET (U-8). |
| Unicode emoji data | Emoji 17.0; emoji-test.txt SHA-256 1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda | Unicode-3.0 | Ships: names, categories and exact fully-qualified sequences. No font artwork or CLDR keywords. | `tools/gen-emoji-index.py` -> `Packages/OpenKit/Sources/OpenSpaceEditor/Resources/emoji-index.json`; https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt ; licenses/Unicode-3.0.txt. |
| Unicode regex tables | Unicode 16.0.0 (regex-syntax 0.8.11) | Unicode-3.0 | Ships: character properties for enabled regex Unicode features. | `third_party/rust/chromium_crates_io/vendor/regex-syntax-v0_8/src/unicode_tables/*.rs` generated-header `ucd-16.0.0`; licenses/Unicode-3.0.txt in addition to the crate license. |
| Unicode bidirectional tables | Unicode 16.0.0 (unicode-bidi 0.3.18) | Unicode-3.0 | Ships: IDNA bidirectional property data. | `third_party/rust/chromium_crates_io/vendor/unicode-bidi-v0_3/src/char_data/tables.rs`, `UNICODE_VERSION = (16, 0, 0)`; licenses/Unicode-3.0.txt plus the crate terms and copyright notice. |
| Unicode normalization tables | Unicode 18.0.0 as labelled by unicode-normalization 0.1.26 | Unicode-3.0 | Ships: generated normalization tables. This is the vendored source's own version constant, not a claim about the system Unicode version. | `third_party/rust/chromium_crates_io/vendor/unicode-normalization-v0_1/src/tables.rs`, `UNICODE_VERSION = (18, 0, 0)` in the committed vendor patch; licenses/unicode-ident-v1-LICENSE-UNICODE.txt plus the crate terms/copyright notice. |
| Open-generated sounds (own work) | v1; tools/generate-sounds.py | Open-owned | Ships: open-event.caf and open-capture.caf; synthesized from seeded PCM, no reference audio. | `Packages/OpenKit/Sources/OpenFeatures/Resources/Sounds/`; reproducible source and PCM SHA-256 pins in `tools/generate-sounds.py`. No upstream sound license. |
| Open Intro (own work) | v2; tools/generate-intro-sound.py | Open-owned | Ships: original 20 s stereo AAC score and its PCM measurement reference; deterministic synthesis, no reference audio. | `Packages/OpenKit/Sources/OpenOnboarding/Resources/Onboarding/`; source, fixed seed and PCM SHA-256 pin in `tools/generate-intro-sound.py`. No upstream sound license. |
| Other Open-owned resources | main source snapshot | Open-owned | Ships: JS runtimes, JSON settings/catalog metadata, scripting definition. No copied fonts, sounds or image artwork. | See the complete resource map below. Derived emoji/PSL files have separate rows. System fonts, symbols, SQLite and Apple frameworks are OS-provided, not redistributed source dependencies. |
| adblock (Brave adblock-rust) | 0.8.11 | MPL-2.0 | Ships: browser-process network/cosmetic matching; redirect payloads have their own GPL row below. | `third_party/rust/adblock/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/adblock-v0_8/`; https://crates.io/crates/adblock/0.8.11 ; licenses/MPL-2.0.txt. Modified MPL Cargo.toml is in the vendor patch; public exact-source location UNSET (U-8). |
| uBlock Origin resources / scriptlets | 3762a26fd65df422080c116e6a70d13bc8d57d62 | GPL-3.0 | Ships: redirect stubs only (47 resources; no scriptlet templates), plus original redirect-source text and copyright/license notices under AdBlock/Source. | `Engine/fork/adblock/resources-pins.txt`; exact complete corresponding upstream source: https://codeload.github.com/gorhill/uBlock/tar.gz/3762a26fd65df422080c116e6a70d13bc8d57d62 ; source paths `src/web_accessible_resources/`, `src/js/redirect-resources.js`; output SHA-256 `6d4a87b8f0e44e0ffad66c5b66694c4a1da27383eaa11acae218030a29d9575e`; licenses/GPL-3.0.txt. Public distribution review remains U-6 / fork-infra Q-2. |
| json-rust string escaping excerpt | Embedded in adblock 0.8.11; original upstream revision not recorded | MIT | Ships: adblock resource argument string escaping, adapted from json-rust. | `adblock-v0_8/src/resources/resource_storage.rs:23` explicitly attributes json-rust; https://github.com/maciejhirsz/json-rust ; licenses/MIT-json-rust.txt. The license copy pin is provenance for the text, not a claim about the excerpt revision; review this with U-6. |
| rust-url parser excerpt | Embedded in adblock 0.8.11; original source header 2013–2016 | Apache-2.0 | Ships: parser code retained by adblock from rust-url. | `adblock-v0_8/src/url_parser/parser.rs` copyright/license header; licenses/rust-url-parser-NOTICE.txt, licenses/Apache-2.0.txt (Apache choice). This is separate from the url 2.5.8 crate row. |
| Rust: base64 | 0.13.1 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/base64/v0_13/README.chromium`, `third_party/rust/chromium_crates_io/vendor/base64-v0_13/`; https://crates.io/crates/base64/0.13.1 ; licenses/Apache-2.0.txt. |
| Rust: bitflags | 1.3.2 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/bitflags/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/bitflags-v1/`; https://crates.io/crates/bitflags/1.3.2 ; licenses/Apache-2.0.txt. |
| Rust: byteorder | 1.5.0 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/byteorder/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/byteorder-v1/`; https://crates.io/crates/byteorder/1.5.0 ; licenses/byteorder-v1-LICENSE-MIT.txt. |
| Rust: displaydoc | 0.2.7 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/displaydoc/v0_2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/displaydoc-v0_2/`; https://crates.io/crates/displaydoc/0.2.7 ; licenses/Apache-2.0.txt. |
| Rust: either | 1.18.0 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/either/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/either-v1/`; https://crates.io/crates/either/1.18.0 ; licenses/Apache-2.0.txt. |
| Rust: equivalent | 1.0.2 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/equivalent/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/equivalent-v1/`; https://crates.io/crates/equivalent/1.0.2 ; licenses/Apache-2.0.txt. |
| Rust: form_urlencoded | 1.2.2 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/form_urlencoded/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/form_urlencoded-v1/`; https://crates.io/crates/form_urlencoded/1.2.2 ; licenses/Apache-2.0.txt. |
| Rust: hashbrown | 0.17.1 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/hashbrown/v0_17/README.chromium`, `third_party/rust/chromium_crates_io/vendor/hashbrown-v0_17/`; https://crates.io/crates/hashbrown/0.17.1 ; licenses/Apache-2.0.txt. |
| Rust: icu_collections | 2.2.0 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_collections/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_collections-v2/`; https://crates.io/crates/icu_collections/2.2.0 ; licenses/Unicode-ICU4X.txt. |
| Rust: icu_locale_core | 2.3.0 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_locale_core/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_locale_core-v2/`; https://crates.io/crates/icu_locale_core/2.3.0 ; licenses/Unicode-ICU4X.txt. |
| Rust: icu_normalizer | 2.2.0 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_normalizer/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_normalizer-v2/`; https://crates.io/crates/icu_normalizer/2.2.0 ; licenses/Unicode-ICU4X.txt. |
| Rust: icu_normalizer_data | 2.2.0 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_normalizer_data/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_normalizer_data-v2/`; https://crates.io/crates/icu_normalizer_data/2.2.0 ; licenses/Unicode-ICU4X.txt. |
| Rust: icu_properties | 2.2.0 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_properties/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_properties-v2/`; https://crates.io/crates/icu_properties/2.2.0 ; licenses/Unicode-ICU4X.txt. |
| Rust: icu_properties_data | 2.2.0 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_properties_data/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_properties_data-v2/`; https://crates.io/crates/icu_properties_data/2.2.0 ; licenses/Unicode-ICU4X.txt. |
| Rust: icu_provider | 2.3.1 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/icu_provider/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/icu_provider-v2/`; https://crates.io/crates/icu_provider/2.3.1 ; licenses/Unicode-ICU4X.txt. |
| Rust: idna 0.2.3 | 0.2.3 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/idna/v0_2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/idna-v0_2/`; https://crates.io/crates/idna/0.2.3 ; licenses/Apache-2.0.txt. |
| Rust: idna 1.1.0 | 1.1.0 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/idna/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/idna-v1/`; https://crates.io/crates/idna/1.1.0 ; licenses/Apache-2.0.txt. |
| Rust: idna_adapter | 1.2.2 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/idna_adapter/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/idna_adapter-v1/`; https://crates.io/crates/idna_adapter/1.2.2 ; licenses/Apache-2.0.txt. |
| Rust: indexmap | 2.14.2 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/indexmap/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/indexmap-v2/`; https://crates.io/crates/indexmap/2.14.2 ; licenses/Apache-2.0.txt. |
| Rust: itertools | 0.10.5 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/itertools/v0_10/README.chromium`, `third_party/rust/chromium_crates_io/vendor/itertools-v0_10/`; https://crates.io/crates/itertools/0.10.5 ; licenses/Apache-2.0.txt. |
| Rust: itoa | 1.0.18 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/itoa/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/itoa-v1/`; https://crates.io/crates/itoa/1.0.18 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: litemap | 0.8.3 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/litemap/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/litemap-v0_8/`; https://crates.io/crates/litemap/0.8.3 ; licenses/Unicode-ICU4X.txt. |
| Rust: matches | 0.1.10 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/matches/v0_1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/matches-v0_1/`; https://crates.io/crates/matches/0.1.10 ; licenses/matches-v0_1-LICENSE.txt. |
| Rust: memchr | 2.8.3 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/memchr/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/memchr-v2/`; https://crates.io/crates/memchr/2.8.3 ; licenses/byteorder-v1-LICENSE-MIT.txt. |
| Rust: num-traits | 0.2.19 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/num_traits/v0_2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/num-traits-v0_2/`; https://crates.io/crates/num-traits/0.2.19 ; licenses/Apache-2.0.txt. |
| Rust: once_cell | 1.21.4 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/once_cell/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/once_cell-v1/`; https://crates.io/crates/once_cell/1.21.4 ; licenses/Apache-2.0.txt. |
| Rust: paste | 1.0.15 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/paste/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/paste-v1/`; https://crates.io/crates/paste/1.0.15 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: percent-encoding | 2.3.2 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/percent_encoding/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/percent-encoding-v2/`; https://crates.io/crates/percent-encoding/2.3.2 ; licenses/Apache-2.0.txt. |
| Rust: potential_utf | 0.1.6 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/potential_utf/v0_1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/potential_utf-v0_1/`; https://crates.io/crates/potential_utf/0.1.6 ; licenses/Unicode-ICU4X.txt. |
| Rust: proc-macro2 | 1.0.107 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/proc_macro2/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/proc-macro2-v1/`; https://crates.io/crates/proc-macro2/1.0.107 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: quote | 1.0.47 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/quote/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/quote-v1/`; https://crates.io/crates/quote/1.0.47 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: regex | 1.13.1 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/regex/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/regex-v1/`; https://crates.io/crates/regex/1.13.1 ; licenses/Apache-2.0.txt. |
| Rust: regex-automata | 0.4.18 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/regex_automata/v0_4/README.chromium`, `third_party/rust/chromium_crates_io/vendor/regex-automata-v0_4/`; https://crates.io/crates/regex-automata/0.4.18 ; licenses/Apache-2.0.txt. |
| Rust: regex-syntax | 0.8.11 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/regex_syntax/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/regex-syntax-v0_8/`; https://crates.io/crates/regex-syntax/0.8.11 ; licenses/Apache-2.0.txt. |
| Rust: rmp | 0.8.11 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/rmp/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/rmp-v0_8/`; https://crates.io/crates/rmp/0.8.11 ; licenses/rmp-serde-v0_15-LICENSE.txt. |
| Rust: rmp-serde | 0.15.5 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/rmp_serde/v0_15/README.chromium`, `third_party/rust/chromium_crates_io/vendor/rmp-serde-v0_15/`; https://crates.io/crates/rmp-serde/0.15.5 ; licenses/rmp-serde-v0_15-LICENSE.txt. |
| Rust: seahash | 3.0.7 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/seahash/v3/README.chromium`, `third_party/rust/chromium_crates_io/vendor/seahash-v3/`; https://crates.io/crates/seahash/3.0.7 ; licenses/seahash-v3-LICENSE.txt. |
| Rust: serde | 1.0.229 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/serde/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/serde-v1/`; https://crates.io/crates/serde/1.0.229 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: serde_core | 1.0.229 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/serde_core/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/serde_core-v1/`; https://crates.io/crates/serde_core/1.0.229 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: serde_derive | 1.0.229 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/serde_derive/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/serde_derive-v1/`; https://crates.io/crates/serde_derive/1.0.229 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: serde_json | 1.0.151 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/serde_json/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/serde_json-v1/`; https://crates.io/crates/serde_json/1.0.151 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: smallvec | 1.16.1 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/smallvec/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/smallvec-v1/`; https://crates.io/crates/smallvec/1.16.1 ; licenses/Apache-2.0.txt. |
| Rust: stable_deref_trait | 1.2.1 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/stable_deref_trait/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/stable_deref_trait-v1/`; https://crates.io/crates/stable_deref_trait/1.2.1 ; licenses/Apache-2.0.txt. |
| Rust: syn 2.0.119 | 2.0.119 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/syn/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/syn-v2/`; https://crates.io/crates/syn/2.0.119 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: syn 3.0.5 | 3.0.5 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/syn/v3/README.chromium`, `third_party/rust/chromium_crates_io/vendor/syn-v3/`; https://crates.io/crates/syn/3.0.5 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: synstructure | 0.13.2 | MIT | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/synstructure/v0_13/README.chromium`, `third_party/rust/chromium_crates_io/vendor/synstructure-v0_13/`; https://crates.io/crates/synstructure/0.13.2 ; licenses/synstructure-v0_13-LICENSE.txt. |
| Rust: thiserror | 1.0.69 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/thiserror/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/thiserror-v1/`; https://crates.io/crates/thiserror/1.0.69 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: thiserror-impl | 1.0.69 | Apache-2.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/thiserror_impl/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/thiserror-impl-v1/`; https://crates.io/crates/thiserror-impl/1.0.69 ; licenses/itoa-v1-LICENSE-APACHE.txt. |
| Rust: tinystr | 0.8.4 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/tinystr/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/tinystr-v0_8/`; https://crates.io/crates/tinystr/0.8.4 ; licenses/Unicode-ICU4X.txt. |
| Rust: tinyvec | 1.13.3 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/tinyvec/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/tinyvec-v1/`; https://crates.io/crates/tinyvec/1.13.3 ; licenses/tinyvec-v1-LICENSE-APACHE.txt. |
| Rust: unicode-bidi | 0.3.18 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/unicode_bidi/v0_3/README.chromium`, `third_party/rust/chromium_crates_io/vendor/unicode-bidi-v0_3/`; https://crates.io/crates/unicode-bidi/0.3.18 ; licenses/Apache-2.0.txt, licenses/unicode-bidi-v0_3-COPYRIGHT.txt. |
| Rust: unicode-ident | 1.0.24 | Apache-2.0, Unicode-3.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/unicode_ident/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/unicode-ident-v1/`; https://crates.io/crates/unicode-ident/1.0.24 ; licenses/itoa-v1-LICENSE-APACHE.txt, licenses/unicode-ident-v1-LICENSE-UNICODE.txt. |
| Rust: unicode-normalization | 0.1.26 | Apache-2.0, Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/unicode_normalization/v0_1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/unicode-normalization-v0_1/`; https://crates.io/crates/unicode-normalization/0.1.26 ; licenses/Apache-2.0.txt, licenses/unicode-ident-v1-LICENSE-UNICODE.txt, licenses/unicode-normalization-v0_1-COPYRIGHT.txt. |
| Rust: url | 2.5.8 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/url/v2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/url-v2/`; https://crates.io/crates/url/2.5.8 ; licenses/Apache-2.0.txt. |
| Rust: utf16_iter | 1.0.5 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/utf16_iter/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/utf16_iter-v1/`; https://crates.io/crates/utf16_iter/1.0.5 ; licenses/tinyvec-v1-LICENSE-APACHE.txt. |
| Rust: utf8_iter | 1.0.4 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/utf8_iter/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/utf8_iter-v1/`; https://crates.io/crates/utf8_iter/1.0.4 ; licenses/tinyvec-v1-LICENSE-APACHE.txt. |
| Rust: write16 | 1.0.0 | Apache-2.0 | Ships: browser-process adblock dependency. | `third_party/rust/write16/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/write16-v1/`; https://crates.io/crates/write16/1.0.0 ; licenses/tinyvec-v1-LICENSE-APACHE.txt. |
| Rust: writeable | 0.6.4 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/writeable/v0_6/README.chromium`, `third_party/rust/chromium_crates_io/vendor/writeable-v0_6/`; https://crates.io/crates/writeable/0.6.4 ; licenses/Unicode-ICU4X.txt. |
| Rust: yoke | 0.8.3 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/yoke/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/yoke-v0_8/`; https://crates.io/crates/yoke/0.8.3 ; licenses/Unicode-ICU4X.txt. |
| Rust: yoke-derive | 0.8.2 | Unicode-3.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/yoke_derive/v0_8/README.chromium`, `third_party/rust/chromium_crates_io/vendor/yoke-derive-v0_8/`; https://crates.io/crates/yoke-derive/0.8.2 ; licenses/Unicode-ICU4X.txt. |
| Rust: zerofrom | 0.1.8 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/zerofrom/v0_1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/zerofrom-v0_1/`; https://crates.io/crates/zerofrom/0.1.8 ; licenses/Unicode-ICU4X.txt. |
| Rust: zerofrom-derive | 0.1.7 | Unicode-3.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/zerofrom_derive/v0_1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/zerofrom-derive-v0_1/`; https://crates.io/crates/zerofrom-derive/0.1.7 ; licenses/Unicode-ICU4X.txt. |
| Rust: zerotrie | 0.2.5 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/zerotrie/v0_2/README.chromium`, `third_party/rust/chromium_crates_io/vendor/zerotrie-v0_2/`; https://crates.io/crates/zerotrie/0.2.5 ; licenses/Unicode-ICU4X.txt. |
| Rust: zerovec | 0.11.8 | Unicode-3.0 | Ships: browser-process adblock dependency. | `third_party/rust/zerovec/v0_11/README.chromium`, `third_party/rust/chromium_crates_io/vendor/zerovec-v0_11/`; https://crates.io/crates/zerovec/0.11.8 ; licenses/Unicode-ICU4X.txt. |
| Rust: zerovec-derive | 0.11.6 | Unicode-3.0 | Build only: host proc macro or its dependency; host executable is not bundled. Generated code notices are retained. | `third_party/rust/zerovec_derive/v0_11/README.chromium`, `third_party/rust/chromium_crates_io/vendor/zerovec-derive-v0_11/`; https://crates.io/crates/zerovec-derive/0.11.6 ; licenses/Unicode-ICU4X.txt. |
| Rust: zmij | 1.0.23 | MIT | Ships: browser-process adblock dependency. | `third_party/rust/zmij/v1/README.chromium`, `third_party/rust/chromium_crates_io/vendor/zmij-v1/`; https://crates.io/crates/zmij/1.0.23 ; licenses/seahash-v3-LICENSE.txt. |
| aho-corasick | 1.1.5 | MIT OR Unlicense | Not shipped: no regex perf-literal feature and no adblock GN dependency; retained for the U-6 review. | Pinned Chromium `third_party/rust/aho_corasick/v1/README.chromium`; source crate cache `aho-corasick-1.1.5/LICENSE-MIT` and `UNLICENSE`; licenses/aho-corasick-LICENSE-MIT.txt, licenses/aho-corasick-UNLICENSE.txt. Other Chromium consumers still require the complete generated Chromium credits. |
| EasyList | 202611072258; snapshot commit 256e23a0e35b8a32cd7db5bff4801210cd2ff23d; header source commit b52f0f1aca4574d9a40672a98293baf7a84a0c41 | GPL-3.0-or-later OR CC-BY-SA-3.0 (upstream also permits later CC versions) | Ships: unmodified seed text with headers at Open.app/Contents/Resources/AdBlock/easylist.txt. | The EasyList authors (https://easylist.to/); exact source https://raw.githubusercontent.com/easylist/easylist/256e23a0e35b8a32cd7db5bff4801210cd2ff23d/easylist.txt ; SHA-256 756ddc9aaae3c4c9a76068dc1dfc10129dba78721ddf79f07340c8102950c2b5; pin in Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt; terms https://easylist.to/pages/licence.html ; licenses/GPL-3.0.txt, licenses/CC-BY-SA-3.0.txt. |
| EasyPrivacy | 202611072258; snapshot commit 256e23a0e35b8a32cd7db5bff4801210cd2ff23d; header source commit b52f0f1aca4574d9a40672a98293baf7a84a0c41 | GPL-3.0-or-later OR CC-BY-SA-3.0 (upstream also permits later CC versions) | Ships: unmodified seed text with headers at Open.app/Contents/Resources/AdBlock/easyprivacy.txt. | The EasyList authors (https://easylist.to/); exact source https://raw.githubusercontent.com/easylist/easylist/256e23a0e35b8a32cd7db5bff4801210cd2ff23d/easyprivacy.txt ; SHA-256 c1d09df31b339231a79a5e389031ea09745b229f90c9e379aca1f2d4b7e07813; pin in Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt; terms https://easylist.to/pages/licence.html ; licenses/GPL-3.0.txt, licenses/CC-BY-SA-3.0.txt. |
| Other catalog filter subscriptions | Runtime-selected catalog URLs | Per-list terms; not included in this bundle | Not shipped: downloaded only when enabled; no other catalog payload is bundled. | Packages/OpenKit/Sources/OpenAdBlock/Resources/catalog.json; upstream list URLs and terms must be reviewed when adding a bundled list. |

Patent note: release builds enable proprietary codecs. H.264/AAC patent licensing for distribution is
not granted by any open-source license above and is part of the §10 user
gate. The plan ships the acknowledgment; it does not clear the patent risk.

## Public MPL source location (U-8)

Public MPL source location: UNSET

The user must choose a public repository or mirror under release plan U-8.
Publish the exact adblock sources and Open modifications, both Swift PSL
snapshots and the psl crate's generated list source without authentication.
The pinned private repository alone does not meet the public source offer.
Then replace UNSET above with the HTTPS location and verify anonymous access.
The generator checks URL syntax only; it does not test public access.
`--require-public-source` and `--require-cef-credits` refuse an unset offer.
No source was published or release user step performed by this audit.

## Bundled filter lists and U-6 license choice

`tools/fetch-adblock-lists.sh` verifies the immutable snapshot URLs and
SHA-256 values in `list-pins.txt`. `tools/embed-adblock.sh` copies those
bytes without changes into the app. Both pinned files retain these header
lines (EasyList and EasyPrivacy each have the same version and source commit):

```text
! Version: 202611072258
! Last modified: 07 Nov 2026 22:58 UTC
! Commit: b52f0f1aca4574d9a40672a98293baf7a84a0c41
! Homepage: https://easylist.to/
! Licence: https://easylist.to/pages/licence.html
```

The headers link to the terms; they do not spell out the license names.
That authoritative page states:

> Unless otherwise noted, the contents of the EasyList repository
> (https://github.com/easylist) is dual licensed under the GNU
> General Public License version 3 of the License, or (at your option)
> any later version, and Creative Commons Attribution-ShareAlike 3.0
> Unported, or (at your option) any later version. You may use and/or
> modify the files as permitted by either licence; if required,
> "The EasyList authors (https://easylist.to/)" should be
> attributed as the source of the material.

U-6 must **confirm the license choice for the bundled filter lists; Open
distributes them unmodified**. Both alternatives and their full texts are
retained in acknowledgements pending that written review. Including both
texts does not select a license or close U-6. The snapshot commit in the
pin URLs identifies the exact distributed files; the different commit in
their headers identifies the upstream source used to generate those files.

## uBlock redirect assets: §7.3(b)

The app now ships the pinned redirect resources in the row above. The build
stages original text sources and LICENSE.txt from the same hash-verified uBO
archive, embeds them under `AdBlock/Source`, and passes that directory as
`--ubo-source` to the acknowledgements generator. The exact complete upstream
archive is linked in the row above; binary stub bodies are encoded unchanged
by the crate in resources.json. The locked assembly driver is Open-owned
build code in `tools/adblock-resources/`. No scriptlet templates ship.
`licenses/GPL-3.0.txt` remains in the generated acknowledgements. This local
bundle does not close U-6 or authorize a public release.

The Sparkle checkout at the exact pin confirms bspatch is in its shared
bsdiff library, while sais is used by bsdiff in delta-creation tools. Those
tools are not embedded in Open.app. Their upstream notices remain intact
in the whole Sparkle license. Sparkle does not state independent revisions
for Ed25519 or SUSignatureVerifier in that license.

## Open.app resource map

`Packages/OpenKit/Package.swift` declares no remote Swift dependencies.
`project.yml` adds only Sparkle 2.10.1. Local OpenKit products link the Apple
system libraries/frameworks; no third-party Swift source package is hidden
behind another remote package. OpenSettings and OpenSiteControl both depend
on OpenAdBlock, so its resources do ship transitively today.

| Bundle resource | Repository source | Ownership / license |
|---|---|---|
| OpenKit_OpenSuggest.bundle/Contents/Resources/public_suffix_list.dat | Sources/OpenSuggest/Resources/public_suffix_list.dat | PSL, MPL-2.0 |
| OpenKit_OpenAdBlock.bundle/Contents/Resources/Resources/{catalog.json,list-pins.txt,resources-pins.txt,resources.json,public_suffix_list.dat} | Sources/OpenAdBlock/Resources/ | Open-owned catalog/hash metadata; PSL is MPL-2.0; resources.json is GPL-3.0 |
| AdBlock/{easylist.txt,easyprivacy.txt} | Vendor/adblock/ staged from the commit-pinned URLs in Sources/OpenAdBlock/Resources/list-pins.txt | The EasyList authors; GPL-3.0-or-later OR CC-BY-SA-3.0 (later CC versions also permitted); unmodified headers retained |
| AdBlock/{resources.json,Source/} | Vendor/adblock/ generated from resources-pins.txt | uBlock Origin redirect stubs and original text sources/notices; GPL-3.0 |
| OpenKit_OpenSpaceEditor.bundle/Contents/Resources/emoji-index.json | Sources/OpenSpaceEditor/Resources/emoji-index.json | Derived Unicode 17.0 data; Unicode-3.0 |
| OpenKit_OpenFeatures.bundle/Contents/Resources/Sounds/{open-capture.caf,open-event.caf} | Sources/OpenFeatures/Resources/Sounds/ | Open-owned generated audio |
| OpenKit_OpenOnboarding.bundle/Contents/Resources/Onboarding/{open-intro.m4a,open-intro-reference.json} | Sources/OpenOnboarding/Resources/Onboarding/ | Open-owned generated intro audio and PCM measurements |
| OpenKit_OpenBoosts.bundle/Contents/Resources/{boost-applier.js,zap-picker.js} | Sources/OpenBoosts/Resources/ | Open-owned runtime source |
| OpenKit_OpenTranslate.bundle/Contents/Resources/translate-runtime.js | Sources/OpenTranslate/Resources/ | Open-owned runtime source |
| OpenKit_OpenMedia.bundle/Contents/Resources/pip-site-rules.json | Sources/OpenMedia/Resources/pip-site-rules.json | Open-owned site rules |
| OpenKit_OpenSleep.bundle/Contents/Resources/keep-alive-sites.json | Sources/OpenSleep/Resources/keep-alive-sites.json | Open-owned defaults |
| OpenKit_OpenCommands.bundle/Contents/Resources/expected-menu.json | Sources/OpenCommands/Resources/expected-menu.json | Open-owned menu facts, no upstream assets |
| Open.sdef | App/Resources/Open.sdef | Open-owned scripting definition |
| Credits.rtf, Acknowledgements.txt, CREDITS.html | Generated at build time | This inventory and upstream texts; Chromium HTML remains incomplete in the current engine |
| Sparkle.framework and nested helpers/XPC/localizations | Sparkle 2.10.1 binary package | Whole upstream LICENSE, including bsdiff, sais-lite, Ed25519 and SUSignatureVerifier notices |
| Chromium Embedded Framework.framework; locale paks, resources.pak, chrome_100_percent.pak, chrome_200_percent.pak, icudtl.dat, V8 snapshots, graphics libraries/data | Recorded main CEF distribution Release/ | Chromium/CEF and their transitive licenses; exact generated Chromium credits still required |
| OpenEngine.framework, five Open Helper apps, Open executable | Engine/OpenEngine/, Helper/, App/ | Open-owned bridge/shell; linked third-party engine covered above |

Resource paths in the map are relative to `Open.app/Contents/Resources/`.
`Sources/` in the map means `Packages/OpenKit/Sources/`. No `.ttf`, `.otf`
or third-party sound file is declared by the shell. AppleColorEmoji, system
fonts and SF Symbols are supplied by macOS. Chromium's packed assets are
covered by its own generated credits, not by the shell asset audit.
CLI fixture bundles (openkit, sidebar-render, space-editor-render and
sitecontrol-render) are not products embedded by the Open target.

## Rust provenance and security review

The adblock dependency walk has 70 exact crate/version entries. It follows
`deps` in the pinned `BUILD.gn` files after the committed Rust patch, stops
host proc-macro dependencies for the runtime classification, and retains
all host tools above. `Engine/fork/licenses/THIRD_PARTY.md` lists Open's 23
added crates; Chromium supplies the remaining crates. The existing crates
are not new dependencies introduced by this license PR.
`docs/engine-patches.md` "Security review" records the 23 crates.io archive
SHA-256 values and the regex feature edits. The matching cached archives
were checked during this audit; the receipt gives the result.

U-6 must review adblock/regex in the privileged browser process, excluded
aho-corasick, the three PSL copies, parser limits and the pending fuzz/time
limit work. Existing advisory notes remain: idna 0.2.3 RUSTSEC-2024-0421 is
list-domain handling (request hosts use idna 1.1.0); rmp-serde 0.15.5
RUSTSEC-2022-0092 concerns Raw/RawRef (adblock does not use them); paste 1.0.15
RUSTSEC-2024-0436 is an unmaintained build macro. These are impact notes,
not closure of the security review.

## Chromium credits blocker

The read-only recorded distribution is under
`$HOME/Developer/open-engine-s8-main/chromium_git/chromium/src/cef/binary_distrib/cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64_minimal/`.
Its `CREDITS.html` is 401 bytes and contains `This is sample credits page`
and `generate_about_credits=true`. It is not a third-party license list.
The engine owner must generate complete about_credits for the matching
engine build and refresh the recorded distribution. This task does not
edit or build an engine tree.

The generator copies the exact HTML to `CREDITS.html` next to both the RTF
and TXT. It includes complete HTML text in acknowledgements only if the
input passes the completeness check. Preview output labels the sample as
incomplete. Release mode refuses it. `tools/release.sh` also copies the
HTML twin beside release artifacts; it never substitutes another browser's
credits. Nothing strips upstream licenses already in a framework.

## Committed upstream texts

All files below preserve upstream bytes. No legal text was typed from
memory. Sources are the committed vendor patch, matching Cargo source
cache, pinned upstream Chromium/FFmpeg files, and the existing pinned CEF,
Sparkle, Mozilla, GNU and Unicode texts. Copies with identical SHA-256
share a file; distinct copyright notices remain distinct. The inventory
rows identify each crate's own source file through `README.chromium`.

| File | Upstream source | SHA-256 |
|---|---|---|
| licenses/Apache-2.0.txt | `third_party/rust/chromium_crates_io/vendor/addr-v0_14/LICENSE-APACHE` | `a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2` |
| licenses/BSD-CEF.txt | CEF `4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f/LICENSE.txt`; also Vendor/cef/LICENSE.txt | `058c3827ffb827ff3edda471ae7e1bb1d1aa5931985f0126043ccd33409e792f` |
| licenses/BSD-Chromium.txt | Chromium `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/LICENSE` | `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b` |
| licenses/CC-BY-SA-3.0.txt | Creative Commons authoritative legal code: https://creativecommons.org/licenses/by-sa/3.0/legalcode.txt (downloaded 2026-11-08; unchanged UTF-8 bytes) | `3f941b3b89cf7b8370ceb83cc76d2120d471b58735d8ca60238a751a48d7f72f` |
| licenses/FFmpeg-CREDITS.txt | FFmpeg `9db86ce5b5b454dfc96c435f9f0723012980c37f/CREDITS.chromium` | `903a6faa336b60d419bc6eb2bcffe4ca8bd9446735e5de4fcc901c80e9f22327` |
| licenses/GPL-3.0.txt | https://www.gnu.org/licenses/gpl-3.0.txt (existing committed upstream copy) | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |
| licenses/LGPL-2.1-FFmpeg.txt | FFmpeg `9db86ce5b5b454dfc96c435f9f0723012980c37f/COPYING.LGPLv2.1` | `246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30` |
| licenses/MIT-Sparkle.txt | Sparkle `ab7d71291238df6e0492143b120c9b696a35f603/LICENSE` (whole external notices included) | `389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe` |
| licenses/MIT-json-rust.txt | json-rust `0775592d339002ab148185264970c2a6e30b5d37/LICENSE-MIT` (upstream copy; excerpt revision is not recorded by adblock) | `72f0893758d2b526b3908cca7a8c0034044f7866c43b60d5f3ae4b18cc389eae` |
| licenses/MPL-2.0.txt | `third_party/rust/chromium_crates_io/vendor/adblock-v0_8/LICENSE` | `3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04` |
| licenses/Unicode-3.0.txt | https://www.unicode.org/license.txt (2026-11-06 committed Unicode V3 copy) | `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` |
| licenses/Unicode-ICU4X.txt | `third_party/rust/chromium_crates_io/vendor/icu_collections-v2/LICENSE` | `f367c1b8e1aa262435251e442901da4607b4650e0e63a026f5044473ecfb90f2` |
| licenses/aho-corasick-LICENSE-MIT.txt | Cargo source cache `aho-corasick-1.1.5/LICENSE-MIT` | `0f96a83840e146e43c0ec96a22ec1f392e0680e6c1226e6f3ba87e0740af850f` |
| licenses/aho-corasick-UNLICENSE.txt | Cargo source cache `aho-corasick-1.1.5/UNLICENSE` | `7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c` |
| licenses/byteorder-v1-LICENSE-MIT.txt | `third_party/rust/chromium_crates_io/vendor/byteorder-v1/LICENSE-MIT` | `0f96a83840e146e43c0ec96a22ec1f392e0680e6c1226e6f3ba87e0740af850f` |
| licenses/itoa-v1-LICENSE-APACHE.txt | `third_party/rust/chromium_crates_io/vendor/itoa-v1/LICENSE-APACHE` | `62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a` |
| licenses/matches-v0_1-LICENSE.txt | `third_party/rust/chromium_crates_io/vendor/matches-v0_1/LICENSE` | `d7b49708075b5f43f8e108464f1970c8c66fa8b6afce4f9c944da3af77cc1460` |
| licenses/psl-v2-LICENSE.txt | `third_party/rust/chromium_crates_io/vendor/psl-v2/LICENSE` | `f09adf500d35265ee63ef552f8e61487e09ee549da66eaf0ec7924e3ad7cf14b` |
| licenses/rmp-serde-v0_15-LICENSE.txt | `third_party/rust/chromium_crates_io/vendor/rmp-serde-v0_15/LICENSE` | `979d35e1d157289100ba2a7eb13fffe4e7a1b93506c755c4c66890918e467c4e` |
| licenses/rust-url-parser-NOTICE.txt | Vendor patch `adblock-v0_8/src/url_parser/parser.rs` first copyright/license comment (also exact cached adblock 0.8.11 source) | `891519f4249e526687d08cdbd096a2dcb96be60b408870b2f722fcf3915daec1` |
| licenses/seahash-v3-LICENSE.txt | `third_party/rust/chromium_crates_io/vendor/seahash-v3/LICENSE` | `23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3` |
| licenses/synstructure-v0_13-LICENSE.txt | `third_party/rust/chromium_crates_io/vendor/synstructure-v0_13/LICENSE` | `219920e865eee70b7dcfc948a86b099e7f4fe2de01bcca2ca9a20c0a033f2b59` |
| licenses/tinyvec-v1-LICENSE-APACHE.txt | `third_party/rust/chromium_crates_io/vendor/tinyvec-v1/LICENSE-APACHE.md` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| licenses/unicode-bidi-v0_3-COPYRIGHT.txt | `third_party/rust/chromium_crates_io/vendor/unicode-bidi-v0_3/COPYRIGHT` | `edb20b474f6cbd4f4db066b54a9e0f687d0009d309412a63431189b59b8e2a07` |
| licenses/unicode-ident-v1-LICENSE-UNICODE.txt | `third_party/rust/chromium_crates_io/vendor/unicode-ident-v1/LICENSE-UNICODE` | `f7db81051789b729fea528a63ec4c938fdcb93d9d61d97dc8cc2e9df6d47f2a1` |
| licenses/unicode-normalization-v0_1-COPYRIGHT.txt | `third_party/rust/chromium_crates_io/vendor/unicode-normalization-v0_1/COPYRIGHT` | `23860c2a7b5d96b21569afedf033469bab9fe14a1b24a35068b8641c578ce24d` |

Chromium's own BSD license and the other Chromium/codec licenses belong in
the matching distribution's complete `CREDITS.html`. The current dev
distribution instead contains the 401-byte upstream sample credits page
(`This is sample credits page`, `generate_about_credits=true`). It is not
complete credits. `--require-cef-credits` rejects that sample; a release must
provide real generated credits and copy the HTML twin beside its artifacts.
The default generator can preview the prepared inventory without that input,
but prints an explicit warning and includes the missing-credits status in
both outputs. Such a preview is not release-license acceptance.

MPL source changes must remain available as source at the public location
chosen under U-8; a commit in the current private repository is not enough.
The inventory and artifacts do not close the release plan's license/patent
review gate. Public distribution waits for the user's §10 confirmation.

The Section 13 Step 4 engine branch removes adblock's embedded PSL and its
`addr`, `psl` and `psl-types` crates. Its CXX resolver uses Chromium's existing
registry data, including private registries. Swift's separate PSL remains.
The final distribution must carry this source and license inventory together.

Full audit and build receipts: [license audit](license-audit.md). Public
release acceptance requires the generated Chromium inventory/texts,
U-8's verified source location and the user's written U-6 confirmation.
