# Imported secrets acceptance (Section 15)

The App writes imported passwords, cookies, cards and addresses through each mapped Profile's OpenEngine context. Existing Open records win. The real Settings and first-run adapters use explicit consent, bounded batches, durable per-kind writes and counts-only reports. Profile retirement cancels the mapped task, drains writes and drops the sink before folder removal.

M5 synthetic acceptance passed on 2026-11-08. The native App source is `ef81d706`, which merges main `40c2ab94` (#265). G6 changed the Python harness and docs only after that Debug build. The engine is main's #264 distribution, framework SHA-256 `619324d328e529295a01a56c9e596d21eb216d6ab1cebe22c5a20d6862815399`; embedded code SHA-256 `bdb0c2581cfde2cd038ab90c8c177336e72bf23e598f8ed935e235fc9962695f`.

[The sanitized runtime receipt](results-imported-secrets-g6.json) records every row, load, command, cleanup count, prior attempt and final import-harness hash. The PR body records focused and full verification on the final commit. Loads below are 1 / 5 / 15 minutes. Queue loads are kept separately in the JSON.

| Final suite | Result | Load at screen acquisition | Load after |
|---|---|---|---|
| `G6-secrets-import-profile-fixed` | 10 PASS; 2 M1-only | 7.55 / 8.92 / 10.53 | 8.86 / 9.08 / 10.53 |
| `G6-firstrun` | 97 PASS | 30.61 / 18.75 / 13.96 | 18.02 / 18.90 / 15.17 |
| `G6-features` | 26 PASS; 1 M1-only | 14.98 / 18.21 / 15.27 | 38.93 / 23.49 / 17.52 |

All three final suites have zero foreground interruptions and cleanup PASS, with zero owned processes or windows left. They used separate `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock` calls, the priority rule, the pinned fingerprint, `--stop-on-app-death`, a 120-second row cap and a 600-second suite cap (1,200 seconds for first run). `OPEN_E2E_NO_CRASH_PROBES=1` remained set. No new Open crash report appeared.

| Import row | Result | Load | Evidence |
|---|---|---|---|
| I-negative-mock-key | PASS | 7.91 / 8.97 / 10.54 | Without the allow switch: error 10; every store count zero in both Profiles; capability false and consent/probe/read counters zero. |
| I-1 | PASS | 7.91 / 8.97 / 10.54 | Each Profile: 3 logins, 1 blocked site, 1 address, 1 card, 4 cookies; all failed counters zero. Work had no page before import. |
| I-2 | PASS | 7.76 / 8.92 / 10.51 | Explicit real-dropdown fill matches in both Profiles; no foreign Profile entry. |
| I-3 | PASS | 7.76 / 8.92 / 10.51 | Repeat adds zero records; existing counts and store totals stay unchanged. |
| I-4 | PASS | 7.53 / 8.86 / 10.48 | A newer Open password survives re-import and fills through the real dropdown. |
| I-5 | DEFERRED | 7.89 / 8.90 / 10.47 | M1-only by rule; not run while M1 is on HOLD. |
| I-6 | DEFERRED | 7.89 / 8.90 / 10.47 | M1-only by rule; not run while M1 is on HOLD. |
| I-7 | PASS | 7.53 / 8.86 / 10.48 | After relaunch, each Profile receives 3 required unpartitioned cookies and zero foreign cookies. |
| I-8-no-switch | PASS | 7.89 / 8.90 / 10.47 | Capability stays false; allow button unavailable; skip/cancel and direct adapter create zero consent/probe/read calls. |
| I-8-allow-switch | PASS | 8.86 / 9.08 / 10.53 | Same capability and zero-call guards with the fixture allow switch. |
| I-9-completed | PASS | 7.97 / 8.93 / 10.49 | Real Settings delete: Profile/engine/cache folders absent before quit and after relaunch; Default counts and ledger unchanged; retired request refused. |
| I-9-in-progress | PASS | 7.89 / 8.90 / 10.47 | Same deletion checks while Work is paused after durable logins; task/sink retired and engine context removed. |

First-run F12 proves instrumentation only: its Debug median was 752 ms against the 250 ms Release budget, at load 18.81 / 19.08 / 15.14. This is a loaded Debug upper bound, not idle Release acceptance. The existing Release timing follow-up remains open.

Two earlier attempts are retained separately. The first passed the negative proof and I-1–I-3, then stopped in I-4 because the harness omitted required `PasswordUiEntry` fields. The second passed I-4 and I-7, then stopped in I-9 because it had not answered the real Change Profile warning. G6 corrected those harness requests, saved/reset/restored the shared confirmation preference, and checked the separate Chromium cache path. Both failed attempts cleaned up all owned processes and windows; the early I-9 failure also proves cleanup with an outstanding confirmation. [Source evidence](../re/import-secrets-fixture.md).

| Earlier attempt | Result | Load at screen acquisition | Load after |
|---|---|---|---|
| `G6-secrets-import` | FAIL; I-4 request omitted required WebUI entry fields | 9.72 / 11.30 / 12.39 | 9.48 / 11.17 / 12.32 |
| `G6-secrets-import-schema-fixed` | FAIL; I-9 setup left the Change Profile confirmation unanswered | 14.53 / 10.87 / 11.67 | 13.62 / 11.02 / 11.69 |

Agents used generated fixtures and the mock Keychain only. No real import path, real Keychain read, real Arc secret read, unit test or computer-use tool ran. Reports contain no secret field values. On mock-key builds `canImportPasswordsAndCookies` stays false even with the synthetic allow switch. I-5/I-6 and feature crash recovery remain separate M1-only gates. After U-1/U-2, the signed-build import of the user's real Arc secrets requires the user present and explicit consent; synthetic acceptance does not close it. No engine root was edited.
