# Arc page chrome: static evidence

Target: Arc **1.170.0 (89123)**, arm64. Research date: 2026-11-05.
This is a research handoff for Section 11. It makes no Open design decisions.
Arc was not launched. No desktop input, App changes, engine changes, or tests
were made.
The project-root evidence directory below is
`/Users/serge/.t3/projects/open/.re/`; it is separate from this Git worktree.

**FACT** means that the cited metadata, resource, or traced code proves the
specific statement. A resource's existence proves its text, not that a menu
or dialog displays it. **GUESS** marks an inference. Unsettled requests are
listed as open questions, with the capture needed to answer them.

## Evidence and limits

| Evidence | Source and method |
|---|---|
| Main / Core | `.re/bin/Arc-arm64`, `.re/bin/ArcCore-arm64` in the project root. `strings`, `nm -n` plus `xcrun swift-demangle`, and `otool -ov`. Addresses below are unslid main-binary virtual addresses unless stated otherwise. |
| Code | Existing `~/Library/Caches/OpenRE/ghidra/ArcMain.gpr`, program `Arc-arm64`, opened with `-process Arc-arm64 -noanalysis -readOnly`. No import or analysis pass. Read-only postScripts live in `~/Library/Caches/OpenRE/ghidra-scripts-s11/`, outside dot folders. |
| Raw results | `.re/section11/page-chrome/` in the project root. `ghidra-find-dialogs.txt`, `ghidra-layout-js.txt`, `ghidra-fieldrefs.txt`, `ghidra-helpers.txt`, and the later focused batches named below. `binary-sha256.txt` identifies both input slices. Nothing in this directory belongs in Git. |
| Swift fields | The main binary's `__swift5_fieldmd`, `__swift5_types`, and `__swift5_proto`; decoded locally. Fields identify ownership and available states, not active runtime branches. |
| Colors | Saved `assetutil -I` JSON under `.re/design/`. Bundle names below distinguish identically named colors. Assets were read, not copied or reused. |
| Engine English text | `/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Versions/A/Resources/en.lproj/locale.pak`. Read-only DataPack decoding; `locale-en.json` records resource ID, file offset, and text. Resource-ID order is **not menu order**. `&` in this resource is a mnemonic marker. |
| Existing captures | Read 3,107 saved `ax.json` files under `.re/runtime/sessions/`; found 153 nonempty AX menu nodes. Targeted searches found Settings' Clear Browsing Data row, but no find controls, page/link/image menus, permission prompt, download row, or JavaScript dialog. Other sheets in those captures are unrelated. See `runtime-hits.json` and `runtime-menus.json`. |

The environment script currently names an older Ghidra installation. These
queries sourced `tools/rea-env.sh`, then used
`GHIDRA_INSTALL_DIR=/opt/homebrew/opt/ghidra/libexec`. Ghidra 12.2 reported a
missing `AppleSilicon/swift` compiler specification and used its default
specification. Constants, selectors, resource text, and call targets below
are checked directly; uncertain decompiler types or branches remain open.
Logs end by discarding changes to the read-only program.

Existing coverage: [downloads and Site Control](features-advanced.md),
[menus and shortcuts](menus-and-hotkeys.md),
[saved interaction states](interaction-states.md), and
[capture-session limits](capture-session-2-results.md).
This report adds detail and narrows claims that those sources did not prove.

## 1. Find in page

### Frame and contents

| Status | Finding | Evidence |
|---|---|---|
| FACT | The find bar is an AppKit `NSView`, `Arc.FindInPageView`. It uses `NSTextField`, `NSStackView`, native buttons, and a `CALayer` separator. It is owned by each `WindowContentViewController`, rather than by the sidebar. | ObjC class metadata; Swift fields `Arc.FindInPageView`, `WindowContentViewController._findInPageView`; `0x10032aca4`, `0x100424b14`. |
| FACT | It sits at the **top-right of the page content container**, right inset **10 pt**. Its left edge must stay at least **10 pt** inside the controller's view, at priority **750**. Preferred width is **300 pt**, at priority **250**, so this is not a hard minimum width. | `0x100424b14`: right/top/left/width constraints; `ghidra-fieldrefs.txt`. |
| FACT | The top inset is **10 pt** normally. It becomes **50 pt** if a content panel exists, or if the page's top-bar view is attached to a superview. These offsets are relative to the page container, not the outer window or traffic lights. | `0x10040c02c` updates constraint key 3; `0x100424b14` creates that top constraint. |
| FACT | Height is **32 pt**. Layer corner radius is **5 pt**. The background is a catalog color painted into the layer; the traced find view does not create a visual-effect material. | `0x10032aca4` height constraint; `0x10032be90` background/radius; background accessor `0x100bd7e24` → initializer `0x100bd7c9c`. |
| FACT | The background token is **BaseAssets `PopoverBackground`**: Display P3 light `(0.980, 0.984, 1, 1)`, dark `(0.082, 0.110, 0.188, 1)`. | `0x100bd7c9c`; `.re/design/assetutil_Contents__Resources__ARCClients_BaseAssets.bundle__Contents__Resources__Assets.car.json`. |
| FACT | The shadow uses BaseAssets `PopoverShadow`: P3 `(0.082, 0.110, 0.196, 0.30)` light / alpha `0.80` dark. The shadow preset is blur **5 pt**, offset **(0, −3 pt)**. | `0x10032aca4` → `0x100be547c` / `0x100bd8074`; tuple at `0x1036baf80`; color initializer `0x100bd7ee4`; BaseAssets catalog. |
| FACT | Left-to-right content order is search icon, query field, result count, previous, next, close. The count's three labels are current ordinal, **`/`**, total, with zero stack spacing. Thus the format is **`1/5`**, not `1 of 5`. | `0x10032a0d4`, `0x10032a1dc`, `0x10032aca4`; count updates `0x10032a530`. |
| FACT | Query leading inset is **32 pt**; query trailing edge is **4 pt** before the results container. Search image view is **26 × 26 pt**, leading inset **3 pt**, vertically centered; glyph size **15 pt**. Close is centered vertically, **3 pt** from the trailing edge. | `0x10032aca4`, `0x100329b50`. |
| FACT | Previous/next/close glyph size is **16 pt**, with **5 pt** button insets. Their source is the custom icon-font path, not a recovered SF Symbol name: previous U+E914, next U+E90C, close U+EA11; search U+E9CC. These code points identify evidence, not assets Open may reuse. | `0x100329c6c`; initializers `0x100be6d2c`, `0x100be696c`, `0x100bee3c4`, `0x100bec36c` → `0x100bee79c`; `icomoon.ttf` cmap metadata. |
| FACT | The separator is **1 pt** wide, at close-button minX minus **1.5 pt**, with **7 pt** vertical insets. It is hidden when the results container has no content. `FindInPageSeparator` is P3 black at 10% alpha, with no dark variant in the catalog. | `0x10032bfac`, `0x100329ac8`, `0x100bd980c`; BaseAssets catalog. |
| FACT | The query field has no bezel, background, or focus ring; it is single-line, horizontally scrollable, and does not wrap. | `0x100329dfc`: `setBezeled`, `setDrawsBackground`, `setFocusRingType`, cell scrolling/wrapping. |
| FACT | In the default system `FontSet`, the query uses **13 pt system regular** (`label`); count and Not Found use the **12 pt system small-caps** font (`smallCaps`). The small-caps transform preserves point size and enables lower/upper-case small caps. This is the default font configuration, not a runtime font measurement. | Query getter `0x100d9359c`, key path `0x1036da218` (stored field offset 0); result getter `0x100d93edc`, key path `0x1036da318` (offset 64); `FontSet` field order; initializer `0x100d92aac`; transform `0x100a036c4` sets CoreText features 37/38, selector 1. |
| FACT | Exact placeholder: **`Find in page...`** (three ASCII periods). Exact no-result label: **`Not Found`**. The text `No results found, find in page` is the localization **comment**, not the label. | `0x100329dfc` and `0x10032a354`; comment strings `0x103958d00`, `0x103958d20`. |
| FACT | `Not Found` uses `FindInPageError`: P3 `(0.788, 0.200, 0.200, 1)`, with no dark override. No-result presentation replaces the count/navigation content; an empty query has a separate empty state. The traced code colors the no-result label; it does not prove the query itself turns red. | `0x10032a354` → `0x100bd974c` → `0x100bd95bc`; `ResultType` cases `results`, `noResults`, `empty`; `0x10032a530`, `0x10032bca8`; BaseAssets catalog. |
| FACT | Count and button tint use **ARCUI `PopoverInputText`**: P3 `(0.055, 0.059, 0.063, 0.80)` light / `(0.980, 0.984, 1, 0.90)` dark. | `0x10032c750`, `0x10032aca4` → `0x100a69c74` → `0x100a69aec`; ARCUI catalog. |
| FACT | Query text uses BaseAssets **`ForegroundPrimary`**: P3 `(0.05490, 0.05882, 0.06275, 0.90)` light; sRGB white at `0.80` alpha dark. | `0x100329dfc` → `0x100bd699c` → `0x100bd6814`; BaseAssets catalog. |

### Keys, focus, and state

| Status | Finding | Evidence |
|---|---|---|
| FACT | Cmd+F = Find…, Cmd+G = Find Next, Cmd+Shift+G = Find Previous. These are native menu actions through `arc_performFindPanelAction:`. | MainMenu nib, Find submenu; [menu report](menus-and-hotkeys.md). |
| FACT | Within the query field, Esc sends dismissal; Return requests the next result; holding Shift changes Return to previous. Up and Down also request previous and next. The delegate consumes these selectors. | `0x10032c9a8`: `cancelOperation:`, `insertNewline:`, `moveUp:`, `moveDown:`; `0x10032c494`; `flagsChanged:` at `0x10032c52c` checks Shift bit 17. |
| FACT | Invoking Find while already editing the query selects all query text for the Find action (menu-item tag 1); other Find actions pass along the responder chain. | `0x10032b884`. |
| FACT | Presentation binds the view store and sets `isHidden = false`; dismissal clears that binding and sets `isHidden = true`. No animation is called in these two handlers. This is evidence for the traced native-find path, not a measured animation duration. | `0x10041bdf4`, `0x10041bfa4`. |
| FACT | State is tied to a `webContentFrameID`; view state has `windowID`, `contentID`, `spaceID`, query, total, and active ordinal. The responder registration carries `windowID` and `contentID`. | Swift fields `WindowContents.FindInPage.State`, `.ViewState`, `Arc.FindInPageView.ResponderInfo`; registration `0x10032bb9c`. |
| FACT | Begin-find can seed the query from selected page text after replacing newlines with spaces and trimming whitespace, when the resulting selection is at most **40 characters**. | `0x1020f3690`: selection read, newline replacement, trim, `String.count < 0x29`. |
| FACT | Analytics names are not placement modes: `FindInPageSource` = `webPage`, `assistant`, `unknown`; `FindInPageEntryPoint` = `menuItem`, `keyboardShortcut`, `unknown`; `FindInPageButton` = `next`, `previous`. Assistant-related state is not a requirement for Open. | Swift enum fields under `AnalyticsClient.AnalyticsEventProperties`. |
| GUESS | In Split View, the bar belongs to the selected pane's content controller. Per-pane ownership and frame IDs support this, but they do not prove which pane a global Cmd+F action selects after every focus change. | `WindowContentViewController._findInPageView`; `FindInPage.State.webContentFrameID`; no matching saved split/find capture. |

Open questions: visual confirmation of the default fonts; query lifetime on close,
tab change, navigation, and relaunch; whether a window-level last query
seeds another tab; exact focus restoration after close; and the active-pane
rule in Split View. `WindowState.findInPageQuery` and content-local find
state both exist, so “query persists per tab” is not established by those
field names alone. Capture procedure is in §7.

## 2. JavaScript dialogs

| Status | Finding | Evidence |
|---|---|---|
| FACT | ArcCore hands alert, confirm, prompt, and beforeunload requests to the Swift shell, with title/message strings and completions. This is not enough to identify the visible renderer by itself. | `WebContentChromium` ObjC methods at `0x100539f70`, `0x10053a0b8`, `0x10053a200`, `0x10053a478`; `ADK.WebContentUIDelegate` conformance at `0x1036e1ce8`. |
| FACT | The traced native-window implementation uses **`NSAlert` sheets**. It allocates `NSAlert`, sets message/informative text, adds buttons, and ends with `beginSheetModalForWindow:completionHandler:`. Prompt adds a text-field accessory initialized from default text. | Presenter `0x1009a1bd4`, called by alert `0x100e35148`, confirm `0x100e3566c`, prompt `0x100e35ba0`, beforeunload `0x100e3e46c`; `ghidra-layout-js.txt`, `ghidra-helpers.txt`. |
| FACT | The application-type branch in those callers tests whether the bundle ID starts with **`company.thebrowser.dia`**. Arc's bundle ID is **`company.thebrowser.Browser`**, so that test is false for this target. The Dia delegate branch is not evidence of an Arc custom JavaScript dialog. | `0x10059d594` → `0x10059d3c0` → `0x10059d3dc`; prefix string `0x1039684d0`; read-only `plutil -extract CFBundleIdentifier` on Arc's Info.plist. |
| FACT | The shell's native-window button labels are **`OK`** and **`Cancel`**; alert supplies no cancel button, confirm/prompt supply it. The beforeunload native-window branch also constructs OK/Cancel, even though the engine callback has a primary-label argument. Do not substitute Leave/Stay from Chrome convention without a capture. | The four caller functions above; `0x100e34904` forwards title/message/completion to `0x100e3e46c`; `0x1009a1bd4` omits a nil secondary button. |
| FACT | The optional suppression control in this presenter reads **`Don't show this again`**. It is an `NSButton` checkbox in the accessory stack, enabled by the request's suppression flag. Beforeunload's traced native-window branch sets that flag false. | `0x1009a1bd4`, string `0x1039785c0`; `0x100e3e46c`. |
| FACT | Engine resources contain **`$1 says`**, **`An embedded page at $1 says`**, **`This page says`**, **`An embedded page on this page says`**, **`The extension $1 says`**. These are engine title templates; the shell presenter uses the supplied title. | English pack IDs **36242–36246**; `0x1009a1bd4` sets message text from its title input. |
| FACT | Engine resources also contain **`Leave site?`**, **`Leave app?`**, **`Changes you made may not be saved.`**, **`Reload site?`**, **`Reload app?`**. The engine resource **`Prevent this page from creating additional dialogs`** exists, but it differs from the shell checkbox above. Resource presence does not prove that longer checkbox appears. | Pack IDs **36247–36249, 36251–36253**. |
| FACT | Dialog handling belongs to `ADKClient.WebContentFrame`. It tracks `allowsBackgroundJavaScriptDialogs` and beforeunload closing policies `promptUser`, `autoDeny`, `autoAccept`. There are early-answer and delegate branches as well as the NSAlert branch. A window sheet can therefore originate from one tab without being a page-sized overlay. | `0x100e35148`, `0x100e3566c`, `0x100e35ba0`, `0x100e3e46c`; Swift fields `WebContentFrame.ClosingState`. |

Open question: confirm visible behavior for a foreground tab, a background
tab, and a Split View pane. The static native-sheet path and Arc-vs-Dia
branch are proved; no saved runtime capture establishes its appearance or
whether tab switching is blocked. Do not confuse `WebDialogFeature`'s HTTP
login/WebUI views, or `Dialogs`' extension-install sheet, with JavaScript
alert/confirm/prompt.

## 3. Site permission prompts

| Status | Finding | Evidence |
|---|---|---|
| FACT | The shell has its own permission UI: `PermissionRequests.PermissionRequestDialogView` and `.PermissionRequestPopoverView`. State carries `windowContentID`, request, palette, and optional site title. The URL/title placeholder popover has a distinct `permissionRequest` content case. | Swift fields; ObjC class string `0x1039f1a80`; `Arc.CommandBarPlaceholderPopoverState.Content`; `TopBarConfiguration.permissionRequestState`. |
| FACT | Exact decision labels in these views are **`Allow`** and **`Not Now`**. The latter has localization comment “Button to deny permission”. No Allow this time / Block / remember checkbox is proved by these constructors. | `0x101ebeeb4`, `0x101ebe490`, `0x101ebe530`, `0x101ebfc1c`, `0x101ebfcbc`; `ghidra-find-dialogs.txt`. |
| FACT | Exact generic question: **`Allow %@ to access your %@?`**. If no site name exists, the fallback is **`this website`**. Multiple requested permissions can be joined into one title. | `0x101ec1174`, list helper `0x101ec1088`; strings at `0x1039f1b60` and the inline fallback. |
| FACT | Special questions are **`Allow %@ to know when you’re actively using this device?`**, **`Make %@ your default mail app?`**, **`Allow %@ to download multiple files?`**, **`Allow %@ to store files on your device?`**, **`Allow %@ to send you notifications?`**. | `0x101ec1174`; main-binary strings beginning `0x1039f1c10`, `0x1039f1cd0`, and following strings; decoded raw strings in `dialog-permission-strings.txt`. |
| FACT | The prompt table at `0x10055d56c` supplies human-readable permission nouns. It includes AR, window management, camera, captured surface control, clipboard, topLevelStorageAccess, quota, file system access, font, location, hand tracking, idle detection, microphone, MIDI devices, download, notifications, keyboard/pointer lock, storage, sensors, VR, web app installation, local network, ambient login, and protocol-handler cases. These are table entries, not proof that every permission is enabled. | `0x10055d56c`; `ADK.WebContentPermissionRequestType` fields. See Site Control's related display table at `0x10055c864` in [features-advanced](features-advanced.md). |
| FACT | The main popover's help text is **`Click the lock to change this any time`**. It is a shell string; it is not Chromium's stock permission bubble text. | `0x101ebf30c`, string `0x1039f1ab0`. |
| FACT | Little Arc has a separate in-window permission card attached to its content container's leading/top anchors. It animates in with a **0.1 s** helper and has a matching **0.1 s** hide helper. This does not establish the normal-window anchor. | `0x10002b8d4`, `0x10002bbbc`; `LittleWindowViewController.permissionRequestView`; `ghidra-fieldrefs.txt`. |
| FACT | Permission requests are per web content, with engine completions kept in `WebContentChromium.pendingPermissionsRequests`. Quiet-UI requests have a separate early-response path. The shell does not directly write a new JSON permissions file in this request bridge. | `0x10053be38`; `webContents:willAskForPermission:withRequests:withQuietUIReason:completion:` at `0x10053933c`. |
| FACT | Later site-setting changes go through engine APIs for an origin/profile: `setPermissionsForOrigin:withPermissionTypes:withSiteSetting:` and `setContentSettingsForOrigin:withContentSettingTypes:withSiteSetting:`. | [Site Control, SC-2/SC-12](features-advanced.md); ArcCore selectors. |
| FACT | The normal-window permission path creates an AppKit popover from the URL/title placeholder. It anchors to the Site Control Center button's bounds when that button exists; otherwise it uses the hover-button container's bounds. The call requests `NSRectEdge.maxY` (raw value 3). This proves the anchor view and requested edge, not final screen coordinates or AppKit's edge adjustment near screen bounds. | `0x1003b13f0` → `0x1003afa4c` (permission content tag 2) → `0x1003b3004` → `0x1003b1648`, `showRelativeToRect:ofView:preferredEdge:`; static button tag 3 is `siteControlCenter`; `ghidra-badge-cells.txt`, `ghidra-completion-anchor.txt`. |

Open questions: final normal-window placement and dimensions; Allow/Not Now
decision persistence and expiration per permission; remembered origin scope;
one-time grants; grouped camera+microphone wording; and whether a separate
system permission dialog follows the site prompt. No “remember” behavior
should be inferred from the absence of a checkbox.

## 4. Downloads

The Library/downloads state and Little Arc tray are already described in
[features-advanced §9.5](features-advanced.md). Keep those surfaces separate:
the `DownloadItemBackground` colors below belong to **LittleBrowser**.
They are not evidence for normal Library cells or a sidebar popup.

| Status | Finding | Evidence |
|---|---|---|
| FACT | Cmd+Shift+J invokes **View Downloads**, selector `toggleDownloads:`. The command's explanatory text is **`Opens the Downloads section of your Library.`** It targets the Library's downloads section, not a proved `chrome://downloads` page. | MainMenu nib / [menus](menus-and-hotkeys.md); `0x10205d150`, string `0x1039fb350`. |
| FACT | Automation/accessibility identifiers include `downloadButton` and `downloadsMenu`. Their names alone do not prove a dedicated sidebar Downloads button or the menu's geometry. | `arc-strings.txt` lines 34200–34201 / 117522–117523; identifier enum. |
| FACT | Shared actions include open, open when finished, reveal in Finder, copy, cancel, remove from list, and move to Trash. A pause state exists in the download manager, but this does not prove visible Pause/Resume controls. | Swift fields `SharedDownloadsFeature.Action`, `ADKClient.DownloadAction`; no pause/resume case in the shared UI action enum. |
| FACT | The download context-menu builder appends **Open %@**, **Copy %@**, **Show in Finder**, then conditionally a separator and **Cancel Download**, then a separator and **Hide from Arc**, then conditionally **Move to Trash**. `%@` is a file-type description derived from the extension. Missing-state conditions can omit items. | `0x102eac4e8`, `ghidra-batch2.txt`; localization comments at `0x103a36780` onward. This is the download menu, not the page menu. |
| FACT | A download speed uses **`%@/s`**, with the number formatted by `NSByteCountFormatter`. Negative/unavailable speed or an inappropriate state yields no speed string. | `0x101cdba38`; comment `Format string for download speed in seconds (e.g. 3 MB/s)`. |
| FACT | The row model distinguishes failed, paused, cancelled, downloading, finished, and open-when-finished behavior. **`Failed to Download`** is an exact failure subtitle. | `ADKClient.DownloadAction` and download-state fields; strings around line 47329; subtitle formatter `0x101cdbc14`. |
| FACT | Other exact state subtitles include **`Paused`**, **`Cancelled`**, and **`Opening… (<integer>%)`** for open-when-finished. Download size text uses `NSByteCountFormatter`, separates received/total with `/`, and collapses repeated units. The formatter joins available parts with **` · `**; a source suffix uses **`from <domain>`**. These are formatter rules, not a measured row layout. | `0x101cdbc14`, size formatter `0x101cdd0e4`, source formatter `0x101cdd5b4`, remaining-time helper `0x101cdd8f4`; `ghidra-last-details.txt`. |
| FACT | Little Arc row fields are icon, title, subtitle, close button, title stack, and row stack, with a `download` view state. | `LittleBrowserDownloadsTrayItemView` / `.ViewState` Swift fields; tray controller `0x1022adc30`. |
| FACT | Little Arc backgrounds: normal white / dark P3 `(0.05, 0.05, 0.05, 1)`; hovered P3 `(0.96, 0.96, 0.96, 1)` / dark `(0.12, 0.12, 0.12, 1)`. | `.re/design/assetutil_Contents__Resources__ARC_LittleBrowser.bundle__Contents__Resources__Assets.car.json`: `DownloadItemBackground`, `DownloadItemBackgroundHovered`. |
| FACT | Progress-track color is BaseAssets `DownloadProgressBarBackground`: sRGB `(0.808, 0.843, 0.906, 1)` light / `(0.443, 0.467, 0.510, 1)` dark. | BaseAssets catalog. Presence alone does not establish which row uses this track. |
| FACT | `DownloadProgressBadge` explicitly holds progress-ring opacity, overall opacity/scale, completion opacity/scale, icon name/size, and Reduce Motion state. When progress reaches at least 1, its completion callback selects SF Symbol **`checkmark`**, sets icon size **9 pt**, and schedules animations: ease-out **0.8 s** after **0.15 s**; spring response **0.5 s**, damping **1**, after **0.15 s**; ease-out **0.15 s** after **1.15 s**; ease-in **0.15 s** after **1.3 s**. The exact visible trajectory and Reduce Motion result still need confirmation. | `BaseHomeComponents.DownloadProgressBadge` fields; `0x1025dfddc` → `0x1025dfe4c`; `ghidra-completion-anchor.txt`. |
| FACT | Quit warning title: **`Downloads in progress`**. Body: **`There are downloads in progress. Closing the application will cancel them.`** Buttons: **`Close Arc`** and **`Keep browsing`**. | `0x100232ae0`: localized title/body, inline `Close ` + app name and `Keep browsing`; body string `0x103954830`; `0x1005a5f44` app-name helper. |
| FACT | Profile download-location choices have stable IDs `arc.folder`, `arc.other`, `arc.promptForDownload`. The preferences action distinguishes changing the file path from setting “prompt for file download path”. These IDs are menu choices, not three filesystem paths. | `0x102042b90` and adjacent enum functions; `PreferencesFeature.Action.onDidChangeFileDownloadPath`, `.onDidSetPromptForFileDownloadPath`; `promptForDownloadPath` / `promptForDownloadFilePath` fields. |

Open questions: the normal sidebar/menu/tray's exact entry point and frame;
row spacing and typography; which formatted parts appear together; visible
Pause/Resume controls; running badge count versus ring; completion appearance;
and destination menu labels/defaults beyond the captured `Downloads` value
([S2 02/0012, 0034](interaction-states.md)). The existing “Save to Library
copies or registers the file” statement is not a settled copy-vs-reference
result.

## 5. Page context menus

### What the current evidence proves

| Status | Finding | Evidence |
|---|---|---|
| FACT | ArcCore supplies a menu model plus element information to the shell. The context records link/source URL, selection/edit state, and coordinates. Extension/page-dependent items can change the result. | `ADK.ContextMenu.model/elementInfo`; `WebContentChromium.webContents:willShowContextMenu:withElement:` at `0x1005397f8`; `ArcContextMenuElementInfo` metadata; [engine report](arccore-engine.md). |
| FACT | The `WebContentFrame` witness used by that callback points to a shared function that returns false. That callback does not build or filter menu rows. The Boolean's engine-side consequence was not traced here. | `ADK.WebContentUIDelegate` witness table `0x104231b28`, slot `+0x20` → `0x100003b60`; callback `0x1005397f8`; `ghidra-fonts-permission.txt`. |
| FACT | `ARC_ContextMenus.bundle` exists, but its Swift types include sidebar/Space/download menus. The presence of a title in this bundle or the main binary does not establish that it is appended to a web-page menu. | Bundle Info.plist; `ContextMenus.DownloadMenu`, `SpaceMenu`, `SidebarMenu`; `WindowContents.CommandBarContextMenuAction`. |
| FACT | A separate **URL/title-bar context-menu** enum contains Copy URL, Share, toolbar toggles, full-URL toggle, shared-quote toggle, Capture, Capture Full Page, Capture in Portrait Mode, and Manage Extensions. This enum is not the Chromium page-context-menu model. | `WindowContents.CommandBarContextMenuAction` Swift fields; comments near main-binary `0x10395ded0`. |
| GUESS | The older [menu report](menus-and-hotkeys.md) and EX-18's claim that Capture/Share/Copy URL/Manage Extensions are page-menu additions needs a page-menu capture or a builder trace. The cited title comments also belong to the URL-bar menu family, so they do not settle that claim. | Earlier docs versus the separate `CommandBarContextMenuAction` and `ADK.ContextMenu` types; no saved page-menu AX capture. |

The following strings are **FACTS about the English engine resource**.
They are a lookup list for a later capture. They do **not** prove item
visibility, grouping, inclusion, or screen order in Arc.

| Status | Target | Exact resource titles (mnemonic `&` removed for readability) | Evidence |
|---|---|---|---|
| FACT | Page | Back; Forward; Reload; Save As…; Print Text Selection…; View Page Source; Translate to $1; Exit Full Screen; Reload Frame; View Frame Source | Pack IDs 8911–8913, 8915–8916, 8924, 8927–8930. |
| FACT | Link | Open Link in New Tab; Open Link in New Window; Open Link in Incognito Window; Open Link in Split View; Open Link in Left/Right/Top/Bottom View; Open Link With…; Save Link As…; Copy Link Address; Copy Email Address; Copy Link Text | Pack IDs 8917, 8931–8933, 8937–8941, 8948–8951. |
| FACT | Image | Open Image in New Tab; Open Original Image in New Tab; Load Image; Save Image As…; Copy Image Address; Copy Image | Pack IDs 8958–8963. |
| FACT | Selection | Copy; Copy Link to Highlight; Remove Highlight; Select All; Translate Selection to $1; Translate; Search $1 for “$2”; Search $1 for “$2” in New Tab; Go to $1 | Pack IDs 8982 (alias of 299), 8952, 8956, 8997–8999, 9001–9002, 9007. |
| FACT | Editable field | Undo; Redo; Cut; Copy; Paste; Paste and Match Style; Select All; Add to Dictionary; Remove from Dictionary; Start Dictation; password/passkey actions | Pack IDs 8979–8986, 8997, 9008–9009, 9014, 9018. The DataPack alias table supplies 8981–8984. |
| FACT | Extensions | Manage Extensions | Pack ID 10091. This may belong to extension-management UI; placement in the page menu is unproved. |

No exact page/link/image/selection/editable **menu order** is established by
this table. In particular, resource strings for Split View can be stock
Chromium strings. They do not prove an Arc-specific split addition. No
Little Arc or Peek page-menu item was established. Search resource text is
`Search $1 for “$2”`; “Search with…” should not be adopted as exact Arc copy
without the live menu.

### Open's existing choice: merged PR #94

**FACT:** [PR #94](https://github.com/SergeSerb2/open/pull/94), merged as
`f668a90e19020c83227154ef68c789ca7063eee3`, is an **Open allowlist decision**.
Its choices are not reverse-engineering proof of Arc's hidden items.

| Status | Open behavior already chosen | Evidence |
|---|---|---|
| FACT | Preserve supported page navigation/save/print/source/inspect, link/image/media, editing/spelling/writing-direction, password/passkey, protocol-handler, page-added, extension-added, and macOS Speech items. Preserve Chromium's relative order of surviving entries. | `Engine/OpenEngine/src/OEContextMenuAllowlist.mm`; merge `f668a90e`; `git log --all --grep=allowlist`. |
| FACT | Hide IDs not in that allowlist, including unsupported Chrome panels, profile/sync routes, Lens/AI, and unsupported toolbar bubbles. Chromium's selected-text search action is explicitly excluded because it uses Chromium's engine instead of the Profile's engine. | Allowlist `IsAllowed`; PR #94 body; decision commit `4b43d952`. |
| FACT | Remove invisible items before filtering; trim leading/trailing/repeated separators; recursively filter submenus and remove empty submenus. Selection accepts only delivered enabled leaves, and does not descend through a disabled parent. | `OEFilterChromeContextMenu`, `OERequests.mm`, PR #94's merged visibility/disabled-parent fixes. |

Open questions: actual Arc item order and separators for all five targets;
which Chromium IDs Arc hides; whether Capture, Translate, Manage Extensions,
Peek, Little Arc, and Split View appear in the page menu; and exact search
provider wording. Capture each target independently; do not extrapolate
from the URL-bar, tab-row, or extension-action context menu.

## 6. Clear Browsing Data / history clearing

| Status | Finding | Evidence |
|---|---|---|
| FACT | Settings → Profiles → **Your Data and Settings** contains **Clear Browsing Data** alongside Privacy and Security, Passwords, Credit Cards, and Notifications. | Saved AX `20261026-100621-02-settings-setup/0008-100637/ax.json` and 0030/0031; [interaction-states §18](interaction-states.md); string `0x1039f96d0`; constructor `0x102041768`. |
| FACT | The main binary contains **`settings/clearBrowserData`** and an `ADK.ChromiumSettings.clearBrowserData` enum case. Sibling cases cover privacy, payments, notifications, search engines, and password manager. | String `0x103963220`; `ADK.ChromiumSettings` reflection fields. This is route availability, not the proved click path. |
| FACT | The Clear Browsing Data row's callback dispatches `ProfilePreferences.Action.onChangePrivacyPreferencesTapped` (tag 8), wrapped in `PreferencesFeature.Action.profilePreferences` (tag 46). The Privacy and Security row uses a thunk of the same callback. There is no distinct clear-data action in this profile-action enum. | Constructor `0x102041768`; callback `0x10204ca60` → `0x102041f50`; saved listing in `ghidra-route-tags.txt`; descriptors `0x103d12498`, `0x103d122a0`, decoded in `route-action-fields.json`. |
| GUESS | The row likely shares the Privacy and Security destination. The separate `settings/clearBrowserData` string is not enough to claim that this row opens that exact page. The final destination still needs a post-click capture or a complete action-handler trace. | Callback identity above; no saved post-click Clear Browsing Data page. |
| FACT | Clear Archive is a separate Arc command. Clear Cache/Clear Cookies in Site Control are per-site actions; they do not identify the Clear Browsing Data UI or its time-range/data-category defaults. | MainMenu nib; Site Control footer `0x101384580`; [features-advanced SC-16](features-advanced.md). |

Other entry points, exact resulting URL scheme, selected time range,
category defaults, and the scope of deleting Arc history remain open.

## 7. Captures that would settle the remaining questions

The user must operate Arc. A capture needs the whole browser window, the
page's top edge, the sidebar/toolbar state, and an AX snapshot when possible.
Use synthetic pages and filenames, not private history or real message text.

| Capture | Steps and evidence needed |
|---|---|
| Find appearance | Light and dark, toolbar off/on, a narrow window, empty query, `1/5`, and no match. Include a sharp 2x still for type, color, and icon comparison; video for any show/hide transition. |
| Find state/focus | Tab A query, Tab B query, back to A; close/reopen find; navigate and reload; repeat in both Split View panes. Record the selected pane before Cmd+F, then Esc/click close and type or scroll to show focus destination. Include Return/Shift+Return/Cmd+G/Cmd+Shift+G and a selected-text seed. |
| JavaScript dialogs | Alert, confirm, prompt with a default, and beforeunload on close/reload. Repeat twice to expose suppression; record exact title/button/checkbox copy, sheet edge, tab switching, and a background-tab request. |
| Permission prompts | Fresh synthetic origins: location, notifications, camera, microphone, combined camera+microphone, clipboard, MIDI. Capture toolbar on/off and hidden sidebar, then Allow/Not Now, reload, revisit, new tab, and browser restart. Record the Site Control value after each decision. Keep any macOS system alert distinct. |
| Downloads | One slow synthetic file, two concurrent files, pause if offered, cancel, failure, completion, row hover/context menu, and a download in Little Arc. Record entry point, ring/count, row copy, completion motion and Reduce Motion. Quit during an active download, then cancel quitting. |
| Destination | In a fresh Profile, open the Download location menu; choose each option and start a download. Capture chooser behavior, remembered folder, default filename, and a later download. |
| Context menus | Same synthetic fixture: blank page; normal link; linked image and plain image; selected text; empty and selected editable text; a misspelling. Capture every row, separator, submenu, disabled state, and shortcut, with/without an extension-provided item. Repeat selection under two search providers and a non-English page for Translate. |
| Clear Browsing Data | Click the Profile row; capture final URL, selected Profile, tabs/categories/time range, and buttons. Do not clear private data just to collect the UI. |

Verification for this docs-only work: static evidence review and
`git diff --check`. Build, e2e, and `tools/verify-all.sh` are not run, as the
research brief explicitly exempts this docs-only PR. No runtime or visual
acceptance is claimed.

### Section 11 implementation: page menu and dialog bounds (2026-11-07)

Open adds `Manage Extensions` through `PageContextMenuHooks.extensionItems`, excluding editable targets. **GUESS (lead decision):** place it after Chromium's extension contributions in the same group; with no contributions, use a separate group immediately before Inspect. The title is FACT (`features-advanced.md` EX-18); capture S-9 must settle Arc's actual position. Action: the existing `manage-extensions` app command (`App/MainMenu.swift`), opening the extensions page in Today.

Oversized alert, confirm and prompt messages and prompt defaults are shown with at most 10,240 UTF-8 bytes, including a trailing `…` when Open cuts the received text. The cut preserves a complete UTF-8 character. `PageChromeLimits.dialogText` bounds the native sheet text; `PageDialogPresenter` retains the original engine request for its single completion. Other limits are unchanged. Real-App evidence and negative proofs are in `docs/engine-spike/pagechrome-leftovers.md`; these checks prove Open's implementation, not Arc's unrecorded menu placement.

Chromium first applies its own character-count cap to messages without a truncation mark. An ASCII message already cut upstream arrives at the callback with 10,240 bytes and no cut flag; Open preserves that unmarked text. Open adds `…` only when its own 10,240-byte UTF-8 bound cuts the received message or prompt default. The e2e over-bound byte fixture uses multibyte text below Chromium’s character cap so it proves Open’s bound; a separate ASCII case proves the unmarked upstream cut. This is the lead’s 2026-11-07 ruling, verified through the real Chromium callback and native sheet.
