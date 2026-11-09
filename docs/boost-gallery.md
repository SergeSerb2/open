# Local Boost Gallery

File ▸ Boost Gallery and the command-bar action open Library ▸ Boosts as a card
grid. Window ▸ View Boosts keeps the list. Both commands reuse
`AppSettingsActions.showLibrary(section:boostsPresentation:boostsProfileID:)`, one
`LibraryPresenter`, and one `LibraryViewModel`. Presentation is transient; it
does not add a preference or a second window.

Browser commands pass the invoking factory's Profile; Little Open passes its
session Profile. If the Library is key or already visible on Boosts, its Profile
picker stays unchanged. Otherwise an explicit Boosts open uses the caller's
Profile, or the default regular Profile for an app-level command. A plain
`view-library` call changes neither Profile nor presentation. The optional
presentation parameter defaults to nil, which preserves the current layout.
Only `view-boosts` explicitly requests list; only Gallery requests gallery.
The Boosts section also has a small List/Gallery segmented control, including
in its empty state. The editor's All Boosts path keeps the selected layout and
uses the same Profile-preservation rule. The existing Profile picker and search
apply to both layouts. `BoostsProvider` is the sole `app.stores.boosts` owner.
Observation of its revision updates cards
after changes in the editor, import or Library.

Each card shows the name, host pattern with optional path prefix, the shared
`BoostGlyph.fill` in `Core.brandBlue`, an enable switch, Edit and Delete. The
context menu also keeps Rename. Card fill, border, fonts and radius use
`SettingsTokens`; the adaptive grid uses the Library Captures grid's spacing
and minimum width. The empty state uses the existing Library Boosts text.
No preview image is requested, cached or generated. Opening the Gallery loads
no site for a preview.

The list and grid share bindings, Edit, Rename, and Delete confirmation state.
Actions still enter `App/Boosts/BoostLibraryActions.swift`. Toggling a card uses
`AppBoosts.setBoostEnabled` → `refresh(profile:)` → `BoostEngineAdapter.refresh`.
There is no new delivery path. Toggle bindings and Edit callbacks capture the
Profile when the row/card action is formed. Rename/Delete confirmations retain
the original Profile and close if the Profile selection changes. Library Delete
has no Boost-specific Undo registration today; this change keeps that behavior.

Menu validation and the command-bar action gate refuse Gallery in private
windows and while `open.advanced.enableBoosts` is false. Validation reads the
preference through `BoostPreferences.globallyEnabledKey` without creating a
Boost owner or opening a Profile. Settings, the editor, runtime and existing
harnesses share that constant. With Settings/Library key, or with no browser
window key, this remains an app-level Library command, as `view-boosts` is. It
uses a regular Profile even if the only browser window is private; it never
uses the private context (F3, accepted parity by the Section 12 lead).
The existing command registry and action title are unchanged. The change is
outside the command bar's text, drawing and keystroke code, but the lead's required TANDEM
§4c/§4d timing qualification still applies.

## Acceptance after the holds

All runtime rows below are **NOT RUN**. Section 12 lead update items 25 and 26
hold the screens and disk. No build, verification runner, App launch or capture
was used for this change during the hold. Source review and `git diff --check`
do not prove runtime acceptance.

| Row | Real-App check on the M5 | State |
|---|---|---|
| BG1 menu | File ▸ Boost Gallery opens Boosts in gallery mode. Open View Boosts, then Gallery again; the Library window number stays the same and each route restores its own layout. | NOT RUN |
| BG1 command bar | Use Cmd+T, type Boost Gallery, select that action and press Return through the App event path. The same Library window shows the grid. | NOT RUN |
| F1 preserve Profile | Select Profile B in the Library with browser A behind it. With the Library key, File ▸ Boost Gallery keeps B. Repeat from browser A while the Library remains visible on Boosts. When opening a closed Library from browser B, it uses B. Restore the old Profile reset temporarily and record the preservation case failing. | NOT RUN |
| F2 preserve layout | Open Gallery, select another Library section, return through the Boosts sidebar, then choose List in the layout control. `view-library` keeps both the selected Profile and layout; `view-boosts` explicitly chooses List. Also check `view-library` with History selected. With the old default `.list` parameter/implicit Profile reset restored, record the preservation case failing. | NOT RUN |
| F4 captured Profile | Exercise a row/card Toggle and Edit around a queued Profile change in the real App. The callback retains its rendered Profile and does not act on the newly selected Profile. | NOT RUN |
| F6 preference | Toggle Boosts in real Settings; verify the runtime, editor, Turn On action, menu and command-bar gates agree on the shared preference. | NOT RUN |
| BG2 cards | Create two nonempty Boosts through the editor on two fixture hosts in one Profile. Both cards show the correct names/sites. Test another Profile and search, then return. | NOT RUN |
| BG2 live toggle | Turn one card off: its open matching page loses the Boost and the other page keeps its Boost. Turn it on: the first page regains it. Check the stored enabled flags too. | NOT RUN |
| BG3 Edit | Press a card's Edit; the existing Library action opens the editor for that stored Boost and Profile. | NOT RUN |
| BG3 Delete | Press Delete and Cancel, then Delete and confirm. The card and live effect disappear; any editor for that Boost closes. No Boost-specific Library Undo exists. | NOT RUN |
| Empty | With no Boosts in the selected Profile, Gallery shows Nothing Boosted Yet! with the same message as the list. | NOT RUN |
| Disabled | Global Boosts off disables the menu and command-bar action. A private browser window disables them with the global switch on. Dispatch from that private window cannot open Gallery. The app-level regular Library remains allowed per F3. | NOT RUN |
| Negative proof | Temporarily restore only the old `boost-gallery` enablement refusal, rebuild, and record BG1 failing through the menu and command bar; restore the fix and rerun. | NOT RUN |
| Focus | Check Cmd+W, Cmd+T, Cmd+L, Esc and Return in the Library, command bar and confirmation sheet through `OEApplication.sendEvent`. | NOT RUN |

Use synthetic fixtures and the existing App automation runner. Do not use
computer use or launch Arc. `settings-state` reports `boostsPresentation` and
`boostsProfile` for the selected Library context. The grid, list, cards and
card controls have stable accessibility identifiers (`boosts.gallery`,
`boosts.list`, `boosts.layout`, `boosts.<id>.card`, `.enabled`, `.edit`, `.delete`).
Read the real hosted UI and page state as well as the presentation flag. For BG3 fixture
planning, the existing Library Edit action opens the stored host/path as HTTPS;
it does not retain a development fixture's HTTP port.

After explicit release of both holds, follow the current Section 12 rules:
build Debug and Release against main's recorded engine through `s12-heavy.sh`,
audit shared literal keys, run BG acceptance and `boosteditor`, `incognito` and
settings suites, then the full `tools/verify-all.sh` on the final head. Required
regressions include `sitecontrol-render`, `boosts`, `settings-preview` and
`commandbar-render`. Every App/harness launch needs the M5 screen lock, one
suite per invocation. Use the quiet lock only for timing receipts and record
loads for strict and any required paired runs. Do not regenerate baselines or
relax thresholds. Keep the raw misses separate from lead qualifications.

The online/shared Gallery remains out of scope. Arc Gallery's shared-browsing
role remains a guess in the feature-gap audit; this page specifies only Open's
local behavior and makes no new reverse-engineering claim.
