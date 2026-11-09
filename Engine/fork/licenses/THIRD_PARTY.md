# Third-party dependencies in the engine fork

Every new dependency needs a row here in the same PR that introduces it
(repo rule: minimal dependencies, each with a written reason).

| Crate / library | Version | License | Used by | Reason | Source offer / notes |
|---|---|---|---|---|---|
| adblock (Brave adblock-rust) | 0.8.11 | MPL-2.0 | //open/adblock (browser process) | Network + cosmetic matching at uBlock quality; see docs/adblock-design.md | Vendored in patches/rust/0001-adblock-vendor.patch; licenses/MPL-2.0.txt copied from the crate. Crate patches: bounded background regex compilation, generated ASCII ABP patterns and exact DAT object sharing (docs/engine-patches.md "Security review"). Modified MPL files stay under MPL-2.0. |
| base64 | 0.13.1 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (resources (scriptlets) decoding; second epoch beside Chromium's 0.22) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| bitflags | 1.3.2 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (filter option flags; second epoch beside Chromium's 2) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| form_urlencoded | 1.2.2 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via url) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| idna | 0.2.3 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (adblock hostname handling) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| idna | 1.1.0 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via url) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| idna_adapter | 1.2.2 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via idna 1) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| itertools | 0.10.5 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (second epoch beside Chromium's 0.14) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| matches | 0.1.10 | MIT | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via idna 0.2) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| paste | 1.0.15 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (proc macro, via rmp 0.8.11 (build time only)) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| percent-encoding | 2.3.2 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (URL handling) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| rmp | 0.8.11 | MIT | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (serialized engine (DAT); pinned =0.8.11, gnrt would pick 0.8.15 (adblock-fork §4.2)) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| rmp-serde | 0.15.5 | MIT | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (serialized engine (DAT)) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| seahash | 3.0.7 | MIT | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (filter hashing. Published without a license file: crate patch adds upstream's MIT text (gitlab.redox-os.org/redox-os/seahash commit 3088c5c9)) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| thiserror | 1.0.69 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (second epoch beside Chromium's 2) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| thiserror-impl | 1.0.69 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (proc macro for thiserror 1 (build time only)) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| tinyvec | 1.13.3 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via unicode-normalization) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| unicode-bidi | 0.3.18 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via idna 0.2 (was an empty placeholder in Chromium)) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| unicode-normalization | 0.1.26 | Apache-2.0, Unicode-3.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (via idna 0.2) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| url | 2.5.8 | Apache-2.0 | //open/adblock (via adblock) | Dependency of adblock 0.8.11 (request URL parsing) | Vendored in patches/rust/0001-adblock-vendor.patch; license file and record in its generated README.chromium |
| regex (Chromium crate, now shipped) | 1.13.1 | Apache-2.0 | //open/adblock (via adblock) | adblock cannot work without it | Already vendored by Chromium as group "test" (libafl only). Open moves it to "safe" and builds it without its perf features (docs/engine-patches.md "Security review") |

The lead approved MPL-2.0 and a vendor patch of about 20 MB (the captured
patch is 11.3 MB). Licenses are as `gnrt` records them in each crate's
`README.chromium`; for dual-licensed crates (`MIT OR Apache-2.0`) that is the
Apache-2.0 choice. Filter lists and the uBlock Origin resources file are data
owned by the feature plan (adblock-fork §9), not rows here.
