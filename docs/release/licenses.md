# Release license inventory

Snapshot: 2026-10-25, Chromium/CEF pins from `Engine/fork/VERSIONS`.
Update the affected row in the same PR that changes a shipped component.
Rows marked **not yet linked** or **not bundled** are preparation records;
the generator omits them from the shipped component paragraphs.

| Component | Version | License | How Open uses it | Source / offer |
|---|---|---|---|---|
| Chromium | 156.0.8078.48 | BSD-style (Chromium license) | Engine core | https://chromium.googlesource.com/chromium/src/+/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/LICENSE ; full third-party credits must come from the matching CEF distribution's CREDITS.html |
| CEF | 156.0.14+g4fa4ab5 (branch 8078) | BSD | Embedding layer | https://github.com/chromiumembedded/cef/tree/4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f ; Vendor/cef/LICENSE.txt; committed text BSD-CEF.txt below |
| adblock (Brave adblock-rust) | 0.8.11 — not yet linked | MPL-2.0 | Planned browser-process network and cosmetic matching | https://github.com/brave/adblock-rust/tree/v0.8.11 ; fork-infra Step 8 has not vendored the crate. When linked, publish the vendored sources and all modified MPL files in https://github.com/SergeSerb2/open/tree/main/Engine/fork/patches/rust/ |
| Public Suffix List | 2026-10-22_08-36-41_UTC; commit 8437e5262f13305f94087abe699b4fe2be1d1de8 | MPL-2.0 | OpenSuggest URL-versus-search decisions; same snapshot in OpenAdBlock | https://publicsuffix.org/list/public_suffix_list.dat ; source snapshot with intact MPL header: https://github.com/SergeSerb2/open/tree/main/Packages/OpenKit/Sources/OpenSuggest/Resources/public_suffix_list.dat ; modified MPL files remain available in this public repository |
| FFmpeg (Chromium bundled) | Chromium 156.0.8078.48 pin | LGPL-2.1 (Chromium build) | H.264/AAC with proprietary_codecs=true and ffmpeg_branding="Chrome" | https://chromium.googlesource.com/chromium/src/+/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/third_party/ffmpeg/ ; full component license and notices must be included in the generated Chromium credits |
| Sparkle | not yet linked (Step 7 chooses the exact pin) | MIT | Planned update framework | https://github.com/sparkle-project/Sparkle ; MIT-Sparkle.txt is prepared from upstream 2.10.1, not a dependency pin. Update this row and verify the license text when Step 7 lands |
| Filter lists (EasyList, EasyPrivacy, catalog subscriptions) | not bundled in the current app; list-pins.txt snapshots 2026-10-25 | Each list's own license | Downloaded ad-block data; OpenAdBlock is not linked by the current app target | https://easylist.to/ ; Packages/OpenKit/Sources/OpenAdBlock/Resources/catalog.json records every upstream URL; list-pins.txt records the EasyList and EasyPrivacy hashes. Review each list's own terms before bundling; catalog entries alone are not bundled asset evidence |

Patent note: release builds enable proprietary codecs. H.264/AAC patent licensing for distribution is
not granted by any open-source license above and is part of the §10 user
gate. The plan ships the acknowledgment; it does not clear the patent risk.

## Conditional GPL-3.0 component

uBlock Origin resources / scriptlets do **not** ship in the current app.
There is no shipped-component table row for them. Catalog URLs for optional
filter downloads are not bundled scriptlets or resource replacements.
`GPL-3.0.txt` is prepared for the conditional case only and is omitted from
Credits until a row named `uBlock Origin resources / scriptlets` is added.
When those assets ship, that row must give their exact upstream pin, GPL-3.0,
and a public corresponding-source URL. Bundle them as source text together
with the full GPL-3.0 license, or do not ship them. The generator requires
an explicit `--ubo-source` directory and checks that it contains source text.

## Committed upstream texts

The files are unmodified upstream bytes, fetched 2026-10-25. Source URL and
version/commit are recorded here beside each file, rather than prepended
to the legal text.

| File | Upstream source | Version / commit | SHA-256 |
|---|---|---|---|
| licenses/MPL-2.0.txt | https://www.mozilla.org/media/MPL/2.0/index.txt | Mozilla Public License 2.0 | 3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04 |
| licenses/GPL-3.0.txt | https://www.gnu.org/licenses/gpl-3.0.txt | GNU General Public License 3, 29 June 2007 | 3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986 |
| licenses/MIT-Sparkle.txt | https://raw.githubusercontent.com/sparkle-project/Sparkle/ab7d71291238df6e0492143b120c9b696a35f603/LICENSE | Sparkle 2.10.1, ab7d71291238df6e0492143b120c9b696a35f603 | 389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe |
| licenses/BSD-CEF.txt | https://raw.githubusercontent.com/chromiumembedded/cef/4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f/LICENSE.txt | CEF 156.0.14+g4fa4ab5, branch 8078 | 058c3827ffb827ff3edda471ae7e1bb1d1aa5931985f0126043ccd33409e792f |

Chromium's own BSD license and the other Chromium/codec licenses belong in
the matching distribution's complete `CREDITS.html`. The current dev
distribution instead contains the 401-byte upstream sample credits page
(`This is sample credits page`, `generate_about_credits=true`). It is not
complete credits. `--require-cef-credits` rejects that sample; a release must
provide real generated credits and copy the HTML twin beside its artifacts.
The default generator can preview the prepared inventory without that input,
but prints an explicit warning and includes the missing-credits status in
both outputs. Such a preview is not release-license acceptance.

MPL source changes must be committed as source in this public repository.
The inventory and artifacts do not close the release plan's license/patent
review gate. Public distribution waits for the user's §10 confirmation.
