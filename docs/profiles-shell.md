# Profiles shell — Section 10

Settings deletes a Profile after an exact typed-name confirmation. Delete
Unused Profiles lists the captured unused set and requires `DELETE`.
Default and assigned Profiles cannot be deleted. Model removal disables Undo
registration and clears older Undo actions. The App releases any context,
removes Open-owned data, and saves the snapshot synchronously.

`ProfileTeardown` owns release and pending cleanup. It records every
non-default context loaded this launch. Loaded engine/cache directories wait
for the next launch; never-loaded directories are removed immediately.
Both paths queue Local State cleanup for launch. The journal is bounded at
64 KiB, 1024 unique names, and 255 UTF-8 bytes per name. It rejects Default,
path components, malformed JSON and oversized input. Atomic writes sync the
file and parent before cleanup proceeds. Launch cleanup runs with the data
root locked, before `OEEngine.start`, and removes `profile.info_cache`,
`profile.last_used` and `profile.last_active_profiles` references. A cleanup
failure stops startup before the engine can use partially cleaned data.

The engine's current `releaseContext` completion proves that pages closed.
It does not prove Chromium Profile destruction. In-session deletion of
previously loaded engine data remains deferred until the engine supplies
that stronger barrier. No restart prompt is part of the shell flow.

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
- These checks do not claim Chromium Profile-destruction completion or Arc
  pixel parity for the new multi-Profile indicator. The existing
  single-Profile sidebar baselines stay authoritative.

## Acceptance

The real-App `profiles` suite includes missing-reference repair and saved
relaunch, exact typed deletion, immediate Open-owned removal, deferred
engine and Local State cleanup, never-loaded engine/cache removal, no Undo
restoration, same-name cookie isolation, bulk deletion, native indicators,
the shared icon picker, and Passwords for a Profile without a Space.
Settings preview renders both deletion states and the bulk dialog at 1x/2x.
Final results and the negative proof are recorded here after verification.
