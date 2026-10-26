# Full CLI verification

Run from any directory on macOS with Swift and Python 3 installed:

```sh
tools/verify-all.sh
tools/verify-all.sh --quick
tools/verify-all.sh --only route,favicons
tools/verify-all.sh --with-arc-data --keep-logs
```

The runner uses `/bin/bash` 3.2. It builds `Packages/OpenKit` exactly once with
`nice -n 10 swift build -c release -j "${VERIFY_JOBS:-6}"`. The build runs in its
own process session. A compiler error, any output line containing `warning:`,
or a nonzero build exit stops the run. The build log records warning/error line
counts. Checks use the resulting release executables; they never call `swift run`.

`--quick` selects commands-demo, suggest-check, and commands-dump after the build.
`--only NAME[,NAME]` selects checks from the table below, preserving table order.
The build always runs; `--only build` runs just the build. Combined with `--quick`,
`--only` must select from the quick set. Unknown names and invalid flags exit 2.
`VERIFY_JOBS` sets build concurrency. `VERIFY_LOG_DIR` can name a **new** log
directory; an existing directory is refused to protect earlier evidence.

Every check runs in a fresh `mktemp -d` directory, with its own working directory
and `TMPDIR`. Synthetic snapshot prerequisites come from commands-demo. A check
selected alone creates that prerequisite through the real CLI. Roundtrip copies
the demo's output before saving it. It does not change the original fixture.

Each command must exit as expected **and** print its required success evidence.
The runner records PASS, FAIL, or SKIP and elapsed whole seconds. A failed check
does not stop later checks, except for a failed build. Exit 0 means there were no
FAIL rows. An unavailable command or executable is SKIP, detected from openkit's
usage tokens or `.build/release/<executable>`. A command that exists but fails,
prints incomplete results, or misses a dependency is FAIL. Missing node or Chrome
also makes the optional Boosts check SKIP. Checks excluded by flags have no row.

| Name | What PASS proves | Typical duration after build |
|---|---|---|
| `commands-demo` | Real BrowserModel commands, undo/redo, placement refusal, archive/restore, and persistence report all checks passed and zero failed. See [model.md](model.md). | <1 s |
| `roundtrip` | A commands-demo snapshot loads, saves, and reloads with `roundtrip OK`. | <1 s |
| `suggest-check` | The existing suggestion CLI reports N/N passed, with N > 0, including local HTTP remote-provider paths and its main-thread CPU budget. See [suggest.md](suggest.md). | 5–20 s |
| `commands-dump` | The real headless NSMenu and keyboard registry match the reference table (`missing=0 extra=0 different=0`). Default and override bindings have no unexpected conflicts. See [commands.md](commands.md). | <1 s |
| `route` | Runs an existing `tools/route-check.sh`, `tools/verify-routing.sh`, `tools/verify-route.sh`, release `route-check`, or `openkit route-check` runner when present. Otherwise exercises [routing.md](routing.md) A1–A10 through `openkit route`: host boundaries, containment, first-match order, source normalization, toggle, rejected scheme, stale target, and JSON/text agreement. Every accepted result has an explicit expected destination. | <2 s |
| `favicons` | A tiny generated site served by Python http.server on loopback fetches through the release debug flags. Concurrent fetches succeed, a second process uses the cache, 32/64-pixel PNGs read back, and a page without an icon reports missing and absent readback. All requested page/icon URLs are local. See [favicons.md](favicons.md). | <2 s |
| `sleep-demo` | The existing real model/controller/store CLI reports N checks passed and zero failed. Its engine boundary and clock remain the CLI's simulation. Expected deliberate storage errors are allowed. See [sleep.md](sleep.md). | 1–5 s |
| `adblock-perf` | Both current budgets pass: 1,000 lookups p95 <1 ms and profile open with integrity scan p95 <10 ms. Ten groups yield exactly 5,000 matches in 10,000 lookups. Official default-list downloads may be needed. See [adblock-lists.md](adblock-lists.md). | 5–30 s; network dependent |
| `adblock-catalog` | Real CLI output contains all 46 catalog IDs, category counts 3/2/5/35/1, and only EasyList/EasyPrivacy enabled by default. | <1 s |
| `profiles` | When `openkit profiles` exists, exercises the planned P-1–P-8 and P-10 flow: create, duplicate refusal, assign Space, both delete refusals with unchanged snapshot bytes, reassignment, temporary-profile deletion with retained directory, and roundtrip. Contract: [profiles plan §9.1](plans/profiles.md#91-openkit-profiles--cli-new-file-openkitprofilescliswift). | <2 s |
| `sidebar-render` | When present, `sidebar-render check` reports N/N passed. | 1–5 s |
| `commandbar-render` | When present, `commandbar-render check` reports N/N passed. | 1–5 s |
| `boosts` | Headless system Chrome loads the actual Boosts harness and production scripts. A7 asserts banner highlight geometry/color, selector commit, hidden banner, and active picker. A11 asserts the precise pick, two aligned related previews, three-match replacement, and hidden posts. Saves both PNGs and rejects runtime errors. See [boosts.md](boosts.md). | 5–20 s; npm install dependent |
| `import-arc` | Opt-in only. Read-only copies of Arc's top-level JSON files pass sidebar/archive accounting, `archive-list --limit 0`, and roundtrip. Also inspects default-profile output when profiles exists (P-9). | <2 s |

An initial release build usually takes 20–90 seconds. An incremental build usually
takes 1–3 seconds. Host load, cold compiler caches, npm, and list downloads can
increase these estimates. The final table and each log give actual times/results.
Performance budgets are never retried or relaxed by the runner.

## Logs and privacy

The default directory is `$TMPDIR/open-verify-<local timestamp>.<unique suffix>/`
(`/tmp` when TMPDIR is unset). The runner prints its absolute path at the end.
It contains a log per check, `openkit-usage.log`, `results.tsv`, `summary.txt`,
and available favicon/Boosts PNGs. Failed checks keep their output there.
`--keep-logs` additionally retains synthetic scratch files under `artifacts/`,
including the temporary npm installation. Ordinary runs remove scratch files.
Logs always remain, so the final path works with or without `--keep-logs`.

`--with-arc-data` is the only path that reads
`~/Library/Application Support/Arc/*.json`. The importer reads private copies.
Only allowlisted count/check lines reach the persistent log. Full importer output,
hosts, titles, source JSON copies, snapshots, and SQLite files are discarded when
the check ends, including on failure and with `--keep-logs`. No keychain, History,
Cookies, or browser profile databases are opened. Arc is never launched.

The Boosts check follows the temporary `puppeteer-core` approach used by
`.re/qa/shot.mjs`: it copies this repo's portable driver into its scratch directory,
runs `npm i puppeteer-core` there, and launches system Google Chrome with a fresh
headless profile. There is no repo npm dependency or lockfile. Both local servers
bind a dynamically assigned loopback port and stop in a `finally` block. Chrome
closes in the driver's `finally` block. The harness runs in the page world; this
check does not prove native session authority or the future isolated-world engine
adapter. The runner does not launch Open, drive the desktop, build Chromium, or
claim app/engine acceptance. [scripting.md](scripting.md) describes separate
App/AppleScript gates; no scripting CLI exists in this checkout.

## Verify the failure path

Use a disposable copy of the checkout and edit its copy of
`tools/verification/check.py` to point `cli` at a nonexistent absolute path. Run
`tools/verify-all.sh --only suggest-check`. The real package build must still
pass, then suggest-check must report FAIL with exit 1. Keep that edit outside the
working branch. A missing advertised command is SKIP; a missing executable at
execution time or a command with a wrong result is FAIL.
