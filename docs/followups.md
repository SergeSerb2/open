# Follow-ups

Small items found during review and verification. Each line: area — issue — where found.

- Favicons — after a candidate is blocked as private (SSRF guard), the fetcher marks the origin failed instead of trying the same-origin `/favicon.ico` fallback. — lead check of PR #12, 2026-10-25
- Engine — inject Open's page runtimes (Zap picker, Boost applier internals) in an isolated world (Chromium content-script world), so pages cannot reach the picker overlay or its bridge. Main-world injection is only for user Boost JS. — PR #23 review, 2026-10-25
- Licensing — pre-release license review: adblock-rust (MPL-2.0), uBlock Origin resources/scriptlets (GPL-3.0), Public Suffix List (MPL-2.0), Chromium/CEF (BSD), proprietary codecs (H.264/AAC licensing) in release builds. — adblock plan, 2026-10-25
- Engine fork — non-official builds must not apply the field-trial testing config: it breaks child-process launch on macOS 27.2 beta (GPU launch error 1003, `sandbox_extension_issue_file_to_process` EPERM). Add `disable_fieldtrial_testing_config=true` to `Engine/fork/gn/dev.args.gn` with the first patched build; until then OpenEngine passes `--disable-field-trial-config`. Verified with cefsimple and Open.app on the 2026-10-25 stock build. — lead, 2026-10-25
- Engine fork — one remaining non-fatal `sandbox_extension_issue_file_to_process … Operation not permitted` line for the app bundle when run from /tmp; re-check from /Applications and a normal path. — lead, 2026-10-25
- Engine (profiles) — CEF logs "Cannot create profile at path …/Profiles/Profile-<id>/Engine" when a non-default profile opens: every request-context cache_path must be a child of `root_cache_path`. Set `root_cache_path` = `<data root>/Profiles`, global `cache_path` = `Profiles/Default` (lead decision 4), other profiles `Profiles/<dir>/Engine`; verify cookie persistence across relaunch for a second profile. Owner: engine lead. — app-shell Step B report, 2026-10-25
