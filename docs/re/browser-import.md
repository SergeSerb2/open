# Import from other browsers (Safari, Chromium family, Firefox)

Agent F3, 2026-11-11. Static analysis of Arc 1.170.0 (reference strings) and Arc 1.172.2 (installed bundle,
read-only), plus schema-only reads of browser files on this Mac. Arc was not launched.

Evidence keys used below:

- **MS**: Arc main binary strings, `.re/arccore/strings-arc-main.txt` (line numbers given as `MS:n`).
- **CS**: ArcCore strings, `.re/arccore/strings-arccore.txt`.
- **SEL**: `.re/arccore/objc-selectors.txt`, `.re/arccore/objc-classes.txt`.
- **AC**: `xcrun assetutil --info` of `ARC_ImportFeature.bundle` (raw: `.re/f3/assets-ARC_ImportFeature.json`).
- **MM**: main-menu nib strings, `.re/hotkeys/mainmenu-nib-strings.txt`.
- **DISK**: schema dump on this Mac with `.re/f3/scripts/schema.py` (prints table SQL and JSON key/type shapes only, never values). Raw: `.re/f3/chromium-*.txt`, `.re/f3/firefox-*.txt`.
- **PUB**: public source, linked.

Related findings: `passwords-autofill.md` PW-8/PW-9 (Arc's importer engine paths and selectors), `onboarding.md` (onboarding step list), `data-model.md` §5 (Arc's `User Data` is a stock Chromium directory).

## 1. What Arc imports, per source

Arc's own summary strings (MS:124851–124853) state the categories per source:

| Source | Arc's string | Categories |
|---|---|---|
| Safari | "We can import your history, passwords, and bookmarks from Safari." | history, passwords (manual CSV), bookmarks |
| Firefox | "We can import your history, autocomplete data, and bookmarks from Firefox." | history, form autocomplete, bookmarks. **No passwords, no cookies.** |
| Chromium family | "We can import your history, cookies, passwords, autocomplete payment info, and bookmarks from " + browser name | history, cookies, passwords, payment cards, bookmarks; plus extensions and open tabs (below) |

Additional categories, proven by names only:

- **Extensions** (Chromium family): engine selector `import:withCategories:withAllowedExtensions:withBookmarkImportTargets:skipExistingCookies:withDelegate:error:` (SEL); Swift state fields `installedExtensions`, `ExtensionID`, `ExtensionsSubscriptionCancellationID` (MS:87520 region). Arc also offers an **ad-blocker** subset: `AdBlockersSelection`, "Use all imported ad blockers", "All ad blockers will be removed" (MS:124838).
- **Open tabs / windows**: `didImportSessionWindows:` (SEL), `onboardingRestoreTabsFromOtherBrowsers`, `openTabImport`, `skipOpenTabImport`, events `onboarding_tab_import_finished/_skipped` (MS). Guess: Arc reads the source browser's session files and offers to reopen its tabs.
- **Favorites suggestions from history**: onboarding state fields `history`, `siteEngagement`, `suggestedTopApps`, `generatedTopAppsFromImport`, `autoSelectFavoritesEngagementThreshold`, `skipAndAutoSelectFavorites`, types `ImportedTopApp`, `SiteEngagementScore`, `TopAppAndScore` with fields `lastVisitTime`, `visitCount`, `score` (MS:234391, MS:87520). Reading: after import, Arc ranks sites from the imported history and site-engagement scores and pre-selects Favorites above a threshold. The threshold value is not in strings (needs Ghidra or capture).
- **Cookie policy**: toggle "Replace existing cookies with imported cookies", subtitle "Recommended if you haven't visited many websites in Arc yet" (MS:131167); engine flag `skipExistingCookies:` (SEL); Swift `deleteAllCookiesFromDestinationProfile()` "Deleted all cookies for profile" (MS:124900 region). Arc also clears destination history in some path: `clearHistoryFromDestinationProfile()` (same region; trigger unknown, guess: fresh onboarding profile only).
- **Referral side effect (do not copy)**: "Reported invite code from imported browser history to firebase-server." (MS). Arc scans imported history for its own invite links. Server-only; Open drops it.

### Supported source browsers (catalog)

ArcCore `arc/browser/importer/import_source_catalog.cc` sits next to these bundle IDs (CS): `com.apple.Safari`, `org.mozilla.firefox`, `com.google.Chrome`, `com.google.Chrome.canary`, `com.brave.Browser`, `com.microsoft.edgemac`, `com.vivaldi.Vivaldi`, `com.operasoftware.Opera`, `com.operasoftware.OperaGX`, and Arc itself. Data roots seen beside them: `Application Support/com.operasoftware.Opera`, `.../OperaGX` (CS).
The import bundle ships one logo per source (AC): `SafariLogo`, `ChromeLogo`, `FirefoxLogo`, `Brave`, `Edge`, `Opera`, `OperaGX`, `Vivaldi`. Chromium (unbranded), Dia, Zen and other Gecko forks are **not** in Arc's catalog.

## 2. Surfaces and entry points

| Surface | Entry point | Evidence |
|---|---|---|
| Menu item "Import from Another Browser…" | Arc menu (app menu) | MM:931–935, selector `importFromAnotherBrowser`; search aliases "Import Bookmarks; Import Settings; Import Logins; Import Passwords; Transfer Bookmarks; Transfer Settings; Transfer Logins; Transfer Passwords; Bookmarks" (MM:935) |
| Import dialog (sheet) | menu item; command bar; seeded tab | `ImportMenuFeature.ImportDialogSheetWindow`, `ImportDialogView`, `ImportDialogScreen`, `ImportDialogHeader`, `ImportDialogInstructionsView`, `ImportDialogButtonType` (MS) |
| Onboarding import steps | first run | `importSource → importFromSafari → topApps → importBookmarks → safariPasswordImportOptions → importSafariKeychain → topApps → … → adBlockers` (`onboarding.md`) |
| Seeded "Import Logins & Bookmarks" tab | new user's Arc Basics folder | MS:132025–132026; `data-model.md` seeded id `importLoginsAndBookmarks` |
| Password import prompt (sheet) | after onboarding, once (guess); a "Show password import prompt" menu item exists (`showPasswordImportPromptMenuItem`; guess: internal debug menu) | `PasswordImportPromptSheetWindow`, "Import passwords to Arc?", "You can import your passwords from another browser such as Chrome or Safari into Arc.", asset `password-import-prompt-icon` (MS:131182, AC); flags `eligibleToSeePasswordImportPrompt`, `hasShownPasswordImportPrompt` |
| Bookmarks-bar upsell | bookmarks bar context | `shouldShowImportUpsellOnBookmarksBar` (MS). Guess: Arc's Chromium bookmarks page. |
| Onboarding suggestion cards | Home / suggestions | `isOnboardingSuggestionHidden_importFromAnotherBrowser`, `..._importCookiesFromAnotherBrowser`, `lastUsageDate_importFromAnotherBrowser` (MS) |
| Progress and result toasts | while importing | "Now importing" + "Sit tight!", "Success! We imported all of your stuff", "Only some of your data imported. Please try again!", "We weren't able to import … please try again!" (MS:125851–125860) |

### Import dialog screens (Settings/menu path)

Strings in `ImportMenuFeature` (MS:131140–131200), in the order they appear in the binary:

1. **Source**: title "Import from your old browser"; body "Import everything you need from your old browser to hit the ground running with Arc." Browser tiles with logos; selection indicator colour `BrowserSelectionShadowIndicator` (light #FFFFFF, dark transparent; AC).
2. **Safari access** (Safari only): title "Import from Safari"; Full Disk Access copy "To import Safari browser history, Arc will need Full Disk Access. Feel free to remove access when this step is finished."; "After you have given access, you can choose to restart Arc now, or continue and restart later." Buttons: restart, "Continue without restarting", continue anyway when access seems missing. Images `SystemPreferencesVentura`/`SystemPreferencesMonterey` (AC) show the System Settings pane. `FullDiskAccessAuthorizer`, `FullDiskAccessTimerID` (MS) show Arc polls for the grant.
3. **Destination Profile**: "Which Arc Profile should we import to?", options "My Existing Arc Profile" and "Create a New Profile", note "A new Profile will keep your existing data separate from what you're importing.", and "This will create a new Space and assign your **<name>** Profile to it." (MS:131150–131175). Text field `importMenuFeatureNewProfileTextField`.
4. **Cookies option**: "Replace existing cookies with imported cookies" toggle (Chromium sources).
5. **Bookmarks selection**: "Bookmarks get an upgrade." / "Choose which bookmarks to bring along. We say, keep the ones you visit every day and let go of the rest." A tree with a top-level "select all" row (MS:124843–124848); types `ArcBookmarkTreeNode`, `Bookmarks.Bookmark.Options.Destination` (MS:87500).
6. Lock dialog when the source runs: "Quit Safari to continue importing", "Quit Firefox to continue importing" (MS:124861–124863); engine callback `didImportLockDialogShow:withDialogBody:completion:` (SEL); Chromium's `firefox_profile_lock.cc` (CS); running-app watchers `SafariRunningAppID`, `FirefoxRunningAppID` (MS).

Button roles (MS:131157–131165): back, restart Arc, exit, continue, continue anyway, "decline importing for now", cancel.

### Safari passwords

Arc cannot read Safari's passwords. It offers two paths (MS:124940–124975, MS:125440):

- Recommended: install Apple's iCloud Passwords extension ("Add iCloud Passwords Extension").
- Manual: "Import Passwords from Safari": the user exports from Safari ("Export All Passwords"), then drops the file on a drop zone "Drag or click here to upload" ("Upload your Passwords.csv file to Arc", help link "How do I find this?"). Validation error "The file you uploaded doesn't look like … passwords file". After import Arc offers "Want us to delete Passwords.csv?" with "I'll do this later" / "Don't delete Passwords.csv". Images `SafariKeychainImportVentura`/`Monterey` (AC, 1586×985) show the export steps.
- Drop-zone colours (AC, sRGB): background light #E0E1FF / dark #191B4C; border light #2C33E1 / dark #3239FB; foreground light #2C33E2 / dark #FFFFFF (P3); completed fill #C5E5C0, completed foreground #3EA82E; error #C93333.

The engine side reads Safari's **export files**: `arc/utility/importer/safari_exported_data_importer.cc` with "Unable to find Safari passwords CSV file", "Safari history JSON file missing 'history' array", "Failed to read Safari bookmarks HTML file", `initWithSafariExportedData:profileName:name:categories:` (CS, SEL). Upstream Chromium 156 also ships `user_data_importer.mojom.BookmarkHtmlParser` (CS). Reading: Arc can import a Safari "Export Browsing Data" archive (bookmarks HTML, history JSON, passwords CSV) as well as the live files.

### Where imported data lands in the sidebar

- Arc has no bookmarks list. Imported bookmarks become **pinned tabs in a pinned folder named "Imported from <Browser>"**, with the bookmark folder tree nested inside (for Chrome: a "Bookmarks bar" subfolder). PUB (secondary, third-party how-to articles: [windowsreport](https://windowsreport.com/how-to-import-bookmarks-in-arc-browser/), [allthings.how](https://allthings.how/how-to-manage-bookmarks-in-arc-browser/)). Not yet seen in a capture. The exact folder title and the `Destination` cases need capture.
- Onboarding recommends a subset: "We recommend bringing %@ bookmarks to start … it's easy to import the rest later." (MS:125448 region).
- A new destination Profile gets a new Space (string above).
- Open tabs: guess, they become Today tabs (`num_pinned_tabs_imported`, `onboarding_imported_pinned_tabs` suggest Chrome pinned tabs become Arc pinned tabs).

## 3. Arc import state machine (names only)

Engine API (`ADKClient`): `availableImportSources`, `loadImportSourceProfiles`, `availableImporterProfiles`, `beginImportSequence`, `endImportSequence` (MS). Delegate callbacks: `didImportInitialize:`, `didImportStart:`, `didImportCategoryStart:withCategory:`, `didImportCategoryEnd:withCategory:withError:`, `didImportEnd:withError:`, `didImportSessionWindows:`, `didImportLockDialogShow:…` (SEL). Swift: `ImportProfile` per source profile with `sourceProfileDirectoryBasename`, `destinationProfileDirectoryBasename`, `categoriesStatus`, `categoriesCompleted`, `activeFetchCategories` (fetch categories seen: `recentHistory`, `siteEngagement`, `bookmarks`), `isDestinationProfileNew`. Analytics fields: `importSource`, `profileCount`, `category`, `durationInSeconds`, `importedCount`, `availableCount`, `expandedCount`, `manuallySelected` (MS).
Engine source files: `arc/browser/importer/{arc_external_process_importer_host, chrome_importer_utils, import_source_catalog, importer_list, importer_manager, profile_writer}.cc`, `arc/utility/importer/{chrome_importer, chrome_importer_arc_parts, importer_overrides, safari_exported_data_importer}.cc`, and upstream `chrome/utility/importer/{firefox_importer.cc, safari_importer.mm, bookmarks_file_importer.cc}` (CS). So Arc reuses Chromium's old Firefox and Safari importers in a utility process and adds its own Chrome importer.

## 4. Source formats

### 4.1 Chromium family (Chrome, Brave, Edge, Vivaldi, Opera, Chromium)

Data roots (`~/Library/Application Support/`): `Google/Chrome`, `Google/Chrome Canary`, `BraveSoftware/Brave-Browser`, `Microsoft Edge`, `Vivaldi`, `com.operasoftware.Opera`, `com.operasoftware.OperaGX`, `Chromium`. Opera keeps its profile at the root, not in `Default` (guess from the CS path strings; verify).

Schemas below come from Arc's own Chromium 156 `User Data/Default` (DISK), which is a stock Chromium profile. In this agent's shell, listing `Google/Chrome`, `BraveSoftware/Brave-Browser` and `Microsoft Edge` failed with "Operation not permitted", while `Arc`, `Dia`, `zen` and `Google/Chrome for Testing` were readable. The cause is not settled: it may be this agent's sandbox or a macOS data protection (the Chrome folder carries a `com.apple.macl` attribute). **Needs check**: can a normal signed Open build read these folders without a prompt?

| Data | File | Schema facts |
|---|---|---|
| Profiles | `Local State` (JSON) | `profile.info_cache.<dir>.name`, `profile.profiles_order`, `profile.last_active_profiles` (`data-model.md` §5) |
| Bookmarks | `<profile>/Bookmarks` (JSON) | `{version, checksum, roots:{bookmark_bar, other, synced}}`; node `{type:"url"|"folder", name, url?, children?, date_added, date_last_used, date_modified, guid, id}`; times are microseconds since 1601-01-01 as strings (PUB: Chromium `components/bookmarks/browser/bookmark_codec.cc`). Arc has no such file (`data-model.md`). |
| History | `<profile>/History` (SQLite) | `meta.version` 70 in Chromium 156 (DISK). `urls(id,url,title,visit_count,typed_count,last_visit_time,hidden)`, `visits(id,url,visit_time,from_visit,transition,…)`, `keyword_search_terms`, `downloads*`. Same reader as Open's `ArcHistoryReader` (accepts versions 65–75). |
| Top sites | `<profile>/Top Sites` (SQLite) | `top_sites(url,url_rank,title)`, version 5 (DISK) |
| Passwords | `<profile>/Login Data` (+ `Login Data For Account`) | `logins(origin_url, action_url, username_value, password_value BLOB, signon_realm, date_created, blacklisted_by_user, …)`, version 43 (DISK). `password_value` is `v10` + AES-128-CBC, key = PBKDF2-SHA1(Keychain secret, "saltysalt", 1003) (Open's `ChromiumCrypto.swift`). |
| Cookies | `<profile>/Cookies` | `cookies(creation_utc, host_key, top_frame_site_key, name, value, encrypted_value, path, expires_utc, …, has_cross_site_ancestor)`, version 24 (DISK) |
| Cards, addresses, search engines, form autocomplete | `<profile>/Web Data` | `credit_cards`, `addresses`, `keywords`, `autofill(name,value,…)`, version 160 (DISK) |
| Extensions | `<profile>/Secure Preferences`, `Preferences` → `extensions.settings`; `Extensions/<id>/<version>/` | Open's `ArcExtensionsReader` already parses this. |
| Open tabs | `<profile>/Sessions/Session_*`, `Tabs_*` (SNSS binary command log) | PUB: Chromium `components/sessions/core/session_service_commands.cc`. Not read by Open today. |

Keychain secret per browser: service "<Product> Safe Storage", account "<Product>" (CS "saltysalt", "%s Safe Storage"; Open's `probeChromiumKeychainPair` already knows "Arc", "Chrome", "Chromium"). Brave, Edge, Vivaldi and Opera follow the same pattern (PUB, common importer tools; exact account names are a guess until checked against the user's Keychain by the user, never by an agent).

### 4.2 Safari

| Data | Location | Format | Access |
|---|---|---|---|
| Bookmarks + Reading List | `~/Library/Safari/Bookmarks.plist` | binary plist tree; nodes have `WebBookmarkType` (`WebBookmarkTypeList`, `WebBookmarkTypeLeaf`, `WebBookmarkTypeProxy`), `Children`, `Title`, `URLString`, `URIDictionary.title`, `WebBookmarkUUID`; special lists `BookmarksBar`, `BookmarksMenu`, `com.apple.ReadingList` | Full Disk Access. CS: "Couldn't determine Safari bookmark type (missing WebBookmarkType field).", "Unknown bookmark type … (expected: WebBookmarkTypeLeaf …)". |
| History | `~/Library/Safari/History.db` (SQLite) | `history_items(id,url,domain_expansion,visit_count,…)`, `history_visits(id,history_item,visit_time,title,…)`; `visit_time` is seconds since 2001-01-01 (PUB; field list is a guess until a permitted read) | Full Disk Access. CS: "Safari history database is unreadable for the importer." |
| iCloud tabs | `~/Library/Safari/CloudTabs.db` | SQLite (MS string) | Full Disk Access. Arc lists the path; use unknown. |
| Passwords, passkeys | iCloud Keychain / Passwords app | not readable by other apps | Only through a user export (`Passwords.csv`: columns Title, URL, Username, Password, Notes, OTPAuth — PUB guess) |
| Export archive | user-chosen file, from Safari ▸ File ▸ Export Browsing Data (Safari 18+) | ZIP with bookmarks HTML, `History.json`, `Passwords.csv`, cards and extensions lists (PUB; exact member names are a guess, verify with one user-made export) | No special permission: the user picks the file in an open panel. |
| Cookies | `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies` | Apple binary cookie format | Container data protection. Arc does not import Safari cookies. |

On this Mac, `ls ~/Library/Safari` and the Safari container both fail with "Operation not permitted" (DISK). This is the TCC Full Disk Access gate.

### 4.3 Firefox and Gecko forks

Inspected on Zen 1.24 (a Firefox fork) because Firefox is not installed (DISK).

| Data | File | Schema facts |
|---|---|---|
| Profiles | `~/Library/Application Support/Firefox/profiles.ini`, `installs.ini` | INI: `[ProfileN] Name, IsRelative, Path, Default`; `[Install<hash>] Default, Locked` |
| Bookmarks | `places.sqlite` (user_version 87) | `moz_bookmarks(id, type 1=url/2=folder/3=separator, fk→moz_places.id, parent, position, title, dateAdded, lastModified, guid, …)`; roots by guid `root________`, `toolbar_____`, `menu________`, `unfiled_____`, `mobile______` (PUB: Mozilla docs); times in microseconds since 1970 |
| History | `places.sqlite` | `moz_places(id,url,title,visit_count,hidden,typed,frecency,last_visit_date,…)`, `moz_historyvisits(id,from_visit,place_id,visit_date,visit_type,…)` |
| Form autocomplete | `formhistory.sqlite` (user_version 5) | `moz_formhistory` |
| Passwords | `logins.json` + `key4.db`; on this Zen profile also `logins.db` | `logins.json`: `{nextId, logins:[{hostname, httpRealm, formSubmitURL, usernameField, passwordField, encryptedUsername, encryptedPassword, guid, encType, timeCreated, timeLastUsed, timePasswordChanged, timesUsed, …}], version}`. `key4.db`: `metaData(id,item1,item2)`, `nssPrivate(…)` (NSS key store). `logins.db`: Rust logins store `loginsL`/`loginsM` with `secFields` (DISK). Which store is authoritative in current Firefox is a guess; read `logins.json` first, `logins.db` as fallback. Without a Primary Password, the key in `key4.db` is protected only by an empty password, so no consent dialog exists (PUB: NSS design). |
| Cookies | `cookies.sqlite` (user_version 17) | `moz_cookies(name, value, host, path, expiry, isSecure, isHttpOnly, sameSite, originAttributes, …)`; values in plain text |
| Add-ons | `extensions.json` | `{schemaVersion, addons:[{id, version, type, active, defaultLocale.name, sourceURI, …}]}`. Firefox add-ons are not Chrome extensions. |
| Open tabs | `sessionstore-backups/recovery.jsonlz4` | Mozilla LZ4 frame, magic `mozLz40\0` (DISK) |
| Lock | `.parentlock` / `lock` while running | Chromium `firefox_profile_lock.cc` (CS) |

## 5. Consent matrix

"None" means a normal (non-sandboxed) app can read the file. Each row cites the gate.

| Data | Chromium family | Safari | Firefox |
|---|---|---|---|
| Bookmarks | none (needs check for macOS data protection, §4.1) | Full Disk Access, or user-picked export ZIP | none; source must be quit (lock) |
| History | none | Full Disk Access, or export ZIP | none; quit source |
| Top sites / engagement for Favorites suggestions | none | from history | from `frecency` |
| Passwords | one Keychain prompt for "<Product> Safe Storage" per browser | not possible directly; user exports CSV (or ZIP) | none without Primary Password; with one, the user types it (Arc does not import Firefox passwords at all) |
| Cookies | same Keychain prompt | not possible | none (plain text); Arc does not import them |
| Cards | same Keychain prompt | export ZIP (guess) | not stored by Firefox on macOS in a usable form (guess) |
| Addresses / form data | none (addresses plain) / none | export ZIP (guess) | none (`formhistory.sqlite`) |
| Extensions | none: reinstall from the Chrome Web Store by ID | names only; matching to Web Store is a guess | not possible (different extension system) |
| Open tabs | none (SNSS parse) | `CloudTabs.db` needs Full Disk Access | none (`mozLz4`) |

User-only actions: grant Full Disk Access in System Settings (and usually relaunch); click "Allow" in each Keychain prompt; export Safari passwords; type a Firefox Primary Password; quit the source browser.

## 6. Needs capture (Arc)

See `F3-report.md` §3 for the exact list. In short: every import-dialog screen with Chrome and Firefox installed (synthetic data), the bookmarks tree screen, the destination-folder result in the sidebar, the Safari Full Disk Access screen and its restart choice, the Safari CSV drop zone in each state, the lock dialog, the toasts, and the onboarding `importSource`/`importBookmarks`/`topApps` steps.
