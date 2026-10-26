# Link routing core (Phase A)

Implements Steps 1–4 of [routing-little-open.md](plans/routing-little-open.md), including its Lead decisions appendix. Phase B intake, default-browser registration, windows, engine adapters, hotkeys, and sweepers remain out of scope.

## API

`OpenRouting` depends only on `OpenModel`. It imports no AppKit, stores, importer, suggestions, or commands code.

- `RoutingSource` carries a trimmed, lowercase bundle id, optional PID, and display name. An empty bundle id is unknown. Source identity is normalized again at evaluator entry.
- `RoutingRequest` carries the URL, source, and receipt time. `parseURL(_:)` is the shared CLI/Settings input parser: a bare dotted host or `host:digits[/path]` authority gains `https://` (including `localhost:3000/x`); other explicit schemes reach the evaluator.
- `RoutingSnapshot` is a value copy of Spaces, frontmost-first windows, ordered rules, default destination, and the external-links toggle. Callers copy live model values on the main actor. The App must use its managed windows in actual front-to-back order. The CLI uses standard windows first in stored order, which the report states. `--most-recent` moves a matching standard window first, or supplies a synthetic one.
- `RoutingEvaluator.evaluate(_:in:)` never throws. It rejects non-HTTP(S) schemes, checks source before URL, and selects the first matching rule. A matching rule with a deleted target Space is traced and skipped. A later valid rule can win. If no rule resolves, it resolves the default. A missing default Space that requires most-recent fallback sets `fallbackMissingSpace`. Skipped stale rules keep their trace without replacing the normal rule/default/toggle `via`; no usable Space gives `noSpaces`, unless Little Open can open with a nil profile hint.
- `ResolvedDestination` is a concrete Space/profile pair or Little Open with an optional profile hint. The hint comes from the most recent valid standard window's Space, falling back to the first Space. Duplicate Space ids use their first occurrence.
- `RoutingDecision` carries the request, normalized host, considered traces, reason (`via`), concrete target (`resolved`), and the injected receipt time as `evaluatedAt`. Human rule numbers are one-based; JSON indices are zero-based.
- `RoutingDecisionFormatter.oneLine(_:spaceTitles:)` and `.report(_:spaces:)` serve the log, CLI, and Settings. Unknown Space names use an eight-character UUID. Profile hints use an eight-character profile UUID because the supplied snapshot has no profile names.
- `RoutingDecisionLog` stores the last 200 complete decisions, oldest first, behind an `NSLock`. It is memory-only and safe across threads. Clicked URLs and source identities have history-entry sensitivity. It stores no fetched page content, cookies, or page titles.

Hosts use a shared canonical form: percent-decoded UTF-8, Unicode NFC, and lowercase. `xn--` labels decode to Unicode through a local decoder for [RFC 3492 sections 6.1–6.2](https://www.rfc-editor.org/rfc/rfc3492#section-6); invalid input leaves the label unchanged. The same form applies to host-equality/containment patterns and URL-prefix authorities. Thus Unicode, percent-encoded, and Punycode spellings compare equally.

Host equality strips authority ports and trailing dots and removes one leading `www.` from each side. It does not match subdomains. Host containment is a literal substring test: `google.com` also matches `notgoogle.com`. URL hosts and ports come from separate `URLComponents` fields. IPv6 hosts lose their brackets but retain every address component in reports; IPv6 requests never match `hostEquals` or `hostContains` rules.

URL prefixes are literal and case-sensitive in path/query and keep `www.`. Canonical request URLs and explicit-scheme patterns drop fragments and remove default ports. Scheme-less prefixes match HTTP and HTTPS and keep the supplied remainder verbatim, including an empty path or fragment. Their authority port is removed only when it is the request scheme's default (`:80` for HTTP, `:443` for HTTPS); a non-default port such as `:8443` stays significant. No network or file access occurs during evaluation.

A rule that explicitly selects Little Open still wins when the external-links toggle is off. Only a Little Open **default** is suppressed by that toggle.

## Settings data

`LinksSettingsModel` is `@MainActor @Observable` and contains no views or persistence. The App binds drafts, calls `issues()`, then copies `currentRouting()` into the browser model and schedules its normal snapshot save.

Empty patterns, literal spaces, malformed explicit URL prefixes, and missing Space targets are errors. Invalid drafts remain visible but are excluded from evaluation/save output. Duplicate rules and host-substring semantics are warnings. A missing default Space produces an issue under the stable `defaultDestinationIssueID` and degrades to most recent Space. `moveRule(from:to:)` uses the final list index; `to == count` means the end.

`runTest()` builds one synthetic standard window, evaluates with the same logger-less evaluator, and stores `testDecision`. Invalid input clears the prior result and makes `testInputIsValid` false. It never opens a URL or changes rules. Recreate the settings model when the App adds Spaces or changes their profile assignments, so its input snapshot retains the correct profile mapping. The App hydrates `littleOpenAutoArchiveAfter` from the current profile; its initial value is six hours.

Persistence ownership remains:

| Value | Owner / default |
|---|---|
| Rules, optional source condition, default destination | Existing schema-1 browser snapshot |
| External links in Little Open | `open.links.externalInLittleOpen`, fallback `true` |
| Little Open hotkey | `open.links.littleOpenHotkeyEnabled`, fallback `true` |
| Option-Command-click | `open.links.optionCommandClickLittleOpen`, fallback `true` |
| Little Open auto-archive | Current profile's `littleOpenAutoArchiveAfter`, fresh default six hours |

The model reads the two shortcut toggles and uses the snapshot's external-links toggle. It does not write UserDefaults. The CLI reads the same external-links key with the same fallback. Phase B owns defaults registration and App save wiring.

## Snapshot compatibility

This is a **ONE-WAY migration** from `littleArc` to `littleOpen`. New snapshots do not load in builds before this PR. This is acceptable because Open has no released users. `schemaVersion` stays **1**.

The four live/DTO routing destination enums accept legacy `littleArc` and new `littleOpen`, and encode only the new spelling. Unknown keys and multiple destination keys throw. String-passthrough coding keys keep unknown keys visible to this validation.

The window mapper accepts legacy `littleArc` style strings. Both profile-settings representations read the new auto-archive key first, then the legacy key, then six hours. Explicit stored thresholds survive migration. Today-tab auto-archive remains twelve hours. A missing `sourceBundleID` decodes as nil. The mapper writes no empty source id and normalizes nonempty source ids. The importer does not invent source conditions.

Fresh `BrowserModel` instances and missing-import routing defaults select Little Open, per the lead's Q3 decision. Existing explicit defaults remain unchanged.

## CLI

```text
openkit route DIR <url> [--source BUNDLE_ID] [--most-recent SPACE]
                      [--external-little-open on|off] [--json]
                      [--expect-destination space:<uuid>|littleOpen|mostRecentSpace]
```

`DIR` holds `State/browser.json`. Space overrides accept a UUID or exact title. `--json` emits a sorted-key Codable decision. `--expect-destination` checks the returned target after printing the report; most-recent expectations use the same evaluator to resolve the expected Space.

Exit 0 means a decision was printed and any expectation matched. Rejected schemes and empty-Space decisions also exit 0 without an expectation. Exit 1 means a missing/bad snapshot or a target mismatch. Exit 2 means invalid arguments, invalid URL input, or an unknown Space override. The command never saves or changes its snapshot.

## Verification — 2026-10-25

All package builds ran in `Packages/OpenKit`, in separate process sessions, with exactly:

```sh
nice -n 10 swift build -c release -j 6
```

Baseline, Steps 1, 2, 3, and 4, and the final prefix refinement each built with zero warnings and zero errors. CLI checks used the resulting `.build/release/openkit` and `.build/release/commands-dump` executables; no implicit debug builds ran.

Before source changes, the main-source build at `47d83fed82383f9f120797b109ef45a5f23af73a` imported a temporary copy of the user's top-level JSON files with `openkit import-arc --arc-dir COPY --out OLD`. The resulting schema-1 snapshot contained a legacy Little Open destination and a rule without the new optional source field. An immutable original was kept; load, roundtrip, and edited fixtures used copies. The original hash remained unchanged. All copied user data and raw CLI output stayed outside the repo. Fixture Space names in routing reports were replaced with synthetic names.

For A1–A10, each routing case used a copy of that import with only its routing state edited. `Space X` below is an existing imported Space. Accepted target checks used `--expect-destination` with the appropriate Space UUID, `littleOpen`, or `mostRecentSpace`. A8 checks rejection text and exit 0 because the planned expectation vocabulary has no rejected token.

| Check | Invocation / fixture | Observed result | Status |
|---|---|---|---|
| A1 | `route DIR https://example.com/`; nonmatching rule, Little Open default, toggle on | Host mismatch; default → Little Open; exit 0 | PASS |
| A2 | `hostEquals(example.com)` → Space X; `https://www.example.com/` | Rule #1 → Space X; exit 0 | PASS |
| A3 | Same rule; `https://sub.example.com/` | Host mismatch; default → Little Open; exit 0 | PASS |
| A4 | `hostContains(google.com)` → Space X; `https://mail.google.com/` | Rule #1 → Space X; exit 0 | PASS |
| A5 | Matching rules: Little Open first, Space X second; toggle off | Rule #1 → Little Open; no second trace; exit 0 | PASS |
| A6 | Source-conditioned rule; no source, then matching mixed-case/whitespace source | Unknown source falls through; normalized source matches Space X; both exit 0 | PASS |
| A7 | Little Open default; external-links override off, then on | Off → most-recent Space; on → Little Open; both exit 0 | PASS |
| A8 | `route DIR ftp://example.com/` | `decision: rejected`; no target; exit 0 | PASS |
| A9 | Deleted Space target first, valid matching rule second | `target Space missing — skipped`; rule #2 → Space X; exit 0 | PASS |
| A10 | A1 inputs with `--json` | Valid JSON; `via.defaultDestination` and `resolved.littleOpen` agree with text; exit 0 | PASS |
| A11 | `roundtrip DIR`, then `commands-demo DIR` on a copy of the pre-change import | `roundtrip OK`; 66 checks passed, 0 failed; both exit 0 | PASS |
| A12 | Host-equality/containment rules for bracketed/unbracketed IPv6; URLs `https://[2001:db8::1]/docs` and `https://[2001:db8::99]/docs`, with/without `:8443`; literal IPv6 prefix checks | Both full addresses stay distinct in `normalizedHost`; neither host rule matches; prefix distinguishes addresses and ports; 35 CLI decisions, exit 0 | PASS |
| A13 | Both `hostEquals(münchen.de)` and `hostEquals(xn--mnchen-3ya.de)` against both URL spellings at `/x`; `urlPrefix(xn--mnchen-3ya.de/docs)` against `https://münchen.de/docs/a` | Every required match selects Space X. Host containment, percent-encoded/NFD/uppercase inputs, explicit prefixes, other scripts, malformed Punycode patterns, and negative cases also pass; 48 CLI decisions, exit 0 | PASS |
| A14 | Load a legacy `littleArc` fixture with `route`, run `roundtrip`, then route the saved snapshot; review compatibility text in this file and `model.md` | Old input loads; new output uses only `littleOpen`, retains schema 1, and reloads; 3 CLI invocations, exit 0. Both docs state ONE-WAY migration and pre-PR build incompatibility; Open has no released users | PASS |
| A15 | Scheme-less prefixes `example.com:443/docs`, `example.com:80/docs`, and `example.com:8443/docs`; matching/mismatching HTTP(S) URLs | HTTPS `:443` and HTTP `:80` match omitted defaults; `:8443` and opposite-scheme ports stay significant; combined IDN/default-port case also passes; 11 CLI decisions, exit 0 | PASS |
| A16 | `route DIR example.com:8080/docs` and `route DIR localhost:3000/x`, plus each authority ending after its port | Request URLs gain `https://`, keep their ports, and match their host rules; 4 CLI decisions, exit 0 | PASS |
| A17 | Skipped stale rule with valid Space, most-recent, Little Open on/off, or missing-Space defaults; zero-Space case | Normal default/toggle `via` survives skipped rules. Only an actually missing default target sets `fallbackMissingSpace`, naming that target rather than the skipped rule's id. Empty state uses `noSpaces`; 6 CLI decisions, exit 0 | PASS |

| Existing CLI / required probe | Result |
|---|---|
| Pre-change `import-arc` on the temporary JSON copy | PASS; accounted checks OK; exit 0 |
| New `import-arc` on the same copy | PASS; accounted checks OK; same Space/rule counts; no invented source conditions |
| `dump` and `roundtrip` on the pre-change snapshot copy | PASS; `roundtrip OK`; new save contains no legacy keys |
| `dump` and `roundtrip` on the new import | PASS; `roundtrip OK` |
| `commands-demo` on the imported copy and a fresh directory | PASS; 66/66 each |
| `suggest-check` | PASS; 31/31, including its real local HTTP server paths and timing budget |
| `commands-dump` | PASS; exit 0; no unexpected conflicts or menu differences; two intentional built-menu renames |
| `/tmp` Settings caller probe loaded from the imported snapshot | PASS; matching and nonmatching URL reports, invalid input clears the result, edits/reorder/delete, source normalization, invalid-draft exclusion, warning-only save, deleted rule/default targets, fresh defaults |

The Settings probe used the Swift interpreter against already-built release objects linked into a temporary library. No probe or test target was added to the repo.

PR #20 review-fix verification reran A1–A11 and added A12–A17 through the prebuilt release CLI. Both review-fix builds used the exact build command above, in separate process sessions, and completed with zero warnings and zero errors. Temporary fixtures, drivers, and raw receipts are under `/tmp/open-routing-pr20-review-y3qys9wz`; no test target was added. The immutable pre-change snapshot retained SHA-256 `ef91d400f25c7aa8500d800610b4ff2783891d7862b779af90d164d3721ad4cb`.

The review-fix regression pass also ran `import-arc` read-only against the live Arc data directory, `roundtrip` on that new import, `commands-demo` on a copy of the import and on a fresh directory (66/66 each), `suggest-check` (31/31), and `commands-dump` (exit 0). All passed. No pre-PR build was run against the migrated output; A14 verifies forward load/save/reload and the required compatibility documentation.

Additional real CLI checks passed: missing snapshot (1), invalid arguments/URL/Space override (2), expectation mismatch after printing (1), bare-host scheme convenience, source mismatch, title and UUID most-recent overrides, zero Spaces with Little Open on/off and a Space default, stale-rule fallback, literal prefix boundaries, scheme-less prefixes (including a bare host and verbatim fragment), path/query case and escaping, fragments, default/nondefault ports, empty patterns, and unknown or mixed destination keys. Compatibility roundtrips also passed for legacy rule destinations/window styles, explicit old thresholds, new-key precedence, missing-key six-hour fallback, and normalized source persistence.

## Plan differences and clarifications

- Main already renamed the two command ids to `new-little-open-window` and `little-open-global` before this task. Those existing ids remain unchanged, rather than restoring the older ids listed in the plan. The third title now uses the plan's exact `Open Little Open or Peek in…` wording. The comparison allowlist is bound to exactly the three current ids; the evidence JSON is unchanged.
- The plan's decision fields omit information required by its exact shared report signature. Each trace therefore carries its rule value; decisions carry standard-window count and optional most-recent override id, and snapshots carry that optional report context. Evaluation semantics and the specified formatter call signatures are unchanged. The profile hint prints its UUID because profile names are not supplied by the planned API.
- `RuleDraft.makeRule()` has no Space-list parameter. It validates errors available from the draft itself. `LinksSettingsModel.issues()` and `currentRouting()` additionally validate against the current Space list, so deleted targets remain visible and cannot enter the evaluator/save output.
- The single `BrowserModel` initializer default and importer missing-default fallback also change to Little Open to honor the lead's Q3 override. Explicit saved destinations still win.
- The review fixes supersede the plan's Unicode-pattern limitation (§5.1/Q5) and stale-rule `via` override (§5.5 R7). Host spellings now share Unicode NFC, and only an actually missing default Space causes `fallbackMissingSpace`.
- The plan's broad `Little Arc` grep also finds its required legacy menu-title allowlist and existing search aliases. These are intentional compatibility/evidence/alias strings allowed by the repository rules. Product titles and routing output use Little Open.

No unit tests, desktop automation, Arc launch, Chromium build/sync, or Phase B implementation ran.
