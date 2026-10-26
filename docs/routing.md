# Link routing core (Phase A)

Implements Steps 1–4 of [routing-little-open.md](plans/routing-little-open.md), including its Lead decisions appendix. Phase B intake, default-browser registration, windows, engine adapters, hotkeys, and sweepers remain out of scope.

## API

`OpenRouting` depends only on `OpenModel`. It imports no AppKit, stores, importer, suggestions, or commands code.

- `RoutingSource` carries a trimmed, lowercase bundle id, optional PID, and display name. An empty bundle id is unknown. Source identity is normalized again at evaluator entry.
- `RoutingRequest` carries the URL, source, and receipt time. `parseURL(_:)` is the shared CLI/Settings input parser: a bare dotted host gains `https://`; explicit schemes reach the evaluator.
- `RoutingSnapshot` is a value copy of Spaces, frontmost-first windows, ordered rules, default destination, and the external-links toggle. Callers copy live model values on the main actor. The App must use its managed windows in actual front-to-back order. The CLI uses standard windows first in stored order, which the report states. `--most-recent` moves a matching standard window first, or supplies a synthetic one.
- `RoutingEvaluator.evaluate(_:in:)` never throws. It rejects non-HTTP(S) schemes, checks source before URL, and selects the first matching rule. A matching rule with a deleted target Space is traced and skipped. A later valid rule can win. If no rule resolves, it resolves the default. Missing targets are explained by `fallbackMissingSpace`; no usable Space gives `noSpaces`, unless Little Open can open with a nil profile hint.
- `ResolvedDestination` is a concrete Space/profile pair or Little Open with an optional profile hint. The hint comes from the most recent valid standard window's Space, falling back to the first Space. Duplicate Space ids use their first occurrence.
- `RoutingDecision` carries the request, normalized host, considered traces, reason (`via`), concrete target (`resolved`), and the injected receipt time as `evaluatedAt`. Human rule numbers are one-based; JSON indices are zero-based.
- `RoutingDecisionFormatter.oneLine(_:spaceTitles:)` and `.report(_:spaces:)` serve the log, CLI, and Settings. Unknown Space names use an eight-character UUID. Profile hints use an eight-character profile UUID because the supplied snapshot has no profile names.
- `RoutingDecisionLog` stores the last 200 complete decisions, oldest first, behind an `NSLock`. It is memory-only and safe across threads. Clicked URLs and source identities have history-entry sensitivity. It stores no fetched page content, cookies, or page titles.

Host equality lowercases, strips ports and trailing dots, and removes one leading `www.` from each side. It does not match subdomains. Host containment is a literal substring test: `google.com` also matches `notgoogle.com`. URL prefixes are literal and case-sensitive in path/query and keep `www.`. Canonical request URLs and explicit-scheme patterns drop fragments and remove default ports. Scheme-less prefixes match HTTP and HTTPS and keep the supplied remainder verbatim, including an empty path or fragment. Unicode host patterns are not converted to punycode; callers should use the URL's ASCII host spelling. No network or file access occurs during evaluation.

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

Additional real CLI checks passed: missing snapshot (1), invalid arguments/URL/Space override (2), expectation mismatch after printing (1), bare-host scheme convenience, source mismatch, title and UUID most-recent overrides, zero Spaces with Little Open on/off and a Space default, stale-rule fallback, literal prefix boundaries, scheme-less prefixes (including a bare host and verbatim fragment), path/query case and escaping, fragments, default/nondefault ports, empty patterns, and unknown or mixed destination keys. Compatibility roundtrips also passed for legacy rule destinations/window styles, explicit old thresholds, new-key precedence, missing-key six-hour fallback, and normalized source persistence.

## Plan differences and clarifications

- Main already renamed the two command ids to `new-little-open-window` and `little-open-global` before this task. Those existing ids remain unchanged, rather than restoring the older ids listed in the plan. The third title now uses the plan's exact `Open Little Open or Peek in…` wording. The comparison allowlist is bound to exactly the three current ids; the evidence JSON is unchanged.
- The plan's decision fields omit information required by its exact shared report signature. Each trace therefore carries its rule value; decisions carry standard-window count and optional most-recent override id, and snapshots carry that optional report context. Evaluation semantics and the specified formatter call signatures are unchanged. The profile hint prints its UUID because profile names are not supplied by the planned API.
- `RuleDraft.makeRule()` has no Space-list parameter. It validates errors available from the draft itself. `LinksSettingsModel.issues()` and `currentRouting()` additionally validate against the current Space list, so deleted targets remain visible and cannot enter the evaluator/save output.
- The single `BrowserModel` initializer default and importer missing-default fallback also change to Little Open to honor the lead's Q3 override. Explicit saved destinations still win.
- The plan's broad `Little Arc` grep also finds its required legacy menu-title allowlist and existing search aliases. These are intentional compatibility/evidence/alias strings allowed by the repository rules. Product titles and routing output use Little Open.

No unit tests, desktop automation, Arc launch, Chromium build/sync, or Phase B implementation ran.
