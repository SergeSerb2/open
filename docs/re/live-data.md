# Live data: Live Folders, calendar (Previews and Live Calendar), Join Meeting, mail previews

Agent F2, 2026-11-11. Static analysis only. Arc was not launched.

Targets: Arc 1.170.0 (`.re/bin/Arc-arm64`) and the installed Arc 1.172.2 (`/Applications/Arc.app`, read-only).
The relevant strings and source paths are the same in both builds; only small additions in 1.172.2
(`GitHubClient.RequestOutage`, `fetchPullRequestDiff`). Evidence: `strings -a` of both binaries, `diff` of the
matching lines (raw in `.re/f2/s170.txt`, `s172.txt`, `k170`, `k172`).

Evidence keys used below:

- `S:<line>`: line in `strings -a -n 4 .re/bin/Arc-arm64` (`.re/f2/s170.txt`).
- `T:<Type>`: Swift reflection field records (`.re/handoff/sections/s17/re/swift-fields-resolved.json`,
  extract in `.re/f2/fields-f2.txt`).
- `G:<function>`: decompile from the shared saved Ghidra project `ArcMain` (read-only; Ghidra 12.2; queries
  ran one at a time under `/tmp/open-ghidra.lock`, 8 GB). Raw in `.re/f2/ghidra1.txt`, `ghidra2a.txt`,
  `ghidra2b.txt`, `ghidra3.txt`. Short strings (15 bytes or less) are Swift immediates, decoded with
  `.re/f2/tools/small2.py`.
- `A:<asset>`: `xcrun assetutil --info` of a bundle's `Assets.car`.
- `D:<file>`: the user's Arc data, copied read-only to `.re/f2/arcdata/` (schemas only here).
- `W:` public web sources (listed at the end).

"Guess" marks every statement that the evidence does not prove.

Not in scope here: `HoverCards` (`hover-cards-enabled`, `HoverCardViewModel.SummaryTimeout`,
"5-Second Previews") is the Arc Max link-summary feature and stays out of scope. Slack, Notion, Google Drive,
Confluence, "Chats", "Home task" and "Inbox" live items are shared code with the company's other browser (Dia):
the types exist (`T:BaseModels.LiveItem.Data` cases `notion`, `googleDrive`, `confluence`, `chat`, `homeTask`;
`LiveSlackClient`, `LiveNotionClient` with `app.notion.com/api/v3/*` endpoints, `S:135043`), but no Arc menu,
setting or Live Folder data source exposes them (`T:BaseModels.AutomaticLiveFolderDataSource` has one case,
`github`). Guess: they are unreachable in Arc. Prefs `hasTurnedOffChatsLiveFolder` and
`hasTurnedOffDocumentsLiveFolder` (`S:113735`) are the only hint and have no UI.

---

## 1. Two calendar systems and one mail system

Arc has two separate calendar features. They use different data paths.

| | Calendar **Preview** (hover card) | **Live Calendar** (Favorites tile) |
|---|---|---|
| Where | Hover card on a Pinned or Favorite Google Calendar or Outlook Calendar tab | The Google Calendar Favorite tile itself: countdown subtitle, reminder, Join |
| Module | `Previews` (`Previews/Client/PreviewsDataClient.swift`, `Previews/Fetchers/GoogleCalendarDataFetcher.swift`, `MicrosoftOutlookDataFetcher.swift`) | `LiveCalendars`, `LiveCalendarClient`, `AppTray.LiveCalendarItemView` |
| Data path | Official APIs with OAuth: Google Calendar API v3, Microsoft Graph | The user's signed-in Google session: a hidden incognito context gets the Profile's Google cookies, loads the Calendar web app, and reads the app's own network responses |
| Arc's own credentials | Yes: Arc ships a Google installed-app OAuth client and a Microsoft app registration in the binary (values deliberately not recorded here) | No |
| Arc server | No server of Arc's for the data; tokens go straight to Google/Microsoft token endpoints | No |
| Flag | Setting `calendarPreviewEnabled` / `outlookCalendarPreviewEnabled` | LaunchDarkly flag `calendar-live-preview-enabled` |

Mail previews (Gmail, Outlook Mail) belong to the Preview system.

---

## 2. Live Folders

### 2.1 What it is

A sidebar folder that Arc fills by itself with the user's open GitHub pull requests. Arc adds a PR when it appears
and removes it when it is no longer active. It is a normal folder (`data.list`) with extra
`automaticLiveFolderData`, and its children are normal tab items.

- Public description (W1, W2): created automatically the first time the user creates a pull request on
  github.com; the folder is named "Pull Requests"; it can also be created by hand from the sidebar context menu
  ▸ Live Folders ▸ GitHub; deleting it stops automatic creation until it is turned on again; github.com only
  (no GitHub Enterprise Server domains); since 2024-07 it also shows review requests for the user's teams.
- Only data source in Arc: GitHub (`T:BaseModels.AutomaticLiveFolderDataSource` = `github`). Bitbucket exists
  as a PR source type (`T:BaseModels.LiveItem.PullRequestSource` = `github | bitbucket`) and the strings hold
  Bitbucket sign-in and dashboard URLs (`S:114530–114532`), but no Bitbucket data source. Guess: Bitbucket is
  not reachable.

### 2.2 Surfaces and entry points

| Surface | Facts | Evidence |
|---|---|---|
| Space context menu | Item "Live Folders" with a submenu holding "GitHub" (a toggle). Order: … "New Folder", "Live Folders ▸", separator, "Share Space…" … | `G:FUN_102ed863c` ("New Folder", "Live Folders", "Share Space"); `G:FUN_102edaf50` ("GitHub"); comment "Menu item to manage which live folders are active in this space" `S:134747`; capture session 2 menu row in `interaction-states.md` (Space menu) |
| Automatic creation | When the user opens or edits a PR on github.com, or submits a review, Arc creates the folder (if not turned off) and moves that PR tab into it | `T:LiveFolderCreationSource` = `pullRequestCreated`, `pullRequestDescriptionEdited`, `pullRequestReviewSubmitted`, `spaceContextMenu`; events `githubLiveFolderCreatedForOpenedPR`, `githubLiveFolderUpdatedForOpenedPR`; `reparentPullRequestToLiveFolder(_:contentID:windowInfo:)`, "Unable to find appropriate Space for Pull Request." `S:131760–131772`; URL fragment `pullrequestreview-` `S:114542` |
| Turn off | Per-app preference `hasTurnedOffGithubLiveFolder`; deleting the folder sets it (W2) | `S:113737`; W2 |
| Intro popover | `LiveItemIntroPopoverViewController`: title "Pull Requests", body "Pull requests from you and your team will show up here automatically" | `G:FUN_100cacda0`; `S:116336`; pref `hasSeenGithubLiveFolderEducation` `S:113734` |
| Folder context menu (`liveFolderContextMenu(listItemIDs:)`) | Header "Pull Requests"; a "Repositories" section with one toggle per repository that has an active PR, then the note "This list is generated based on your currently active pull requests."; a "Single Sign-On" item with "Required" and the note "SSO ensures all of your organizations' PRs appear"; "Refresh"; shared folder items such as "Copy All Links"; "Delete Live Folder" / "Delete Live Folders"; "Failed to update" appears when the last fetch failed | `G:FUN_102eb5460`, `FUN_102eb640c` ("Pull Requests", "Refresh"), `FUN_102eb71b8` ("Repositories", "Single Sign-On", "Required"), `FUN_102eb4f64` ("Copy All Links"), `FUN_102eb6de4/6d38` ("Delete Live Folder(s)"); `S:134650–134661` |
| Delete alert | Title "Delete your %@ Live Folder?"; body "You can restore this folder at any time by right-clicking the sidebar."; buttons as for folders ("Delete Folder", "Cancel") | `G:FUN_102a75b50`; `S:132820–132824` |
| Folder header states | "Login with SSO to unlock this folder" (with an `exclamationmark.triangle` symbol); "Sign back in to GitHub."; "…re having trouble connecting to GitHub; click here to see your Pull Requests." | `G:FUN_1003edccc`; `S:112394–112396` |
| Rows | One tab row per PR. More rows behind a "Show More" cell ("Cell that reveals more items in a live folder"). New items can show the unread dot (`showNewItemsAsUnread`) | `G:FUN_100c8a574`; `S:116300`; `performSidebarMutations(…showNewItemsAsUnread:…)` `S:131768` |
| Row hover popover | `LiveItemPopoverViewModel {title, subtitle, icon, width}`; subtitle example "%@ needs your review" | `T:BaseModels.LiveItemPopoverViewModel`; `G:FUN_100c8b050` |
| Peek-out when collapsed | A new PR "peeks" out of a collapsed folder (W2) | W2; folder `peeked` state exists in Arc and Open |
| Developer tool | "Automatic Live Folders" item and "GitHub Parser Debug Tool" window in Arc's internal Developer menu | `S:111234`, `S:131451`. Not a user surface |
| Toast / log titles | "Live Folder Created", "Live Folder Refresh Failed", "Live Folder Pull Request Update Failed" | `S:131750–131780` |

### 2.3 Data per PR

`T:BaseModels.PullRequest`: `number`, `title`, `repo`, `author`, `status` (`open | closed | merged | draft`),
`reviewStatus`, `myReviewStatus`, `isAwaitingMyReview`, `createdByMe`, `updatedAt`, `reviewRequestedAt`,
`reviewCompletedAt`, `diffStats {linesAdded, linesRemoved, filesChanged}`, `checks {passedCount,
inProgressCount, failingCount, pendingCount, failingChecks[{name, url}], lastUpdated}`, `hasConflicts`,
`hasUnresolvedConversations`, `stack {number, position, size, baseRef}`, `stackListHint`, `scrapeStatus
(inProgress | completed | failed)`.

The status icon comes from GitHub's own octicon class names in the page: `octicon-git-pull-request`,
`-draft`, `-closed`, `octicon-git-merge`, `octicon-git-merge-queue` (`S:131406–131411`). Which of the other
fields are drawn in the row or popover is not proven: **needs capture**.

### 2.4 How Arc gets the data (no OAuth, no Arc server)

Arc reads github.com as the signed-in user, with the cookies of the folder's Space Profile
(`LiveFolderFetchContext {browserContextID}`, `T:BaseModels.LiveFolderFetchContext`).

1. **Search.** Arc runs GitHub issue-search queries and parses the HTML result pages and the JSON that
   GitHub's new pulls dashboard embeds (`script[type='application/json']`, `pullsDashboardSurfaceLayoutRoute`,
   `app-name="dashboard-surface"`, `S:131395–131397`, `S:131529`). Query fragments, one per filter kind
   (`T:GitHubClient.FetchType` = `createdByMe | requestingMyReview | approved | changesRequested`), `S:131516–131524`:
   - `is:pr is:open sort:updated-desc` and `is:pr is:open updated:>=<date>` / `is:pr updated:>=<date> sort:updated-desc`
   - `author:@me involves:@me`
   - `user-review-requested:@me involves:@me`, or `review-requested:@me` when team review is on
     (`gitHubTeamReviewEnabled`, `T:LiveFoldersFeature.State`)
   - `review:approved involves:@me`, `review:changes_requested involves:@me`
2. **Details per PR.** Arc loads the PR page in a web content of that Profile and runs a page script that
   returns only the header, state label, review status, assignees, first and last timestamps, diff stats,
   "Files changed" count, a conflicts flag and an unresolved-conversation flag (`S:131430–131514`; Arc's script
   is not copied). It also fetches checks, the merge box, stack membership, user hover cards and the review
   thread (`T:GitHubClient.GitHubClient` closures `fetchPullRequestChecks`, `fetchPullRequestStatusChecks`,
   `fetchPullRequestMergeBox`, `fetchPullRequestStackMemberships`, `fetchUserHovercard`,
   `fetchPullRequestThread`).
3. **HTML fetch.** `Scraping/HTMLFetchClient`, `WebViewHTMLFetcher`, `URLRateLimiters` (`S:133106–133185`);
   request headers `GitHub-Verified-Fetch` and `X-Requested-With` (`S:131420`); parsing with Fuzi XPath.
4. **Sign-in detection.** Navigations to `https://github.com/login`, `github.com/logout` and the two-factor
   pages (`S:114536–114541`) trigger refetch reasons `githubUserSignedIn` / `githubUserSignedOut`.
5. **SSO.** The dashboard's SSO banner (`data-testid='global-sso-banner'`) and `sso_organizations` /
   `https://github.com/orgs/` (`S:131395–131399`) give the "Needs Single Sign-On" state. Preference
   `githubLiveFolderSSOPreferences` (`S:113733`).

### 2.5 Refresh

- Reasons (`T:LiveFolderFetchReason`): `manuallyCreated`, `manuallyRefreshed`, `refreshFailed` (retry),
  `windowForegrounded`, `githubUserSignedIn`, `githubUserSignedOut`, `githubPullRequestCreated`,
  `githubPullRequestReviewed`, `spaceFocused`, `filterUpdated`, `liveItemSelected`, `liveItemUnselected`.
  Refresh types `manual | timer` (`T:LiveFolderRefreshType`). Fetch types `allItems | individualItem`.
- Throttle: `refreshThrottled` event; flag `automatic-live-folders-min-refresh-interval-in-seconds`
  (`S:123521`). Its built-in default is read from constant `0x103664f00` = 10 (`G:FUN_1013dd908`, bytes
  read from the binary). Derived: 10 s minimum between refreshes of one folder. LaunchDarkly could override it.
- A timer exists (`timer` refresh type) but its period is not proven: **needs capture** (or guess: on
  window foreground and Space focus only).

### 2.6 Failure states

`T:BaseModels.GitHubFetchAndParseError` cases and their log names (`S:116316–116345`):
`notSignedIn`/`noCurrentUser` ("Not signed in to GitHub"), `needsSingleSignOn` ("GitHub SSO required"),
`rateLimitExceeded`, `requestedTooSoon`, `unableToGrabHTML`, `unexpectedPageStructure`, `parsingError`,
`invalidURL`, `invalidDocument`, `missingBrowser`, `missingWebContentForPullRequest`, `cancelled`,
`unknownError`. `AutomaticLiveFolderError.refreshError(_, isPersistent:)` decides between a passing failure and
the header states in §2.2.

### 2.7 Storage

- Folder settings live in the sidebar item: `StorableSidebar.json` item `data.list` has keys `customInfo` and
  `automaticLiveFolderData` (`T:BaseModels.SidebarList.CodingKeys`). Shape (`T:AutomaticLiveFolderData`):
  `{dataSource: {github}, lastFetch?: {timestamp, status: success | error(AutomaticLiveFolderError)},
  hiddenItems: Set<LiveItem.ID>, filter?: {github: {attributes: Int (option set), hiddenRepositories:
  Set<Repository>}}}`. The JSON spelling of enum cases is a guess (Arc's convention elsewhere is
  `{case: {}}`).
- Item data per Profile: `StorableLiveData.json` = `{version: 1, liveDataPerProfile: [profile, LiveItemsData…]}`,
  `LiveItemsData = {items: [LiveItem.ID: LiveItem]}`, `LiveItem = {id (url | placeholder), data (pullRequest:
  github(PullRequest)), lastModified?, lastViewed?, firstSeen?}` (`T:`, `S:131774–131777`). Monitor events are
  persisted in memory only (`PersistedLiveFoldersState {events, liveDataPerProfile}`).
- User data on this Mac: `liveDataPerProfile` is empty in the current file and all 11 backups (`D:`).
- Deleting a PR row by hand adds its ID to `hiddenItems` (`liveFolderChildItemManuallyDeleted`, `S:228277`).

---

## 3. Calendar Preview (hover card) and mail previews

### 3.1 Sources and settings

Settings ▸ General ▸ "Previews Settings…" sheet: "Show Arc Previews:" with 7 checkboxes, all on by default
(capture session 2, `sidebar-completion.md` §7). Keys: `folderPreviewEnabled`, `calendarPreviewEnabled`,
`gmailPreviewEnabled`, `outlookCalendarPreviewEnabled`, `outlookEmailPreviewEnabled`,
`recentPagesPreviewEnabled`, `cronPreviewEnabled` (Notion Calendar, formerly Cron) (`S:113760–113768`).
Two more keys have no row: `twitterBadgeEnabled`, `whatsAppBadgeEnabled`.

`T:BaseModels.PreviewType` = `gmail(inboxNumber)`, `recentPages(domain)`, `outlookMail(personal|business)`,
`outlookCalendar(personal|business)`, `folder(id)`, `gcalendar`, `twitter`, `whatsApp`. A Pinned or Favorite tab
whose URL matches a source gets that preview type (guess on the exact URL rules; host list in §3.6).

### 3.2 Calendar card

| Element | Facts | Evidence |
|---|---|---|
| Header | "Upcoming"; a "+" button with tooltip for "New Event" (Google: `https://calendar.google.com/calendar/u/0/r/eventedit`; Notion Calendar: `https://calendar.notion.so/event/create`; Outlook: `https://outlook.live.com/calendar/0/deeplink/compose`); a gear button | `G:FUN_100098754`; `S:110655–110683`; `T:Arc.CalendarPreviewContentView` (`clickedPlusButton`, `clickedSettings`) |
| Body | A day timeline: hour lines with labels and event blocks at computed positions (`CalendarLayout.HourLine {y, label}`, `EventPosition {position}`) | `T:Arc.CalendarLayout.*`, `T:Arc.CalendarPreviewCalendarView` |
| Event | Title, or "Event" when the event has no title; click opens the event (`permalink`) | `G:FUN_10018eb68`; `T:Previews.PreviewLinkType` |
| Join | "Join Event" / "Join " + name button (`QuickJoinButton`), shown for an event with a call link | `G:FUN_100092280`; W3 ("a big Join button … for any meeting within a few minutes") |
| Signed out | Copy "See upcoming meetings and join video calls instantly with the Calendar Preview." and button "Connect Calendar" | `G:FUN_1000923e0`; `S:110647–110650` |
| Re-auth | Per account: email, "sign in again" and "remove" actions (`CalendarReauthView {email, clickedReauthSignIn, clickedReauthRemove}`) | `T:` |
| Context menu | One "Sign Out" item per signed-in account, "Add Another Account", "Refresh", "Disable Live Calendar" | `G:FUN_1000ee6c8`; `S:110792–110804` |
| Open's design, not a captured fact | Arc's card and this menu need a signed-in Google account, so no capture exists. Open (lead ruling 2026-11-12 19:30, CG1): a gear left of "+" opens "Refresh", a separator, "Disable Live Calendar" (Refresh only on a Pinned calendar tab). Refresh asks the macOS calendar store to sync and reloads the card; a small spinner replaces the gear meanwhile. "Disable Live Calendar" closes the card; that Favorite then acts as a plain Favorite (no card, no countdown), stored per Favorite (`open.favorites.liveCalendarDisabled`). The Favorite's right-click menu shows "Enable Live Calendar" or "Disable Live Calendar". No account rows (EventKit) | `CalendarPreviewView.gearMenu()`; e2e `calendar` rows `cal_card_gear_*`, `cal_live_*_per_favorite` |
| Subtitles (tile or card, guess on placement) | "Event right now", "Event began N m ago", "Event in N m", "Event at <time>", "Event tomorrow at <time>" | `G:FUN_1025470c8`; `S:131934–131939` |
| Join rule | No auto-join for events the user has not answered (W4, May 2022). Declined events are filtered (guess from the `declined` response status) | W4; `T:Previews.GoogleCalendarEvent.Attendee.ResponseStatus` |

### 3.3 Mail card

| Element | Facts | Evidence |
|---|---|---|
| Header | "Unread"; "+" "New Email" (Gmail: `https://mail.google.com/mail/u/<n>/#compose`; Outlook: `https://outlook.live.com/mail/0/deeplink/compose`) | `G:FUN_100098c4c` |
| Rows | `UnreadEmail {title, date, url, people[], authorEmail?, summary?}`; Outlook `{createdDateTime, subject, bodyPreview, sender, webLink}` | `T:Previews.UnreadEmail`, `T:Previews.OutlookEmail` |
| Empty | Gmail: "No unread emails, you can exhale! 🍃"; Outlook has its own empty string (value not recovered) | `S:110659–110681` |
| Signed out | "Sign in to your Email to see messages at a glance." | `G:FUN_100096ddc` |
| Subtitles | "Unread Email(s)" forms: one, several, generic | `G:FUN_10253a85c`; `S:131931–131933` |
| Links | Clicking a mail or calendar link in a preview opens it as a Peek | `features-advanced.md` PK-4 |
| Badge colors | `GMailBadgeRed` #EA4335-like (0.918, 0.263, 0.208); `GithubBadgeBlack` #000; `TwitterBadgeGray`; `WhatsAppBadgeRed` | `A:ARC_AppTray` |

### 3.4 Recent pages card

"Recents" header; per site: "New Page" (Notion `https://notion.so/new`, Confluence `https://confluence.new`),
"New File" (Figma `https://figma.com/new`), "New Issue" (Linear `https://linear.app/new`); empty texts
"Recent Notion docs appear here.", "Recent Figma files appear here.", "Recent Linear projects and issues appear
here.", "Recent Confluence pages appear here." (`G:FUN_100098fac`; `S:110664–110680`). Data is local:
`RecentPagesFetcher.search(domain:tidyTitleConfiguration:browserContextID:)` searches the Profile's history for
that domain and cleans titles with tidy titles (`S:131921–131925`). No network.

### 3.5 How the Preview data is fetched

| Source | Mechanism | Evidence |
|---|---|---|
| Google Calendar | OAuth 2 installed-app flow with Arc's Google client (scopes `calendar.events.readonly` and `userinfo.email`), code exchange at `https://oauth2.googleapis.com/token`, then `GET https://www.googleapis.com/calendar/v3/calendars/primary/events` and `https://www.googleapis.com/oauth2/v1/userinfo`. Several accounts per Profile (`GoogleCalendarPreviewData.accounts[email]`) | `S:124776–124790`, `S:131888–131905`; `T:Previews.PreviewAuthenticationRequest.googleCalendar(profile, tokenURL)` |
| Outlook Mail and Calendar | Microsoft identity platform (`login.microsoftonline.com/common`, native-client redirect) with Arc's app registration; scopes `mail.readwrite user.read offline_access calendars.read`; Graph `me/`, `me/calendar/calendarView`, `me/mailFolders/Inbox/messages`; personal or business account | `S:131905–131920`; `T:BaseModels.MicrosoftAccountType` |
| Gmail | The Gmail Atom feed of inbox `n`, read with the Profile's Google cookies, parsed with an XML parser (`GmailPreviewXMLParser`, namespace `http://purl.org/atom/ns#`). The exact feed path is a short immediate and was not recovered: guess `/mail/u/<n>/feed/atom` | `S:131881`, `S:131887`; `T:Previews.GmailPreviewData {unreadEmails, inboxNumber}` |
| Notion Calendar | Host match on `calendar.notion.so` / `calendar.notion.com`; event links `https://calendar.notion.so/event/` | `S:110593–110594`, `S:110798`. Data path not found: guess it reuses the Google Calendar data |
| Recent pages | Local history search | §3.4 |
| Storage | `StorablePreviewsDataClient.json` = `{version: 1, data: [PreviewTypeAndProfile, PreviewData…]}`, `PreviewData = {lastRefreshed, metadata: gmail | gcalendar | outlookMail | outlookCalendar | recentPages…}`. Tokens are not in this file (guess: Keychain). The user's file holds one `gcalendar` entry with empty `accounts` | `T:Previews.PreviewsDataStore.StorableData`, `PreviewData`, `PreviewMetadata`; `D:StorablePreviewsDataClient.json` |
| Refresh | `refreshAllPreviews(always | ifStale)`, a periodic `refreshTimer`, and `setPeriodicUpdatesEnabled` (timer id `AppPreviews.RefreshPreviewsStateTimerID`). Period not recovered: **needs capture** | `T:Previews.PreviewsDataClient`, `PreviewsDataClientImpl` |

### 3.6 Meeting links

Recognised call links (`Previews/Previews+CalendarEvent.swift`, `S:131940–131944`): `meet.google.com/<path>`,
`<subdomain>.zoom.us/<path>`, `teams.live.com/meet/<path>`, `around.co/r/<path>`. Google events also use
`conferenceData.entryPoints` with type `video` (or `phone`) (`T:Previews.GoogleConferenceEntryPoint`). A
separate host list for "this tab is a meeting" (`S:270109–270116`): `meet.google.com`, `zoom.us`, `webex.com`,
`zoho.com`, `skype.com`, `ringcentral.com`, `goto.com`, `slack.com`. Teams meeting path `/l/meetup-join/` on
`teams.microsoft.com` (`S:114490–114491`).

---

## 4. Live Calendar (Favorites tile)

| Item | Facts | Evidence |
|---|---|---|
| What | A Google Calendar Favorite becomes "live": the tile subtitle counts down to the next event, a reminder appears before it starts, and a "Join" button joins the call | W5 (Arc 1.47.1, 2024-06); `AppTray.LiveCalendarItemView`, `LiveItemCollectionViewItem` |
| Subtitle | "in N m" before, "Now" within the minute, "N m ago" after start (strings "in ", "m", "m ago", "Now") | `G:FUN_101ceb9f0`; comments `S:128958–128960` |
| Subtitle colors | `GCalSubtitleBackgroundSecondary` light rgba(0,0,0,0.07), dark rgba(255,255,255,0.07); `GCalSubtitleBackgroundSelected` light (0.963, 0.976, 0.996, 0.90); `GCalSubtitleTextColorSecondary` light (0.13,0.13,0.13,1), dark (0.87,0.89,0.92,0.70); `GCalSubtitleTextColorSelected` (0.13,0.13,0.13,1); `IconViewBackground` light white, dark white 0.20 (sRGB) | `A:ARC_AppTray` |
| Reminder | Join button, dismiss, an interval picker, "View event"; join confirmation state; join keyboard shortcut shown (`joinShortcut`) | `T:AppTray.LiveCalendarItemView`, `LiveItemViewModel {showingJoinConfirmation, joinShortcut, needsIntroAnimation}`; `T:MeetingReminderDismissalReason` |
| Reminder time | "Never", "On Start", "Two Minutes Before", "Five Minutes Before", "Ten Minutes Before" (`LiveCalendarInterval`); stored per Profile (`didSetNotificationInterval(interval, profile)`); prefs `liveCalendarNotificationPreferences`, `liveCalendarBadgePreferences`, `liveCalendarPreviewPreferences`, `hasSeenLiveCalendarEducation` | `G:FUN_101d29690`, `FUN_102ed5780`; `S:116292–116299`, `S:113729–113732` |
| Tile menu | "Show Meeting Link" with "Copy Link" and "Dismiss" | `G:FUN_101d28c10` |
| Visibility | An event stays visible for `calendar-live-preview-max-minutes-visible-after-start` minutes after it starts; built-in default 10 | `G:FUN_1013de11c`; constant `0x103664f00` = 10 |
| Fetch cadence | `calendar-live-preview-min-fetch-interval-in-seconds`; built-in default 360 (6 min) | `G:FUN_1013de07c`; constant `0x1037343d0` = 360 |
| Fetch mechanism | Arc creates a web content in a hidden incognito profile, copies the Profile's Google cookies into it ("Hidden profile incognito should never have preexisting cookies."), loads the Calendar web app for account number N, and waits for the app's own events request and secondary-calendars request; it decodes their bodies. A timeout tears it down. Then it closes the browser | `S:131275–131312`; `T:LiveCalendarClient.LiveCalendarClientError`, `FetchParams {browserWindowContext, accountNumber, fetchMultipleCalendars}`, `LiveCalendarFetchResult {email, secondaryCalendars, events}`; W6 ("not powered by the Google API") |
| State | `LiveCalendar {provider: gcal, account, events, dismissedEventIDs, activeEvent, previouslyActiveEvent, lastFetchAttempt}`; `ActiveEventSession {event, hasJoined, timeFirstDisplayed, timeLastDisplayed}`; `CalendarEvent {start, end, calendarID, accountNumber, title, description, joinLink, isEligibleToAttend, attendees, attachments}` | `T:` |
| Multi-calendar | Flag `calendar-live-preview-multi-cal-support` | `S:123531` |
| Storage | Not found in `Storable*.json`. Guess: in memory plus preferences only | absence in `D:` and strings |

---

## 5. Join Meeting and meeting-related actions

| Item | Facts | Evidence |
|---|---|---|
| Menu | Tabs ▸ "Join Meeting", ⌘⌃J, selector `joinLiveMeeting:` | `menus-and-hotkeys.md` |
| Command bar | "Join next meeting", "Join next video conference"; trigger phrases include "Join Zoom Call", "Video Call", "Meeting" | `G:FUN_101d9bffc`; `S:129097–129192`; `T:ASE2.TypeTravelCandidate…JoinNextMeeting` |
| Target | The Live Calendar's active event `joinLink` (see the next row). ⌃⌘J with no calendar and no meeting gives no visible feedback (capture session 6, `v1/01-cal-dl-pip`) | saved decompile `.re/sidebar-completion/ghidra1.txt` lines 3488–3580 |
| Menu enabled state | The menu validation function `FUN_100314424` (Arc 1.170.0) has a branch for `joinLiveMeeting:`. It reads the Live Calendar state, takes the active event's join URL as an optional (nil when there is no Live Calendar or no event), compares it with nil (`Foundation.URL` `==`), and calls `setEnabled:` with "not nil". So the item is **disabled** unless an active event has a join link; it is never hidden | same decompile: `setEnabled_` at `LAB_100319dec`, reached from the branch through `LAB_100319de4` |
| Meet routing | Air Traffic Control default route for `meet.google.com` (pref `didSetDefaultGoogleMeetRoute`), toast "Meet links now open in your current Space!" with action "Choose where they open" | `S:125771`, `S:125836`; `runtime-observations.md` |
| Meet PiP | Flag `google-meet-auto-picture-in-picture-enabled`; `PictureInPicture.MeetingControls` | `S:123562`, `T:` |

---

## 6. Peek Email (⌘⇧E)

Open already opens a saved webmail Favorite or Pinned tab in Peek (`App/PageChrome/PeekEmailCommand.swift`).
Arc's binary has more: toasts "Checking for emails from %@", "Auth code for %@ copied to clipboard", and
"Make sure Gmail is favorited and you're signed in." (`S:125786–125792`, cases `checkingForEmails`,
`noGmailFavoriteOrAuth`), a code pattern of the form three letters/digits, dash, three letters/digits, and a page
script that tests whether the focused element is an input (`S:132559–132563`). Guess: when the focused field
waits for a login code, Peek Email looks in the Gmail Favorite for a recent mail from the current site's host and
copies the code. No code xref was found. **Needs capture.**

---

## 7. Needs capture

1. Live Folder: the Space menu submenu with the GitHub toggle checked and unchecked; the intro popover; the
   folder row icon; a PR row (icon, title, subtitle, unread dot); the row hover popover (fields drawn, width);
   "Show More"; the context menu with repositories and SSO; the three header error states; the delete alert.
2. Live Folder refresh: when a refresh happens (window foreground, Space focus, timer period).
3. Calendar Preview: signed-out card, signed-in card (size, hour line spacing, event block style, Join button),
   the context menu, re-auth state, Outlook and Notion Calendar variants.
4. Gmail and Outlook Mail cards: signed out, unread list, empty state.
5. Live Calendar Favorite tile: countdown subtitle, reminder card, interval picker, join confirmation,
   "Show Meeting Link".
6. Join Meeting (⌘⌃J) and the command-bar action with and without an upcoming meeting.
7. Peek Email (⌘⇧E) on a page with a focused code field.

## 8. Open's design where no capture is possible (LEAD 20:45, 2026-11-12)

These are **Open's own designs**, not captured Arc facts. The items needed a GitHub account, real sites or
macOS folder consent, so no capture session could settle them (C-LF-1..5). Each rests on the static evidence
cited in §2–§3 above; anything not listed there is a choice made by Open.

| Item | Open's design | Arc evidence it rests on |
|---|---|---|
| C-LF-1 PR row icon | Open's own 16 pt PR-state glyph family in place of the favicon. Inks: open = system green, draft = secondary label grey, merged = system purple, closed = system red. Never GitHub's octicon art | Status values from octicon class names `S:131406–131411` (§2.3) |
| C-LF-1 PR row hover popover | Folder-card family, 240 pt wide. Title = PR title; subtitle "#N · owner/repo"; a third line "‹author› needs your review" only when my review is awaited. No extra fetch per PR (no diff stats, no checks) | `LiveItemPopoverViewModel {title, subtitle, icon, width}`, "%@ needs your review" (`G:FUN_100c8b050`, §2.2) |
| C-LF-2 "Show More" | The first 10 PR rows, then one "Show More" row in the sidebar's secondary row style. A click shows the rest (up to the 50-row cap). The expanded state resets when the folder collapses. The row count of 10 is Open's choice | "Cell that reveals more items in a live folder" `S:116300` (§2.2) |
| C-LF-3 toasts | None. Refresh failures show only as the folder header state | Titles `S:131750–131780` are not proven user-visible; capture s5 showed no toast on creation |
| C-LF-3 Single Sign-On ▸ Required | A read-only state checkmark (on when the last fetch saw the SSO banner). A click opens the organization's SSO URL in a new tab. Nothing is stored | `githubLiveFolderSSOPreferences` `S:113733`; SSO banner and `sso_organizations` `S:131395–131399` (§2.4) |
| C-LF-3 refresh timing | Triggers as in §2.5 (foreground, Space focus, PR created or reviewed, sign-in or sign-out) with the 10 s throttle. No periodic timer | §2.5; no timer period found |
| C-LF-4 Recents and Gmail cards | Unchanged: the measured folder-card family. Header height, row count and "+" size remain GUESS until a capture | §3.3–§3.4 strings |
| C-LF-5 Library ▸ Media first-use card | Body "Allow Open to show your Documents, Desktop, and Download Folders to see them here alongside your Captures."; the Choose Folders button's tooltip and accessibility help "Quickly grab screenshots, images, and videos from your computer by showing them in the Open Library!". The folder prompt appears only on the user's click | LB-1 strings (features-advanced.md), with "Open" in place of "Arc" |

## Sources

- W1: Arc for Windows release notes, 2024-06-06 and 2024-07-18,
  https://resources.arc.net/hc/en-us/articles/22513842649623-Arc-for-Windows-2023-2026-Release-Notes
- W2: TechCrunch, 2024-04-11, https://techcrunch.com/2024/04/11/arc-browsers-live-folders-will-auto-update-tabs-for-you/
- W3: Arc Google Calendar integration page, https://arc.net/integrations/google-calendar
- W4: Arc for macOS 2022 release notes, https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes
- W5: TechCrunch, 2024-06-14, https://techcrunch.com/2024/06/14/arc-browser-new-live-calendar-button-feature
- W6: Yahoo Tech report on Arc's calendar feature, https://tech.yahoo.com/computing/articles/arc-wants-browser-browse-214201997.html
