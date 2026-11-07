# Software update UI in Arc 1.170.0

Static research, 2026-11-07. Target: `/Applications/Arc.app`, version **1.170.0**, build **89123**. This report records the shipped implementation and copy. It does not propose an Open design. Arc was not launched. No desktop input, user preferences, network update feed, signing keys, or Keychain were used.

## Evidence and limits

All executable addresses below are unslid arm64 virtual addresses in `Contents/MacOS/Arc`. `FUN_<address>` identifies the function at that address in the saved analysis. Literal strings and metadata prove that a path ships; they do not prove that a remote feature flag currently enables it.

Raw receipts are in `/Users/serge/.t3/projects/open/.re/s16/update-ui/` (outside this commit). The report contains facts in our own words, plus short copy quotations. It contains no extracted assets or implementation code.

| Evidence ID | Read-only method and receipt |
|---|---|
| P | `plutil -convert json -o - /Applications/Arc.app/Contents/Info.plist`; filtered values in `bundle-keys.json`. Fat executable SHA-256: `25af5f4eaaae5aca25021f2737e90cc4d41fdf195c4a5c4012ea31a1bba4b86a`. |
| M | `source tools/rea-env.sh`; `rea inspect-native-dispatch-metadata /Applications/Arc.app`, plus Swift relative field-descriptor decoding: `swift-fields.json`. `otool -ov` and selector-pointer decoding: `objc.txt`, `updater-objc-methods.txt`. |
| N | `rea decode-interface-builder /Applications/Arc.app`; `nibs.json`, `mainmenu-nib.json`. |
| A | `rea inspect-asset-catalog /Applications/Arc.app --offset 0 --limit 1000 --format json`, repeated at offsets 1000 and 2000; `asset-catalog*.json`, filtered `update-assets.json`. Metadata only; no image extraction. |
| L | Recursive inventory of `.strings`, `.xcstrings`, and `.loctable`, with `plutil` decoding where supported: `resource-inventory.txt`, `localized-update-strings.json`; `strings -a -t x` on the arm64 executable: `thin-strings.txt`. Unicode copy was checked as UTF-8 bytes, not inferred from ASCII `strings` fragments. |
| G | Existing analyzed `ArcMain.gpr` / `Arc-arm64`, documented in [README.md](README.md), queried with `analyzeHeadless … -process Arc-arm64 -noanalysis -readOnly -postScript RangeDecomp.java …`. Receipts: `driver-views.txt`, `behavior.txt`, `surfaces.txt`, `string-functions.txt`, `copy-trace.txt`, `menu-settings.txt`, `banner-views.txt`, `banner-reducer.txt`, `remaining.txt`, `menu-final.txt`, `last-targets.txt`, `prompt-helpers.txt` and their `-annotated` variants. No import or analysis was started. After shared-project lock conflicts, queries used an APFS clone of that same saved analysis at `~/Library/Caches/OpenRE/ghidra-s16-update/ArcMain.gpr`. |
| D | `xcrun llvm-objdump --disassemble --start-address=<address> --stop-address=<address> …/.re/bin/Arc-arm64`; `toast-disasm.txt`, `menu-title-disasm.txt`, `banner-actions-disasm.txt`, `sidebar-reducer-disasm.txt`, `prompt-disasm.txt`. |

The saved analysis reports a missing Swift compiler specification under installed Ghidra 12.2 and uses its default convention. Some switch branches are absent from decompilation. Raw ARM64 instructions confirm the toast literals and the dismissal counter below. Missing decompiler references are **not** evidence that a path is absent. Window dimensions below are constraint or constructor constants, not on-screen measurements.

## Application menu and restart alert

| Finding | Evidence |
|---|---|
| The application menu contains **“Check for Updates…”**, with no keyboard equivalent. It targets `checkForUpdates:` on the application delegate. | N: MainMenu object 1337, title object 1338, target 1527; parent menu 2170 is `_NSAppleMenu`. Key `si6-nh-Kht.title`. M: `AppDelegate.checkForUpdates:` at `0x100236d10`. |
| The search aliases are **“Download; Update; Check for Updates”**. | N: `si6-nh-Kht.ibExternalUserDefinedRuntimeAttributesLocalizableStrings[0]`. |
| The title becomes **“Update Available…”** when there is an available update or a simulated restart. Otherwise it is **“Check for Updates…”** if `canCheckForUpdates` is true, and **“Updating…”** if false. | G/D: title builder `0x1002373c4`; availability helper `0x102e8863c`. `SoftwareUpdate.State` fields at M `0x103e6ef60`; simulation byte `+0x60`, check byte `+0x61`. |
| Menu validation updates the title and, on macOS 14+, sets or removes an `NSMenuItemBadge` from an update-availability Boolean. It returns enabled on the normal `checkForUpdates:` path even when the title is “Updating…”. Thus `canCheckForUpdates` is not itself a disable rule here. | G: `0x1002361c4`, selector `0x10449b3c8`, title key path `0x103656b08`, badge key path `0x103656b28`, final return through `0x100236234`. |
| That validator returns disabled without its view store, without an action, or when the earlier application-wide gate at `0x10202f4d8` is true. **Unresolved:** the exact meaning of that global gate. | G: `0x1002361c4` before its selector branches. No update-specific hidden rule appears in the inspected branch. |
| A separate restart confirmation uses title **“Arc is ready to update!”**, message **“Restart required.”**, and buttons **“Restart”** / **“Cancel”**. | G: AppReducer `0x100115054`, literal use near `0x100119194`; comments “Update available dialog title.”, “Update available dialog message.”, “Update available confirm button title.”, “Update available restart cancel button title.” |
| Debug simulation support ships. Literal copy includes **“Simulate Software Update”**, **“Update available”**, and **“Auto Update complete”**. **Unresolved:** exact debug submenu placement and enabled/hidden conditions. | L: executable strings; M: lazy `debugSoftwareUpdateMenuItem` field; `SharedAppFeature.DeveloperMainMenu.Action.SidebarBannerSimulation.SoftwareUpdateSimulation`. These do not establish public menu visibility. |

The validator result above describes the inspected application delegate path. It does not establish that every app lifecycle state can perform a new check. The manager also has `checkForUpdatesInBackground`, `installAndQuit`, `canInstallAndQuit`, `lastUpdateCheckDate`, and `setMinimumVersionRequirementMode` entry points (M/L: `SoftwareUpdaterClient.SoftwareUpdateManager`).

## Sidebar banners

| Surface / condition | Copy and actions | Evidence |
|---|---|---|
| Legacy available-update banner | **“Arc is ready to update!”**; narrow title **“An update is ready!”**; **“Click to restart”**. A channel-specific variant says **“Early Birds update ready!”**. | G: builder `0x102e36d80`; M: `SoftwareUpdateBannerUpdateAvailableView`, accessor `0x102575480`. Channel comparison is integer 3, not evidence that the installed stable build uses it. |
| V2 available-update banner | **“New Arc Version Available”**; action **“Restart and Update”**. Its expanded view contains **“Automatic Updates”**, with checked/unchecked square symbols, and a dismiss control using `xmark`. | G: `0x102e36d80`, `0x10258534c`, `0x102583d9c`; M: V2 view accessor `0x10258942c`; state contains `autoUpdateEnabled` and `autoUpdateFeatureEnabled`. |
| Legacy update-summary banner | **“Arc Updated!”**; narrow **“Updated!”**; release notes **“What’s New”**, narrow **“What’s new”**; optional referral action **“Share Arc”**. | G: builder `0x102e370cc`; `0x100cc9ae8` → initializer `0x100cc9ac0`; M: summary view accessor `0x10257456c`. |
| V2 update-summary banner | The builder can use **“Update Complete!”**; otherwise **“Arc Updated!”**. Release notes action **“See What’s New”**; optional referral action **“Gift Arc”**. | G: `0x102e370cc` branches on new-summary and update-kind inputs; `0x100cc9c1c` → `0x100cc9b48`. M: V2 summary accessor `0x102593160`. Exact caller Boolean meaning for “Update Complete!” remains **unresolved**. |
| Channel-specific summary | **“Early Birds Updated!”**; narrow **“Early Birds\nUpdated!”**. | G: `0x102e370cc`, channel 3 comparison. `\n` here denotes a line break. |
| Summary links | Separate actions open release notes, a referral code, and a video-series link. The summary carries `videoSeriesTitle` and `videoSeriesURL`; the title is supplied to the builder, not fixed in it. Both summary views have `ReleaseNotesType.video` / `.text`. | M: summary state descriptor/accessor `0x102555f04`, actions at `0x103e57bb0`, release-note type descriptors `0x103e583ac` / `0x103e58a64`; G: builder `0x102e370cc` arguments. |
| Shared sidebar presentation | Banner state contains `content`, `presentationState`, `isHovered`, and both new-banner flags. Presentation states are `initial`, `appeared`, `dismissing`. The container is `SidebarBannerContainerView`. | M: descriptors `0x103e57a10`, `0x103e57d48`, `0x103e5803c`. **Unresolved:** exact vertical anchor, pixel frame, and spacing within the sidebar. The type name alone does not prove “top” or “bottom”. |
| Available-banner input paths | Actions include `preferredAnimationChanged`, `didClickBanner`, `didClickDismiss`, `didToggleEnableAutoUpdate`, and `didClickUpdate`. | M: action descriptor `0x103e57b64`; G: SidebarBanner reducer `0x10254d69c`. |
| Dismiss sources | Analytics distinguishes banner type `updateAvailable` / `updateSummary` and source `auto` / `button`. Hover/unhover and auto-dismiss cancellation types ship. | M: descriptors `0x103e11b28`, `0x103e11b50`, `0x103e57a9c`, `0x103e57ffc`. This establishes named paths, not an observed dismissal delay. |
| Summary eligibility | State distinguishes `pending(Date)`, `awaitingAppSetup`, `ineligible`, `eligible`. A pending date is accepted when its interval from now is at most 10 seconds; the other branch makes it ineligible. | M: `0x103e6efb8`; G: `0x102e369b4` tests `timeIntervalSince <= 10.0`, then stores eligible/ineligible tags. |
| Banner replacement / dismissal | App integration has explicit banner equality/replacement and clear-state paths. A delegate `dismiss` calls the clear helper. | G: `SharedAppFeature/AppData+SidebarBanner.swift`, `0x102e35218`, `0x102e35d68`; D: delegate switch table `0x102e86fd8`, `dismiss` branch `0x102e86384` → `0x102e35d68`. |

**Limit:** a complete eligibility predicate for each banner, all hover timing, and all suppression rules were not recovered. Do not convert the state names into a claim that every downloaded update always shows a banner. The 15-second flag below is called a **sparkle timeout**; it is not proof of a 15-second banner lifetime.

## Toasts

The enum `Toasts.SoftwareUpdaterToastType` has five cases (M: field descriptor `0x103e30570`, accessor `0x1018f6038`). The text below is compiled into the executable. The error description in the custom updater alert is a different surface.

| Case | Full bundled copy | Evidence |
|---|---|---|
| `failedToDownloadUpdate` | **“Something went wrong downloading the update to {product}.\nWe’ll try again later…”** | Prefix C string `0x1039da730`, suffix `0x1039da760`; D: loads at `0x1018eef14` / `0x1018eef4c` and alternate builder `0x1018f153c` / `0x1018f1574`. `{product}` denotes inserted content, not a literal key. |
| `updateAlreadyInProgress` | **“Update in progress. Hang tight!”** | C string `0x1039da780`; D: `0x1018eef68`, `0x1018f159c`. |
| `failedToInstall` | **“Something went wrong installing a new update.\nWe’ll try again later…”** | C string `0x1039da6b0`; D: `0x1018ee15c`, `0x1018f123c`. |
| `cancelledInstall` | **“Restart at a later time to finish installing the new update!”** | C string `0x1039da640`; D: `0x1018eefb4`, `0x1018f15e8`. |
| `newUpdatePending` | **“A new update is pending! It will be ready soon”** | C string `0x1039da5e0`; D: `0x1018eeb48`, `0x1018f1400`. |

`\n` means an actual line break. **Unresolved:** toast duration, exact position, and every trigger predicate. The enum/copy match does not prove that all five can occur with the current server configuration.

## Custom Sparkle driver

The executable supplies `SoftwareUpdaterClient.CustomUserDriver : SPUUserDriver`. Sparkle is **2.9.4**, from `Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist`. The following mappings come from the Objective-C method list and their bodies, not from stock Sparkle documentation.

| SPUUserDriver callback (Objective-C selector) | Arc behavior | Evidence: IMP → implementation |
|---|---|---|
| `showUpdatePermissionRequest:reply:` | Assertion says this should never be called because `SUEnableAutomaticChecks` is set. No permission dialog is built on this path. | `0x101f21938` → `0x101f24730`. |
| `showUserInitiatedUpdateCheckWithCancellation:` | Custom `UpdaterStatusController`, centered, indeterminate progress; **“Checking for updates...”**, **“Cancel”**; cancellation is stored. | `0x101f21ed4`, body `0x101f2199c`. |
| `dismissUserInitiatedUpdateCheck` | Closes and clears the checking controller. | `0x101f220b0` → `0x101f21ef0`. |
| `showUpdateInFocus` | Brings existing custom updater/status controllers forward. | `0x101f22314` → `0x101f220d8`. |
| `showUpdateFoundWithAppcastItem:state:reply:` | Custom `UpdaterWindowController` with appcast item and user-update state. | `0x101f22848`, body `0x101f2233c`. |
| `showUpdateReleaseNotesWithDownloadData:` | No-op. | `0x101f228fc`, single return. |
| `showUpdateReleaseNotesFailedToDownloadWithError:` | No-op. | `0x101f22900`, single return. |
| `showUpdateNotFoundWithError:acknowledgement:` | Custom up-to-date window and acknowledgement callback. | `0x101f229d0` → `0x101f24968`. |
| `showUpdaterError:acknowledgement:` | `NSAlert`: **“Update error!”**, error's localized description, **“OK”**, **“Download manually”**. Second button opens the manager's manual-download URL. | `0x101f22a5c` → `0x101f24d20`. |
| `showDownloadInitiatedWithCancellation:` | Replaces checking with custom download status. Stores cancellation in `onClose`. | `0x101f22d9c`, body `0x101f22ad8`, shared controller helper `0x101f22cd4`. |
| `showDownloadDidReceiveExpectedContentLength:` | Sets maximum progress from expected bytes. | `0x101f22f94` → `0x101f22db8`. |
| `showDownloadDidReceiveDataOfLength:` | Updates received bytes and label **“%@ of %@”** with `ByteCountFormatter`. | `0x101f23468` → `0x101f22fc4`. |
| `showDownloadDidStartExtractingUpdate` | **“Preparing…”**; clears close cancellation, disables the button, sets maximum 1 and indeterminate progress. | `0x101f23830` → `0x101f23498`; small UTF-8 literal includes Unicode ellipsis. |
| `showExtractionReceivedProgress:` | Updates custom progress value. | `0x101f2393c` → `0x101f23858`. |
| `showInstallingUpdateWithApplicationTerminated:retryTerminatingApplication:` | Custom status **“Installing update... ”**; indeterminate progress. The inspected wrapper does not present a retry-termination button. | `0x101f23974` → `0x101f2530c`; the literal has one trailing space. |
| `showReadyToInstallAndRelaunch:` | **“Ready to Install”**; full progress, enabled **“Install and Relaunch”** action with the supplied reply, and an application attention request. | IMP `0x101f23eb4`; body `0x101f239c0`. Wrapper is a shared closure thunk. |
| `showSendingTerminationSignal` | Clears the download controller's close callback. | `0x101f24080` → `0x101f23ed0`. |
| `showUpdateInstalledAndRelaunched:acknowledgement:` | Logs installed/relaunched state and acknowledges. No completion window is created in this callback. | `0x101f240a8` → `0x101f2568c`. |
| `dismissUpdateInstallation` | Closes and clears the custom controllers. | `0x101f24350` → `0x101f2410c`. |

**Standard-UI fallback:** none was found in these callback implementations. They use custom controllers, `NSAlert`, no-op, or assertion paths. `SPUStandardUserDriver` was not found in the main executable's inspected class/string metadata. Sparkle's shipped strings and resources do not prove fallback use. This statement does not exclude independent helper/system permission UI during installation.

## Updater window and release notes

| Finding | Evidence |
|---|---|
| `UpdaterWindowView` has `hasUpdate` and `upToDate` display styles. It contains an image, product title, version label, current-version prompt, primary and secondary buttons, background, and an optional release-notes panel. | M: `SoftwareUpdaterClient.UpdaterWindowView` fields; G: `0x101f3107c`. |
| Up-to-date copy is **“Your browser is up to date”**, with **“Close”**. | G: `0x101f32498`, primary builder `0x101f31fb8`. |
| Available-update primary action is **“Download”** when `SPUUserUpdateState.stage == 0`, otherwise **“Install and Relaunch”**. Secondary action is **“Remind me Later”** (capital L). | G: `0x101f31fb8`, selector stub `0x103608220` resolves to `stage`; `0x101f32984`. |
| The full available prompt template is **“You have v{installed-version-label}.\nWould you like to download\n v{display-version} ({bundle-version}) now?”**. Both `v` prefixes touch the following version. The space after the second line break is present. | D: `prompt-disasm.txt`, `0x101f32510`–`0x101f32618`, including a nested string buffer at stack `+0x10`; G: `0x101f32498`, helper `0x101f181f0`; M: `AppUpdate` fields `title`, `bundleVersion`, `displayVersionString`. |
| For that template, the new display version is taken unchanged unless it contains both parentheses; then the helper takes its first space-separated component (or “-” if empty). The installed-version label is built by the bundle version helper and can include a parenthesized build and channel suffix. | G: `prompt-helpers.txt`, `0x101f181f0`, `0x1005a6a30`. Placeholders are variable content, not literal lookup keys. |
| Minimum-version mode hides the Later button and removes the normal close style bit (`0x8001` rather than `0x8003`); it also changes window-level handling. | G: `0x101f2233c`, `0x101f32984`. No claim about its trigger policy or managed deferral count follows from this. |
| Release notes title uses the nonempty appcast title, else **“A new version is available”**. The title is selectable and uses bold system 14 pt. | G: `ReleaseNotesView` label builder `0x101f2f470`. |
| Notes use a `WKWebView` with appcast HTML. Empty content has **“Thanks for using {product}!”**. The two release-note download callbacks above are not the path that fills this view. | G: `0x101f2f6b4`; HTML prefix literal at `0x1039f4fb0`; item is carried into `ReleaseNotesView`. |
| Notes styling uses system 12 px text; light text RGB (20,20,20), white body; dark mode white text and black body; links `#458AFF`; list-item line height 20 px; body margins top/right/bottom/left 12/8/16/0 px, padding zero. | G: HTML styling literal referenced by `0x101f2f6b4`. Values only, no copied HTML/CSS implementation. |

## Geometry, colors, and icon names

| Fact | Evidence |
|---|---|
| Custom status window content rect is **270 × 334 pt**. Constructor sets level 3, hides on deactivate, uses transparent titlebar and background dragging. | G: `0x101f33bbc`. |
| The updater's left column is constrained to **270 pt**. Optional notes panel is **398 × 394 pt**, inset **12 pt** from top, bottom and trailing edges, with a **12 pt** column gap. | G: `0x101f3107c`, `widthAnchor` / `heightAnchor` constants. These are component sizes, not a claim that the entire update window is 270 × 334. |
| Notes panel corner radius is **10 pt**; heading has **32 pt** horizontal inset and **20 pt** top inset. | G: `0x101f2f848`. |
| `ARC_SoftwareUpdaterClient.bundle/Contents/Resources/Assets.car` has one named color, **`UpdaterButtonBackgroundColor`**: sRGB RGBA **(1,1,1,1)** normally, **(0,0,0,1)** for DarkAqua. There is no updater image rendition in that catalog. | A: `update-assets.json`, catalog SHA-256 `ed0b1403709760f8eee07358c9a84cc48cff713c536dc70f7778890a11534d5a`. |
| Sidebar update view functions reference system-image names **`heart`**, **`play.square`**, **`heart.circle.fill`**, **`play.circle.fill`**, **`play.rectangle`**, **`gift`**, **`sparkle`**, **`xmark`**, **`checkmark.square`**, **`square`**. An animation resource is named **`update-heart-animation`**. | G/L: `surfaces-annotated.txt`, `banner-views-literals.txt`; `0x102577a54`, `0x102577aec`, `0x102583d9c`, `0x10258534c`, `0x102586638`. These are system/resource names, not files to copy. |
| Sidebar view fields depend on a color palette; V2 also reads color scheme. Exact resolved banner colors are **unresolved**. | M: legacy/V2 view descriptors `0x103e5831c`, `0x103e585f4`, `0x103e589fc`. |
| A separate shared catalog contains `ArcUpdatesArcLogo` (75 × 68 px at 1×, 149 × 136 at 2×, plus vector rendition) and `ArcUpdatesGradient` (498 × 183 px, sRGB and P3 variants). Their use by the Sparkle updater window is **not established**. | A: `ARCUI_ARCUI.bundle/Contents/Resources/Assets.car`, `update-assets.json`. Do not use these dimensions as updater-window geometry. |

## Copy keys and localization files

For `_NSLocalizedString` calls below, the **English text itself is the lookup key**, table is nil (default `Localizable`), and bundle is `NSBundle.main`. Translator comments such as “Update available dialog message.” are **not lookup keys**. SwiftUI `LocalizedStringKey` also uses the shown English key. Plain compiled literals have no proved string-table key.

| Surface | Keys / source of copy | Evidence |
|---|---|---|
| Application menu | `si6-nh-Kht.title` → “Check for Updates…”; alias key listed above. Dynamic labels are compiled literals: “Check for Updates…”, “Update Available…”, “Updating…”. | N; G `0x1002373c4`, `0x1002361c4`. |
| Restart alert | `Arc is ready to update!`; `Restart required.`; `Restart`; `Cancel`. | G `0x100115054` near `0x100119194`, main-bundle localization calls. |
| Available banners | `Arc is ready to update!`; `An update is ready!`; `Click to restart`; `Early Birds update ready!`; `New Arc Version Available`; `Restart and Update`. | G `0x102e36d80`. |
| Summary banners | `Arc Updated!`; `Update Complete!`; `Updated!`; `Early Birds Updated!`; `Early Birds\nUpdated!`; `What’s New`; `See What’s New`; `What’s new`; `Share Arc`; `Gift Arc`. | G `0x102e370cc`, `0x100cc9ac0`, `0x100cc9b48` / `0x100cc9b6c`. |
| Banner auto-update row | `Automatic Updates` (SwiftUI text). | G `0x10258534c`. |
| Checking, status, window | `Checking for updates...`; `Cancel`; `%@ of %@`; `Preparing…`; `Ready to Install`; `Install and Relaunch`; `Installing update... `; `Download`; `Close`; `Remind me Later`; `Your browser is up to date`. | G callback/label builders cited above. The trailing space in the installing key is intentional in this transcription. |
| Error alert | `Update error!`; `OK`; `Download manually`; informative message from `error.localizedDescription`. | G `0x101f24d20`. |
| Available-window prompt | Full assembled template in the window table above; no separate localization key was established for its fragments. | G/D: `0x101f32498`, `prompt-disasm.txt`. |
| Release notes | `A new version is available` fallback title; appcast title and HTML are variable content. HTML fallback uses “Thanks for using ” + product + “!”. | G `0x101f2f470`, `0x101f2f6b4`. The HTML fallback is compiled content, not a proved lookup key. |
| Settings | `Automatically update my Arc` (SwiftUI key); `Learn more about auto-updating` (localized tooltip). | G `0x10200bd08`; English keys `0x1039f8150` / `0x1039f8170` in Swift string representation. |
| Toasts | Full copy is in the five-case table above. **Unresolved:** a separate localization lookup key for each toast. English C strings are proved. | L/D: toast addresses above. |

| Resource inventory result | Evidence |
|---|---|
| `ARC_SoftwareUpdaterClient.bundle` contains assets and bundle/signature metadata, but no `.strings`, `.xcstrings`, or `.loctable`. | L: recursive inventory, `resource-inventory.txt`. |
| No `.xcstrings` or `.loctable` was found by the bundle-wide inventory. Other bundles do ship `.strings`. | L: recursive scan; `localized-update-strings.json`. |
| Top-level translated `MainMenu.strings` files contain sparse IB overrides; for example en-GB contains Edit and Copy only. No update/restart override was found in the decoded scan. The base nib is the evidence for the English update menu entry. | L/N. Some bare-key IB `.strings` syntax is not accepted by `plutil`; text was checked separately. This is not a claim that every locale was rendered. |
| `Settings_Settings.bundle` ships localized tables, but the inspected update/restart text scan did not find these custom Arc auto-update row strings there. The executable builder proves the row. | L plus G `0x10200bd08`. |
| Sparkle ships its own localized `Sparkle.strings`, including stock keys “Software Update”, “Check for updates automatically?”, “Install and Relaunch”, “Automatically download and install updates”, and “Update Error!”. These differ from some custom copy (for example “Update error!”). | L: `Contents/Frameworks/Sparkle.framework/Versions/B/Resources/*.lproj/Sparkle.strings`; 36 matching decoded tables in `localized-update-strings.json`. Presence does not prove those stock dialogs are shown. |

## Settings and persistence

| Finding | Evidence |
|---|---|
| Settings contains **“Automatically update my Arc”**, with help text **“Learn more about auto-updating”**. Existing research places it in General / App. | G: row builder `0x10200bd08`, parent `0x10200bb54`, help action `0x102011450` → `0x10200be9c`; [features-core.md](features-core.md), General pane table. **Unresolved:** final help URL and complete toggle-to-default binding. |
| Do not treat Sparkle's `SUAutomaticallyUpdate=true` as proof that the separate Settings toggle's initial value is ON. | P proves the Sparkle setting; M has distinct Arc automation keys below. The older General table's “Proven-ish” ON assertion is insufficient to bind them. |
| Dismissing can persist an auto-update-banner dismissal count. Raw instructions read key **37**, `autoUpdateBannerDismissalCount`, and later store the prior value plus one to key 37. The same branch reads key **35**, `automaticallyUpdateArc`, and reaches the increment when that Boolean is false. | D: `0x10254f630` read, `0x10254f66c` read, `0x10254f838` conditional branch, `0x102550228` increment and `0x102550234` key for write. M: `ArcUserDefaultSettings` field order `0x103de34ec`; G: key-name conversion `0x1005a4098`. |
| **Unresolved:** the complete dispatch predicate into that counter branch, its threshold, and whether all legacy/V2 button/automatic dismissals reach it. | D: `sidebar-reducer-disasm.txt`, branch at `0x10254f5b8`. The read/write is certain; assigning it to every dismiss source would be a guess. |
| App delegate dismissal clears the current banner state. This alone is not a persistent “never show again” choice. | D `0x102e86384` → G `0x102e35d68`, which writes a nil optional banner state. |

The following names are **registered default keys**, not evidence that each is written by a banner dismissal. Evidence for every row: M `ArcUserDefaultSettings` descriptor `0x103de34ec`, G string conversion `0x1005a4098`, L `thin-strings.txt`.

| Group | Exact keys |
|---|---|
| Update automation / age | `automaticallyUpdateArc`, `shouldAutomaticallyUpdateArc`, `shouldAutomaticallyUpdate`, `autoUpdateBannerDismissalCount`, `currentUpdateAvailableSince`, `currentUpdateDownloadedSince`, `mostRecentUpdateDownloadTime` |
| Relaunch / checking | `softwareUpdaterWillRelaunchApp`, `automaticUpdateWillRelaunchApp`, `softwareUpdaterLastUpdateCheckDate`, `windowsUpdateRestartInProgress` |
| Installed-version accounting | `firstLaunchAfterUpdatedFromVersion`, `lastInstalledAppVersion`, `lastInstalledSemanticVersion`, `lastUpdateWasAutoUpdate`, `lastUpdateWasInstalledOnQuit` |
| Banner / simulation | `canShowUpdateBanner`, `forceShowUpdateBanner`, `displayedUpdateVersion`, `simulateVersionUpdate`, `simulatedLastInstalledSemanticVersion`, `lastVersionUpdateWasSimulated`, `forceUpdatesAvailableForTesting`, `updateChannelOverride` |
| Managed deferral | `managedUpdateDialogDeferCount`, `managedUpdateDialogDeferUpdateVersion` |

**Unresolved:** whether dismissing a summary writes `displayedUpdateVersion`, changes `canShowUpdateBanner`, or has another version-scoped persistence rule. These names are leads, not proved dismissal semantics. No user defaults were read or changed.

## Sparkle Info.plist configuration

All rows are facts from P, `Contents/Info.plist` in this exact build.

| Key | Value |
|---|---|
| `SUFeedURL` | `https://releases.arc.net/updates.xml` |
| `SUEnableAutomaticChecks` | `true` |
| `SUAutomaticallyUpdate` | `true` |
| `SUScheduledCheckInterval` | `28800` seconds (8 hours) |
| `SUPublicEDKey` | Present, nonempty public Ed25519 verification key. Value omitted because its content does not affect UI. |

No other top-level `SU*` Info.plist key was present in the filtered inventory. This does not establish whether Sparkle persists additional preferences at runtime.

## Feature flags

These are **compiled metadata defaults**, not a readout of active remote/user flags. Evidence for all rows: `SoftwareUpdateFeatureFlags` constructor `0x1013f5734`; getters around `0x1013f54f4`–`0x1013f5700`; M `FeatureFlagMetadata` field order at `0x103e23c40` is `id`, `default`, `canaryDevValue`, `requiresRestart`.

| Flag ID | Compiled default | Scope proved by metadata / call sites |
|---|---|---|
| `software-update-relaunch-animation-enabled` | `false` | Relaunch-animation flag. |
| `software-update-relaunch-animation-exit-duration` | `0.35` | Animation duration parameter. |
| `software-update-relaunch-animation-enter-duration` | `0.6` | Animation duration parameter. |
| `software-update-relaunch-animation-enter-shimmer-duration` | `0.45` | Shimmer duration parameter. |
| `new-update-summary-banner-enabled` | `false` | Stored in sidebar state; controls summary builder's new copy / view path. |
| `new-update-available-banner-enabled` | `false` | Stored in sidebar state; old and V2 available content types ship. |
| `update-complete-sparkle-timeout-in-seconds` | `15` | Summary state carries `sparkleTimeout`; default data at `0x103734480` is integer 15. Not proof of auto-dismiss duration. |

For the Boolean entries, initialization bytes after the 16-byte ID are `00 02 00`: default false, optional Boolean canary override nil, requiresRestart false. Numeric entries have no canary override and requiresRestart false in this constructor. **Unresolved:** remote rollout values, the separate auto-update-feature gate, and the exact animation curve and final composed banner colors.

## Research boundary

The menu labels, custom-driver callbacks, bundled English copy, component constraints, asset names, Info.plist configuration, flag metadata, and one persistent counter write are established statically. Exact sidebar placement, full eligibility/suppression predicates, summary dismissal persistence, dynamic appcast/video content, and the debug submenu gate remain open. No runtime or visual acceptance is claimed. No Open implementation, build, or test was needed for this docs-only research change.
