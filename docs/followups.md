# Follow-ups

Small items found during review and verification. Each line: area — issue — where found.

- Favicons — after a candidate is blocked as private (SSRF guard), the fetcher marks the origin failed instead of trying the same-origin `/favicon.ico` fallback. — lead check of PR #12, 2026-10-25
- Engine — inject Open's page runtimes (Zap picker, Boost applier internals) in an isolated world (Chromium content-script world), so pages cannot reach the picker overlay or its bridge. Main-world injection is only for user Boost JS. — PR #23 review, 2026-10-25
- Licensing — pre-release license review: adblock-rust (MPL-2.0), uBlock Origin resources/scriptlets (GPL-3.0), Public Suffix List (MPL-2.0), Chromium/CEF (BSD), proprietary codecs (H.264/AAC licensing) in release builds. — adblock plan, 2026-10-25
