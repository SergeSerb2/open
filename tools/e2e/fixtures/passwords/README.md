# Passwords fixtures

Run `python3 -I tools/e2e/fixtures/passwords/server.py --port 0`. The first
stdout line is the chosen port. The server binds IPv4 loopback only. It uses
only the Python standard library. It does not log requests or form values.
POST bodies are discarded, with an 8 KiB limit. Static routes are allowlisted.

`engine_e2e.passwords_fixture_server()` is a context manager. It starts and
stops one server. Its dictionary contains `login`, `change`, `signup`,
`iframe`, `address`, `card`, `webauthn`, `basic`, `set_cookies`, `echo_cookies`,
`local_login`, `port`, and `engine_switches`. Pass the last value as the App
factory's `extra_args`. CEF reads the App's argv through `CefMainArgs` in
`OEEngine.mm`, alongside configuration `additionalSwitches`; each resolver
rule must remain one argument. The switches also bypass system proxies so
fixture traffic stays on loopback.

Login, change, signup and address use `login.example.com`; the iframe parent
uses `other.example.com`. Card, WebAuthn and Credential Management API checks
use `localhost:<port>` for a secure context. The resolver rule sends both
example hosts to the same server. The fixture HTML is original, synthetic
content. Field values are stored in `data-fixture` attributes for the harness;
the form fields start empty. Do not log their values or capture filled forms.
Cookie echo responses contain names only. `/basic` always returns 401 and
never reads or reflects Authorization. WebAuthn buttons publish state/error
names only and abort outstanding requests after five seconds.

On `redirect.example.com`, the same `/login` POST returns 302 `/welcome`,
then the welcome document immediately uses JavaScript to load `/dashboard`.
P-24 checks the save sheet on that completed dashboard and answers Save.
Run acceptance with `--stop-on-app-death` to stop all later flows if Open dies
or writes a new crash report. PW-KC1 is a user hand check by lead decision.

`--only passwords-probe --style chrome` writes the Step 0 observations to
`docs/engine-spike/results-passwords-probe.json`. A feature can be absent while
its crash-safety check passes. Missing saved data makes refill and re-auth
observations inconclusive. Process death, lost automation or a new Open crash
report stops the suite without retry. The separate acceptance suite
`--only passwords --style chrome` reuses this server and its helper; see
`docs/automation.md` for its real-sheet, fill, preference and cookie rows.

For the real-dialog cleanup proof, set
`OPEN_E2E_PASSWORDS_PROBE_ABORT_DIALOG=1` on the same locked command. It exits
with failure while WebAuthn is open. The App's normal `finally` cleanup must
report no remaining owned process or window. Preserve that expected-failure
receipt separately, then run the normal probe for the committed observations.

After a crash, stop all on-screen work. Only after the lead says "M5 clear", `--passwords-probe-rows PR-8,PR-9` can run remaining rows without
replaying the crashed row. Unrequested rows are `NOT_REQUESTED`, not passes.
Each selected run still has its own engine/source fingerprint and timestamps.

PR-7 makes no Basic-auth navigation until the running engine reports the 08xx
`supportsSecretsImport` capability through `credentials`. An unpatched App
without that command also leaves the row BLOCKED. Distribution hashes remain
in the evidence, without a hard-coded allowlist that breaks on a rebuild.
The recorded crash remains evidence; `BLOCKED` is not a pass. The M5 screen
hold still requires an explicit "M5 clear" message before any App launch.

Selected runs write a separate file, for example
`results-passwords-probe-PR-8-PR-9.json`. They preserve the primary crash receipt
in `results-passwords-probe.json`. Merge completed observations into the primary
report with their run/source provenance after the authorized remaining-row run.
