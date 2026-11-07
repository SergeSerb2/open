# Profiles shell — Section 10

Settings deletes a Profile after an exact typed-name confirmation. Delete
Unused Profiles lists the captured unused set and requires `DELETE`.
Default and assigned Profiles cannot be deleted. Model removal disables Undo
registration and clears older Undo actions. The App closes the Profile's
Little Open and private windows, awaits native context deletion, removes its
Open-owned, engine and cache folders, and saves the snapshot synchronously.

`ProfileTeardown` records each non-default context loaded this launch. Its
`unload` calls `OEEngine.deleteContext`, which waits for actual Chromium
Profile destruction and committed Local State cleanup. A Profile with data
from a prior launch is loaded for this native metadata cleanup too. Successful
deletion removes loaded engine/cache directories in the current session.

A synced `Profiles/.pending-wipe.json` journal covers interrupted or failed
cleanup. The journal is bounded at 64 KiB, 1024 unique names, and 255 UTF-8
bytes per name. It rejects Default, path components, malformed JSON and
oversized input. Atomic writes sync the file and parent before cleanup.
Recovery runs with the data root locked, before `OEEngine.start`, and removes
remaining folders plus `profile.info_cache`, `profile.last_used` and
`profile.last_active_profiles` references. A recovery failure stops startup
before the engine can use partially cleaned data. Successful in-session
native deletion needs no App-side Local State JSON edit.

App bootstrap repairs missing Profile references before store preparation or
host creation. Every `installModel` path enforces the same rule. Repairs are
saved at once. The first standard window shows one informational sheet that
names the repaired Spaces. A later launch reads the repaired snapshot and
does not repeat the notice.

Settings Profile rows open the shared emoji/SF Symbol picker. Space headers
and Space Manager headers show the assigned Profile icon when more than one
Profile exists. Their menu uses the existing Set Profile path. Little Open
keeps its title-bar geometry and uses the Profile's icon. Settings and
extension management create a fresh Little Open page on the requested
Profile when it has no Space.

Private windows never show the Space-header Profile indicator. Repair and
Settings deletion use the normal `app.model`; private window models are
separate. Repair notices attach only to standard windows, and deletion
retires hosts only in persistent factories.

## Profile page destinations

The Settings actions use the Chromium 156 routes below. The real-App suite
checks both the committed native URL and `location.href`, plus the actual
engine context, for every page in a normal tab and in Little Open.

| Profile page | URL |
|---|---|
| Privacy and Security | `chrome://settings/privacy` |
| Passwords | `chrome://password-manager/passwords` |
| Credit Cards | `chrome://settings/payments` |
| Notifications | `chrome://settings/content/notifications` |

Chromium 156 redirects the older `chrome://settings/passwords` route to the
Settings root. The Passwords row must reject that redirect. Source evidence:
Chromium `chrome/browser/resources/password_manager/router.ts` (`Page.PASSWORDS`)
and `chrome/browser/resources/settings/route.ts` (`PRIVACY`, `PAYMENTS`,
`SITE_SETTINGS_NOTIFICATIONS`). Runtime evidence takes priority over those
source observations.

## Evidence limits

- Typed-name deletion, the unused-Profile list, and the indicator's existence
  are facts from `strings -a /Applications/Arc.app/Contents/MacOS/Arc`:
  `DeleteProfileDialog`, `DeleteUnusedProfilesDialog`, `ProfileIndicatorView`,
  `Edit Space profile`, and the typed-name prompt. The saved audit is
  `.re/s10/arc-profile-dialog-strings.txt` (lines 32–46); see also
  [features-core.md](re/features-core.md#51-lifecycle).
- **Guess S10-I1:** the 14 pt glyph, 20 pt hit area, 2 pt gap, 55% title tint,
  placement and more-than-one-Profile visibility rule. Arc's exact geometry
  has not been captured.
- User-editable Profile icons and the destination for Profile pages without
  a Space are guesses. The shell follows the Section 10 lead's design.
- The native engine rows now prove Chromium Profile destruction. They do not
  claim Arc pixel parity for the new multi-Profile indicator. The existing
  single-Profile sidebar baselines stay authoritative.

## Acceptance

The real-App `profiles` suite includes missing-reference repair and saved
relaunch, exact typed deletion, immediate Open-owned/engine/cache removal,
committed native Local State cleanup, never-loaded removal, no Undo
restoration, same-name cookie isolation, bulk deletion, native indicators,
the shared icon picker, and Passwords for a Profile without a Space.
Settings preview renders both deletion states and the bulk dialog at 1x/2x.
The initial shell-only Debug/Chrome receipt (before 0701–0703) passed
Profiles 41/41 (27 shell rows), Sidebar
19 rows, Little Open 39/39, Features 19/19, Window 76 rows and Incognito
26 rows. Sidebar's durability row is covered by Profiles. Window's two
Release timing rows are skipped in Debug; its existing card-material row
and Incognito's engine/display follow-ups retain their recorded status.
Every suite's owned-process cleanup passes. The startup cleanup checks pass
all 14 boundary/recovery cases. See [acceptance.json](profiles-shell/acceptance.json).

Removing both App repair calls makes the repair row fail. Restoring the old
Passwords URL makes both Passwords rows fail with `chrome://settings/` as
the final URL; the other six page rows pass. An intentional failure with
the delete sheet open leaves zero owned windows and processes, without
forced termination. All temporary source breaks were restored before the
final builds.

The merged full gate passes 23 of 24 checks. Its command-bar timing rows
150/151 failed at CPU p95 8.63 ms (8 ms budget), inline increment 0.471 ms
(0.3 ms budget), load 19.5 / 30.9 / 35.5. After the lead ended the quiet
window, one strict focused rerun passed all 151 checks: CPU p95 6.81 ms,
inline increment -0.042 ms, measurement load 7.4 / 7.9 / 14.4. It ran under
the quiet lock and Section 10 wrapper; build 2 s, check 37 s, load start
5.05 / 7.73 / 14.67 and end 7.41 / 7.89 / 14.40. All 24 verify-all checks
now pass across the full run and its focused closure. No threshold or
baseline changed. Every command-bar attempt and its load is recorded in
[acceptance.json](profiles-shell/acceptance.json).

Native light/dark 1x captures cover the header at rest/hover, Space Manager
and Little Open's custom Profile icon. `header-render-*@1x.png` and
`header-render-*@2x.png` are offscreen two-Profile renders. The Profile icon
pane and all three deletion states also have offscreen 1x/2x renders.

## Display reruns (2x, lead) — done

Native captures were taken on the M1 Pro built-in Retina display on
2026-11-07, at main `f65327a5`, with the command below (29 PASS, exit 0).
The eight window PNGs are now committed: `header-{light,dark}-{rest,hover}-2x.png`,
`manager-{light,dark}-2x.png`, and `little-open-profile-{light,dark}-2x.png`.
Each width and height is exactly twice its 1x sibling: header 2000 × 1400,
Manager 1920 × 1280, Little Open 2370 × 1664. The harness checked the native
pixel/window-point ratio. No image was upscaled. The M5 1x captures retain
their original provenance; these M1 images do not claim Arc parity.

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/engine_e2e.py --style chrome --only profiles --profiles-shell-only --keep
```
