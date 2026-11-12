# Audit items A11, A16, A17: static findings (2026-11-12)

Source: `strings -a /Applications/Arc.app/Contents/MacOS/Arc` (Arc 1.172.2, build 90755; raw list in `.re/cal/arc-strings.txt`,
line numbers below are lines of that list). No Ghidra run: each key is a Swift enum case with no string reference to
follow. Every statement is a fact from the cited strings unless it is marked **guess**.

## A11. Arc auto-disables uBlock on an allow-listed site

| Fact | Evidence |
|---|---|
| The function is `autoDisableUBlockOnAllowListedDomainsIfNecessary(in:)` in `SharedAppFeature/AppData+ManageAdBlockers.swift` | lines 567273–567284 |
| It runs this script in the extension: read `netWhitelist` from `chrome.storage.local`, add `www.youtube.com` if it is missing, sort, write back | lines 567277–567282 (the script text is in the binary) |
| The only host is `www.youtube.com`; the log line is "Automatically disabled uBlock on YouTube for profile " | lines 567279, 567283 |
| It runs once per Profile: completed Profiles are kept in `autoDisableAdBlockOnAllowListedURLsCompleteProfileIDs` | line 543826 (defaults key) |
| A remote flag gates it: `auto-disable-u-block-on-allow-listed-domains-enabled` | line 553781 |
| The target is uBlock Origin: `netWhitelist` is uBlock Origin's own allow-list key; Arc's known-extension list has `uBlock` and `uBlockLite` as separate cases | line 665483 block (`uBlock jsonFormatter iCloudPasswords arcNative … uBlockLite …`) |

So "allow-listed domains" is not a user list. It is one fixed host. **Guess:** Arc added it when YouTube started to block
viewers who used an ad blocker (2023), to stop that warning for Arc users with uBlock Origin.

**Verdict: out of scope. Do not build.**
- It changes a third-party extension's own settings without asking. Open's rule (lead, 2026-11-12, on JSON Formatter) is that
  Open never acts on third-party extensions silently.
- The target is uBlock Origin's `netWhitelist`. Chrome Web Store no longer offers uBlock Origin (Manifest V2); uBlock Origin
  Lite has no `netWhitelist`. The script would do nothing for today's installs.
- The neighbouring Arc feature, "Speed up Arc by choosing one ad blocker for this profile" (`presentManageAdBlockersDialog`,
  key `hasCompletedMultipleAdBlockersSelection`), is a separate item; Open already warns about a second blocker in
  Settings ▸ Ad Blocking.

## A16. `autoCleanInactiveTabs*`, `cleanTabs*`

| Fact | Evidence |
|---|---|
| Defaults keys: `autoCleanInactiveTabsEnabled`, `autoCleanInactiveTabsThreshold`, `lastCleanTabsDate`, `cleanTabsTriggerCount`, `cleanTabsRecentlyClosedEduShown`, four `cleanTabsUpsell*` keys, `hasDismissedCleanTabsUpsell` | lines 543813–543822 |
| Analytics names: `cleanTabsTriggered`, `cleanTabsEducationPopoverShown`, `cleanTabsInactivityThresholdChanged`, `cleanTabsRestoreSingleTab`, `cleanTabsRestoreAllTabs`, `cleanTabsUpsellShown`, `cleanTabsUndo` | lines 675842–675849, 677031 |
| Types: `CleanTabsShowCleanedTabsEntryPoint`, `CleanTabsRestoreSource`, `CleanTabsGroupDeletionSource`, `CleanTabsInactivityThreshold`, `CleanTabsUpsellButton` | lines 514959–514964 |
| The settings identifiers `autoCleanInactiveTabs` and `autoCleanTabs` sit in lists with `tabGroupEmojiIcons`, `meetingTabGroups`, `tabGroupOptClick`, `skillsMenu`, `slashCommand`, `bookmarkTab`, `newTabsAtStart` | lines 549100–549112, 549244–549256 |
| The type list around them is `Clia*` (onboarding, connected apps, workspace) | lines 514950–514958 |
| No user-visible text: no menu title, settings label, toast or alert with "clean" exists in the binary (only "Clean up Folders" in an unrelated prompt list, and AI prompt text) | `grep -i` over the list: lines 541764, 559423 only |

Tab groups (`CleanTabsGroupDeletionSource`), a bookmarks bar, a Skills menu and slash commands are Dia features; Arc has none
of them. The Arc binary carries shared Dia code (the same key list holds `diaTour`, `bookmarksVisibilityPreference`,
`tabGroupAutoRenameAweAnimationDisplayCount`, `supertab*`).

**Verdict: out of scope. Not an Arc feature.** It is Dia's "clean inactive tabs" (it closes tabs that were not used for a
threshold and offers a restore), compiled into shared modules, with no reachable surface in Arc. Arc's own equivalent is
auto-archive, which Open has. It is not an Arc Max feature either; it is a Dia feature.

## A17. `domainToProfilePreferences`

| Fact | Evidence |
|---|---|
| One defaults key, `domainToProfilePreferences`, between `themeToCSSSharingAllowed` and `showContentDebugViews` in the key list | line 543866 |
| No type, selector, log line or user-visible text contains "domainTo", "ProfilePreference" (singular) or "profile for domain" | `grep` over the list: no other hit |
| `ProfilePreferences*` types are the Settings ▸ Profiles pane (`PreferencesFeature/ProfilePreferencesState.swift`) | lines 519987–520112, 560256–560259 |
| The user's Arc defaults on this Mac do not contain the key | `defaults read company.thebrowser.Browser` key list (2026-11-12) |

The name allows two readings. **Guess 1:** a map from a web domain to a Profile choice (for example "open links of this
site in Profile X", remembered from a Profile picker). **Guess 2:** per-Profile settings stored under a defaults "domain".
`docs/re/features-core.md` line 1004 lists it under per-Profile site preferences, also as a guess. Static strings cannot
decide.

**Verdict: not decidable statically; do not build from a guess (AGENTS.md rule 7).** One runtime read settles it: capture
item A17-a in `C-questions.md` (C3 runs `defaults read company.thebrowser.Browser domainToProfilePreferences` after each
of a few per-site actions with two Profiles). If it is a per-site Profile choice, the size is S to M (Open has Air
Traffic Control rules that already route a site to a Space or Profile).

## Summary

| Item | Plain Arc feature? | Decision | Size |
|---|---|---|---|
| A11 uBlock auto-disable | Yes, behind a remote flag, one fixed host | Out of scope: silent change of a third-party extension; target extension is gone | — |
| A16 clean tabs | No: Dia code in shared modules | Out of scope | — |
| A17 `domainToProfilePreferences` | Unknown | Wait for capture A17-a | S–M if confirmed |
