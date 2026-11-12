# Easels and Notes (F1 findings)

Targets: installed Arc 1.172.2 (arm64 slice of `/Applications/Arc.app/Contents/MacOS/Arc`, called **172** below) and the reference Arc 1.170.0 (`.re/bin/Arc-arm64`, called **170**). Arc was not launched. All facts below come from static files. Raw output is in `.re/f1/` (git-ignored). No Arc asset or code is copied here; this file restates names, keys, values and behaviours in our own words.

Evidence tags used below:

| Tag | Meaning | How it was made |
|---|---|---|
| `FM` | Swift field metadata: type, field names, field types, enum cases | Our parser `.re/f1/tools/fieldmd.py` over `__swift5_fieldmd` of 172; full dump `.re/f1/fm-all-172.txt` |
| `STR` | A C string in the binary | `strings -a` → `.re/f1/strings172.txt`, `strings170.txt` |
| `NIB` | MainMenu.nib of 172 | `rea decode-interface-builder /Applications/Arc.app --format json` → `.re/f1/ib172.json`; menu placement from `docs/re/menus-and-hotkeys.md` |
| `CAR` | Asset catalog | `xcrun assetutil --info …/ARC_EaselUI.bundle/…/Assets.car` (also `ARC_TextEditor`, `ARC_ArcRichTextEditor`) → `.re/f1/assets-*.json`; main catalog from `.re/design/all-colors.txt` |
| `EXP` | Easel export viewer files in `ARC_EaselUI.bundle/Contents/Resources/` (172 only) | Copied to `.re/f1/easel-bundle/`; read as data |
| `DISK` | The user's Arc data, read only | `~/Library/Application Support/Arc`, `~/Library/Caches/Arc` |

"guess" marks every statement that static evidence does not prove.

## 1. Summary

- **Easels** are free-form canvases ("your scrapbook for the web", STR). They live in the sidebar like tabs. A canvas holds text, rich text, shapes (rectangle, circle, arrow, freehand), images, web captures (screenshot or live), small embedded browsers and link cards. Easels are stored on **Arc's Firebase (Firestore + Firebase Storage)**, not on disk. They can be shared by link and edited by several people at once (presence cursors, avatars). Arc 1.172 adds **"Export All Easels"**: a zip of self-contained web pages with one `easel.json` per Easel.
- **Notes** ("Arc Notes") are rich-text documents in the sidebar, edited by a **native AppKit text view** (not a web editor). They are stored locally (`StorableARCDocuments/`) and synced to Firebase. Arc has **phased Notes out**: flags and strings disable new notes and the editor, and "Export Arc Notes" (Help menu) saves a zip of HTML files. The "Default Document App" setting can make "New Note" open a web document site (Google Docs, Notion, …) instead.
- Open has no Arc servers. Every share, presence and sync part of both features needs Arc's account and servers and cannot be reproduced. The local editing parts can.

## 2. Code map (where the features live in Arc)

Source paths and modules (STR, build paths under `…/arc/Frameworks/…` and `…/arc/Browser/…`):

| Area | Modules / files |
|---|---|
| Easel data and sync | `EaselClient` (`EaselClient.swift`, `EaselDocument.swift`, `EaselDocument+Fetch.swift`, `EaselFirebaseDataProvider.swift`, `EaselObjectFirebaseRequestHandler.swift`, `EaselRemoteImageLoader.swift`, `NSImage+Optimized.swift`), `EaselLibraryClient`, `Easel/EaselReducer.swift`, `Easel/EaselState.swift` |
| Easel UI | `EaselUI` (AppKit; `CanvasView`, `EaselCanvasViewController(+Export, +SnapGuides)`, `EaselEditorViewController`, `EaselViewController`, `ObjectView`, `ObjectEditor`, `MoveManager`, `CanvasGrabber`, `CanvasInputOverlay`, `DragHandle`, `ColorPicker`, `URLInputView`, `EaselWebCardView`, `EaselWebBrowserView(+Boosts)`, `EaselLiveCaptureOverlay`, `EaselWebExporter`, `EaselWebExportCoordinator`, `InMemoryEaselDataProvider`); SwiftUI only for small parts (`InputPicker`, `EaselToolbarButton`, `ShareButton`, `EaselPresenceBar`, `EaselLinkViewContent`) |
| Notes data and sync | `DocumentsClient` (`DocumentsClient.swift`, `ArcDocumentsClient.swift`), `DocumentsLibraryClient`, `BaseModels/NoteDocumentType.swift`, `BaseModels/RichTextFormatType.swift` |
| Notes UI | `DocumentsFeature` (`ArcDocumentReducer`, `ArcDocumentEditorViewController`, `ArcDocumentErrorViewController`, `ArcDocumentLoadingViewController`, `ScratchpadContents+AttributedString.swift`), `TextEditor` (`TextEditorViewController`, `TitleEditorContainerView`, `TextEditorForwardingResponderView`), `ArcRichTextEditor` (`ArcRichTextEditorView`, `ArcRichTextEditorContainerView`, `TextEditorFormatMenu(View)`, `TransformType`, `NSMutableAttributedString+RichTextFormatType`, `NSTextAttachment+Image`) |
| Shell glue | `Browser/Sidebar/SidebarCells/EaselCellState.swift`, `ArcDocumentCellState.swift`, `ArcDocumentCellView`; `Browser/Windows/Store/WindowState+EaselExport.swift`, `WindowState+ArcDocument.swift`; `SharedWindowFeature/WindowData+ArcDocument.swift`; `HomeButton/EaselsAndNotesContentView.swift`, `EaselsAndNotesReducer.swift`; `SearchClientManager/EaselCandidateProvider.swift`; `ArcDocumentPIPWindowControllerViewModel` |

Editor engine answer: **both editors are native AppKit.** Evidence: `ArcRichTextEditorContainerView` owns an `NSTextStorage` and an `NSUndoManager`; `BaseEditorTextView` and `TitleEditorTextView` are text-view subclasses; images are `NSTextAttachment` cells (`TextEditorImageAttachmentCell`); the delegate method `textView(_:clickedOnLink:at:)` is AppKit's (FM, STR). The Easel canvas is AppKit views and `CALayer`/`CAShapeLayer` (FM fields `presenceCursorsLayer: CALayer`, `snapguideHighlight: CAShapeLayer`). The only web parts are web cards and browser objects, which host live web content (`EaselWebContentPool.liveWebViews`, FM).

## 3. Easels

### 3.1 Entry points

| Entry | Detail | Evidence |
|---|---|---|
| File ▸ New Easel | ⌃⇧E, selector `newEasel:`, outlet `newEaselMenuItem` | NIB; menus-and-hotkeys.md |
| Sidebar plus menu | "New Easel ⌃⇧E" row | interaction-states.md S2 01 (captured, 0093) |
| Command bar | Description "Creates a new Easel — your scrapbook for the web. Capture, create, and share stuff you find on websites in Arc." | STR |
| Capture | Capture result can save to an Easel: action ids `saveToEasel`, `newEasel`; "See Older Easels"; string "Capture a part of the page, then save it or add it to an Easel."; `EaselDestination {easelID, title, lastActive, shareStatus, creatorID}`; `createEasel(type:title:insertionStrategy:addToLastSavedDestination:presentationDisposition:)`; `EaselClient._addImageAndCreateEaselIfNeeded` | STR, FM |
| Window ▸ View Easels & Notes | selector `viewEaselsAndNotes:` (opens the Library page, guess) | NIB |
| Library | Easels category tile (captured as one of six tiles in Arc 1.170 C session) and Library card "Your Easels are yours to keep" (172 only, §3.8) | library-overlay.md; STR |
| Command bar search | `EaselCandidateProvider`, `SearchableEasel {id, title, creatorID, lastModified}` — Easels are searchable by title | STR, FM |
| Folder description | "Creates a new folder for your tabs, Easels, Notes, and everything else you can squeeze in." | STR |
| View ▸ Appearance | Header "Websites, Easels, and Notes will use:" | NIB |
| Help link | `https://resources.arc.net/hc/en-us/articles/19231142050071-Easels-Capture-Create` (fetch returned 403) | STR |

### 3.2 Sidebar item

On-disk item in `StorableSidebar.json` (data-model.md §2.2, confirmed on disk in an earlier dump; the current test data has no Easel item):

```ts
// data: { easel: SidebarEasel }      (FM SidebarEasel + CodingKeys)
interface SidebarEasel {
  easelID: string;                       // Firestore document id
  shareStatus: "readOnly" | "publicReadWrite" | "creatorOnly";
  title: string;
  timeLastActiveAt?: number;             // Arc time
  customInfo?: { iconType: IconType };   // same custom icon as tabs (guess: emoji/icon)
  creatorID?: string;                    // Arc user id
}
```

Context menu rows (STR): "Remove Easel from Sidebar" / "Remove Easels from Sidebar" (archive), close variants ("Menu item for closing an Easel"), "Copied Easel URL" toast, delete confirm "Are you sure you want to delete this Easel?" / "…these Easels?" with "Doing so will delete the Easel permanently." / "…these Easels permanently.". Untitled placeholder exists ("Placeholder for an untitled easel title in the sidebar.", value not static: needs capture). Sidebar icon: guess the `EaselFavicon` image of the main catalog (design-tokens.md).

### 3.3 Document model (live, in memory)

From FM (172). Field names are facts; JSON key spellings are the CodingKeys listed.

```ts
interface EaselDocument {
  id: string; version?: number; creatorID?: string;
  objects: { [objectID: string]: EaselObject };
  palette?: "vibrant" | "chill" | "theme";
  allParticipantsEver: Participant[];             // {id, name, avatar?}
  presence: { [participantID: string]: { participantID; mousePosition? } };
  shareStatus?: ShareStatus;
  titleObjectID?: string;      // a text object promoted to the Easel title
  customOGImageID?: string;    // object used as the share thumbnail
  serverTitle?: string; lastModified?: Date;
  hasLoadedObjects: boolean; skippedObjectCount: number;
}
interface EaselObject {
  id: string;
  position: { frame: CGRect; zIndex?: number; movedToFrontAtTime: Date };
  content: EaselContent; editable: boolean;
  addedInfo?: { participant; added: Date };       // CreatorInfo
  currentWorkingVersion: string;
}
type EaselContent =
  | { image: { id; content: {url} | {loaded} | failedToUpload | placeholder; size?; dominantColors?: RGBA[]; altText? } }
  | { text: { string: string; style: { fontFamily: "mono"|"fancy"|"hip"|"clean";
                                      paragraphStyle: "body"|"h2"|"h1"|"h0"|"ultra";
                                      fillStyle: "none"|"contentHugging" } } }
  | { richText: { text: string; properties: { richText: { range: NSRange; value: RichTextFormatType } }[] } }
  | { shape: { type: {arrow:{start,end}} | {freehand:[Point]} | rectangle | circle; color: EaselColor } }
  | { webCard: { image?; text?; url; favicon?; dateCaptured?;
                 captureLayoutInfo?: { webContentSize; webContentOffset; frameRelativeToViewport:{x,y,width,height} };
                 captureType? } }
  | { browser: { url?: URL } }                     // CodingKey "webBrowser"
  | { link: { image?; video?: { url; size? }; title?; source: URL; description? } };
type EaselColor = "black"|"gray"|"white"|"pink"|"red"|"yellow"|"lightGreen"|"darkGreen"|"lightBlue"|"darkBlue"|"purple";
```

Content CodingKeys are `image, text, shape, webCard, textStyle, richText, link, webBrowser`; shape CodingKeys `rectangle, circle, arrowFrom, arrowTo, freehandPoints` (FM). Link cards are filled from page metadata: `og:title`, `og:description`/`description`, `og:image`, `og:video`(`:url`,`:width`,`:height`) (STR).

### 3.4 Canvas geometry and look (facts from EXP, which says it mirrors the native editor)

- The document is **1000 points wide**. Object frames are stored as **fractions of the document width** (x, y, width, height all divided by width). Height grows with content; the canvas scrolls vertically (`CanvasMode: verticallyScrolling | fixed`, FM). The view scales with the window width (`canvasWidth`, `documentHeightAsFactorOfWidth`, `convergedWidth`, FM).
- Text styles (point size, weight; line height per family):

| family (font) | ultra | h0 | h1 | h2 | body | line height |
|---|---|---|---|---|---|---|
| mono (Space Mono) | 80 bold | 60 bold | 44 bold | 24 bold | 15 regular | 1.48 |
| fancy (EB Garamond) | 80 | 60 | 48 | 28 | 16 | 1.32 |
| hip (Inter) | 80 /900 | 60 /900 | 44 /900 | 21 bold | 18 | 1.28 |
| clean (system) | 80 /800 | 60 /800 | 44 /800 | 24 bold | 15 | 1.20 |

  Headings centre-align; body left-aligns. Text boxes have fixed frames and the text shrinks to fit (EXP fit loop). Horizontal text inset 5 pt. All four fonts are SIL OFL (EXP `EaselExportFontLicenses.txt`), so Open may bundle its own copies from upstream.
- Shapes: fill opacity 0.75, stroke 2.5 pt, round joins and caps; white uses a 10 % black stroke. Arrow head: two strokes at ±45° from the tip, length `min(32, 0.3 × arrow length)`. Default colours: rectangle lightGreen, circle red, arrow lightBlue, freehand black (EXP). Default per-tool colours are user preferences (`rectangleColor`, `arrowColor`, `circleColor`, `freehandColor`, FM).
- Palettes (CAR main catalog + EXP; light values; black/white swap in dark):

| colour | Chill | Vibrant |
|---|---|---|
| pink | #F2C2AC | #FF994E |
| red | #D74807 | #F53714 |
| yellow | #C2A12A | #FFD335 |
| lightGreen | #D0D87F (p3) | #34E895 (p3) |
| darkGreen | #1D5914 | #107A00 |
| lightBlue | #55A2BD (p3) | #00C7F3 (p3) |
| darkBlue | #3139FB | #3139FB |
| purple | #A6729D | #C0009F |
| grey | #BBBBBB | #BBBBBB |

  A third palette value `theme` follows the Space theme (FM `EaselPalette`). The canvas context menu offers palette choice ("Menu Item that shows the available color palettes", STR).
- Colours from `ARC_EaselUI` (CAR, light / dark): selection `EaselSelectionColor` #6CBAD9; toolbar icon `ToolbarIcon` #5F5880 / #85878E; floating toolbar `FloatingElementBackground` #FFFFFF / #000000; modal `ModalBackground` #FFFFFF / #120F2E with outline #120F2E 3 % / #FCFFFF 10 %; capture buttons normal #FFFFFF / #252832, hover #F0F1F3 / #373C4B, pressed #E3E6E7 / #495064; image filler #000 10 % / #686A6B; error border #D13B23 / #D18881 (p3); loading squiggle `LoadingStateForeground` #5F5880 / #FFFFFF. Main catalog: `EaselBackground` white 85 % / black 50 %; `EaselTitleText` #101118 80 % / white 80 %.
- Web card overlay keeps fixed sizes: bar 36 pt tall, inset 6 pt, corner 8, favicon 16, open chip 23 × 23 corner 5, fade 0.15 s on hover; card corner 10 (EXP, "keeps Arc's fixed point sizes (WebCardConstants)").
- Snap guides: anchors left/right/centerX/top/bottom/centerY (FM `Anchor`), toggle "Use Alignment Guides" in the canvas context menu, default key `easel.useSnapguides`.

### 3.5 Tools and editing

- Input modes (FM `EaselInputMode`): `select`, `move`, `addText`, `addImage`, `addWeb`, `addShape(rectangle|circle|arrow|freehand)`. Drawing overlay modes: rectangle, text, oval, arrow, freehand, web, selection (FM `CanvasInputOverlay.Mode`).
- Toolbar: a floating picker (`InputPicker`, SwiftUI) with tool buttons, hover text, extra buttons, and on the right a share button and presence avatars (`shareAndPresenceStack`, FM). Tool icons in `ARC_EaselUI` (CAR): `EaselIconPointer`, `EaselIconText`, `EaselIconShapes`, `EaselIconRectangle`, `EaselIconEllipse`, `EaselIconArrow`, `EaselIconLine`, `EaselIconTriangle`, `EaselIconFreehand`, `EaselIconImage`, plus `FontIcon`, `FontSize{Body,H1,H2}`, `FontStyle{Fancy,Hip,Mono,System}`, `PaintBucketIcon`, and custom cursors (`Cursor`, `Pencil`, `Movable`, `Moving`, `Interactable-*`, `ResizeNESW/NWSE`). Open must draw its own.
- Text menu: font family and size choice (`TextMenuView`, icons above). Feature flag `easel-expanded-text-sizes` adds sizes (guess: h0/ultra).
- Object context menu (STR comments): Cut, Copy, Paste, Duplicate, Delete, Bring to Front, Send to Back, make the object the document title, "Set as Easel thumbnail" / "Reset to default thumbnail", "Edit Alt Text" / add alt text (dialog text "Caption your image to make it accessible to folks using screen readers or other assistive technologies."), copy URL of an embedded Capture. Exact visible titles of the comment-only rows: needs capture.
- Undo labels exist for move, update, insert, delete, alt text (STR). Pasteboard type `company.thebrowser.Browser.easelObject` carries objects between Easels (STR, FM `EaselObjectPasteboardWriter`).
- Web objects: a web card starts as a **screenshot**; the user can flip it to **live** ("Replace this screenshot with the live website?" / "See an up-to-date, interactive view of whatever you've captured. This does not work on all sites. You can always flip back to the screenshot by pressing …"; keys `easel.liveWebCardEduDialogSeen`, `easel.useLiveWebCard:<id>`) (STR). A browser object is a small page with a URL bar; its search tool uses DuckDuckGo with categories all/images/video/news/maps/shopping (flag `easel-search-tool-enabled`) (FM, STR).
- Pan and zoom: `CanvasGrabber` (pan by a drag handle with a hover delay) and `currentZoomInteraction` / `magnification` exist (FM). Exact gestures and limits: needs capture.

### 3.6 States

Loading ("Easel is loading", squiggle animation), error ("Update Arc to view this easel", "Press … E, and type \"update\"" (the modifier glyph is not in the string; guess ⌘); not-found; no permission), empty canvas (needs capture), selected / hovered / moving / resizing objects (FM `SelectionState`, `MouseState`, `EditState`), image upload in progress ("Upload in Progress"), live-card framing states `none/inProgress/hasFramed/error` (FM).

### 3.7 Storage and servers

- **Content lives in Firestore**, collections `easels`, `objects`, `readStatesPerParticipant`, `readStates`, `memberships`, `presence` (FM `EaselCollectionIDs`). Firestore objects are `EaselFirebaseObject {id, position{rect{x,y,width,height}, zIndex}, content{image?,text?,richText?,shape?,webCard?,webBrowser?,link?,isPlaceholder?}, addedInfo?, previousWorkingVersion, currentWorkingVersion}` with optimistic versioning (FM). Images upload to Firebase Storage (`firebasestorage.googleapis.com`, `EaselRemoteImageLoader.uploadQueue`) and cache in `~/Library/Caches/Arc/EaselImagesCache/` (STR; DISK: empty).
- Share links: base `https://arc.net/easel` (guess: `/…/<id>`), share statuses above; "Once shared, Easels can be viewed in any browser but only edited in Arc. Your name will be visible to anyone with the link." (STR).
- `EaselClient.createEasel` requires an Arc user ("Make sure to create (and set) a user before creating an easel") (STR). **So Arc cannot make an Easel without an account; nothing about content is on this Mac.**
- Feature flags (STR): `easel-drag-optimization-enabled`, `easel-search-tool-enabled`, `easel-expanded-text-sizes`, `easel-exporter-enabled` (172 only).

### 3.8 Easel web export (Arc 1.172 only)

- Library card (STR): title "Your Easels are yours to keep", text "Winding down Arc doesn't mean losing your work. Save all your Easels as web pages you can open anywhere, share, or host yourself.", button "Export All Easels". Per-Easel menu: "Save this Easel as a web page you can open anywhere." Progress sheet "Saving your Easels" / "Gathering your Easels" / "%d of %d". Results: "Your Easels are saved", "Your Easel is saved", "%d of %d Easels saved", reveal button. Failure: "Something went wrong" / "We couldn't finish saving your Easels. Please try again.". Archive name has a `yyyy-MM-dd HH.mm` date.
- Zip layout (EXP README): `index.html` (list with filter All/Shared/Private and sort Last edited/Created/Title), `<Easel name>/index.html`, `<Easel name>/easel.json`, `<Easel name>/images/`, `EaselExportViewer.js/.css`, `fonts/`, `README.md` with an export log, `FONT-LICENSES.txt`.
- `easel.json` schema (FM `EaselWebExportDocument`, cross-checked with the EXP viewer):

```ts
interface EaselExport {
  formatVersion: number; id: string; title?: string;
  palette: "chill" | "vibrant"; exportedAt: Date;
  objects: { id: string; frame: {x,y,width,height}; zIndex: number; content: ExportContent }[];
}
type ExportContent = { type: "text"; string; fontFamily; paragraphStyle }
  | { type: "richText"; text; formats: { location; length; type; url?; level? }[] }
  | { type: "shape"; kind: "rectangle"|"circle"|"arrow"|"freehand"; color; arrow?: {start,end}; points?: {x,y}[] }
  | { type: "image"; src?; altText?; size? }
  | { type: "webCard"; url; title?; image?; favicon?; dateCaptured?; liveCapture?: { webContentSize; frameRelativeToViewport } }
  | { type: "browser"; url? }
  | { type: "link"; source; title?; description?; image?; video?: { url; size? } };
```

  The `type` discriminator spelling is from the viewer (EXP); the date encoding of `exportedAt` is not proven (guess: ISO 8601). This file is **the only route to a user's Easel content without Arc's servers**, and it is complete enough for Open to rebuild every object kind.

## 4. Notes

### 4.1 Entry points

| Entry | Detail | Evidence |
|---|---|---|
| File ▸ New Note | ⌃⇧N, `newNote:`; search aliases "Create Note; Note; Scratchpad" | NIB |
| File ▸ New Note (in Split) | ⌃⌥N, `newNoteInSplitView:`; aliases "Create Note in Split View; Note Split; Scratchpad Split"; command bar "Creates a new Note beside your current page." | NIB, STR |
| Command bar | "Creates a new note. Document types can be set in the Profiles tab."; "Action to open new Arc Note"; "Action to create a new document; e.g. 'New Google Doc'" | STR |
| Help ▸ Export Arc Notes | `exportArcNotes:`; aliases "Export Notes; Backup Notes; Download Notes" | NIB |
| Window ▸ View Easels & Notes | shared with Easels | NIB |
| Plus menu | Not present in the 1.170 capture (S2 01 lists no New Note); flags hide it (§4.6) | interaction-states.md |
| Help link | `…/19233788518039-Notes-Quickly-Jot-to-an-Arc-Note-or-Your-Favorite-Notes-App` (403) | STR |

### 4.2 Default Document App

- Setting row "Default Document App" in the Profiles pane (per Profile), defaults key `defaultNoteDocumentApp` (STR; features-core.md §7.2).
- Value `NoteDocument {title, type: arcNote | webDocument(URL), appID}` (FM). The arc option is titled by "Title for Arc Notes document option" (value: needs capture).
- Web document URLs present in the binary (STR, adjacent block): `https://doc.new`, `https://sheet.new`, `https://slide.new`, `https://word.new`, `https://app.notion.com/new`, `https://figma.new`, `https://figjam.new`, `https://meet.new`, `https://replit.com/new`, `https://make.page`. Which of these are Default Document App options (versus "New …" command-bar actions) is a guess; the menu list needs capture. A toast "New Document Created" exists for a document made in the background (STR).

### 4.3 Sidebar item

The sidebar `data` key is **`arcDocument`**, not `note` (FM `SidebarItemData` cases: `tab, list, arcDocument, easel, itemContainer, welcomeToArc, splitView, sharedObject, instantLinks, tabGroup`). `note` exists only as an analytics item type. Correction to data-model.md §2.2 and to Open's importer (§6).

```ts
// data: { arcDocument: SidebarArcDocument }   (FM + CodingKeys)
interface SidebarArcDocument {
  arcDocumentID: string; timeLastActiveAt?: number;
  isEditable: boolean; customInfo?: { iconType: IconType };
}
```

Rows: "Remove Note from Sidebar" / "Remove Notes from Sidebar", close variants, "Menu item title to delete an Easel or Note." (STR). Flag `unpinned-notes-insertion-strategy-enabled` decides where a new note lands (guess: Today section). Notes can open in a floating window (`ArcDocumentPIPWindowControllerViewModel`, FM; behaviour needs capture).

### 4.4 Document model and storage

```ts
interface ARCDocument {                     // FM
  id: string; title: { value: string; lastUpdatedAt: Date };
  data: { scratchpad: { blocks: { [id]: ScratchpadBlock }; rootBlocks: string[] } };
  shareStatus: "privateDocument" | "publicDocument";
  creatorID: string; createdAt: Date;
}
interface ScratchpadBlock {
  id: string; type: "fullBlob"; version: number; text: string;
  properties: { richText: { range: NSRange; value: RichTextFormatType } }[];
  content: string[]; lastUpdatedAt: Date;
}
type RichTextFormatType = "bold"|"italic"|"underline"|"strikethrough"|"h1"|"h2"|"h3"|"hyperlink"
  | { formattedHyperlink: { url? } } | { unorderedList: { level } } | { orderedList: { level } } | { image: <encoded image> };
```

- One block of type `fullBlob` holds the whole note: plain text plus attribute ranges (FM; `ScratchpadContents+AttributedString.swift`). The same range model is used for Easel rich text.
- Local store: `~/Library/Application Support/Arc/StorableARCDocuments/` (directory, STR list of storable paths), each entry `StorableARCDocument {version, arcDocument}` (FM). DISK: the folder exists and is empty on this Mac. Per-file naming: guess (one JSON per document id).
- Sync: Firestore via `DocumentsClient.save/delete/documentsForUser/fullDocumentsForUser/documentSubscription` (STR). Notes over **1 MB** do not sync: "Currently, notes larger than 1MB cannot be shared or synced. They'll still be available on this computer." Share URL base `https://arc.net/note` (STR).

### 4.5 Editor

- Layout: a title field (`TitleEditorContainerView`; colours `TitleText` #220C7F / #E6E6FF, placeholder same at 40 %) above a body text view in a scroll view; a gutter "+" button (`GutterButton` 44 × 44 image, `gutterButtonWidth/Height`); a paragraph menu and a selection format menu (FM `TextEditorViewController`). Body placeholder "Your best ideas here" (STR).
- Format menu items (FM `FormatMenuTextIconType`): Heading 1/2/3, Text, Bulleted list, Numbered list, Insert image, Bold, Italic, Strikethrough, Underline, link, plus Share. Short labels "Heading 1", "Heading 2", "Heading 3", "Text", "Bold", "Italic", "Underline", "Strikethrough"; title "Format Selection" (STR). Layout vertical or horizontal (FM).
- Markdown-style shortcuts (FM `MarkdownTransformType` + STR regexes): `*word*` bold, `_word_` italic, `-word-` strikethrough, `#`/`##`/`###` headings (guess for the trigger text), list markers with indent level, links, newline continues lists.
- Colours (`ARC_ArcRichTextEditor`, light / dark): body #000 / #FFF; header and list marker #6E678D / #CDCDFF; link #220C7F / #E6E6FF; cursor #2702C2 / #9380E0; selection #CDCDFF / #5235CE; placeholder 40 %; format menu background #FFFFFF / #120F2E, border #CDCCDF / #34334D, text #6E678D / #8795C1, hover #EBEBEC / white 15 %, selected item #2702C2 (bg 10 %) / #B6C9FA (bg #062E79). Main catalog `NotesBackground` white 85 % / black 50 %, `NoteTitleText` #1C177A 80 % / white.
- Errors: "Can't load this note" + "Maybe it's private... maybe it doesn't exist... maybe your dog unplugged the router again?"; "Please authenticate to view this document"; "Update Arc to view this note"; "Failed to Upload Note" (STR).

### 4.6 Phase-out and export

- Flags (STR, both 170 and 172): `export-arc-notes-enabled`, `export-arc-notes-dialog-display-count`, `export-arc-notes-dialog-note-viewing-end-date`, `arc-note-export-document-timeout-in-seconds`, `disable-new-note-entry-points`, `disable-notes-editor`; state `notesDeprecationPhaseTwoEnabled`, `hideNewNoteEntryPoint`.
- Alert (STR): "We're saying goodbye to Arc Notes" with "You can still edit and create Arc Notes until %@ — after then, you will only be able to export them." (phase 1) or "…view Arc Notes until %@…" and "We've phased out Arc Notes … Don't worry, you can still export them!" (phase 2); buttons "Export notes" (guess for the visible title), "Thanks for the heads up".
- Export: `ExportedARCDocument {id, title, html, lastUpdatedAt}` per note; images inline as `data:image/png;base64`; zipped with the system `zip` into `Arc-Notes-Export-…` (STR "Running `zip` command"). Toasts "Exporting Notes", "No Notes found to export.", "Notes export failed." (STR). File names inside the zip: guess (one HTML per note).

## 5. Library ("Easels & Notes" page)

`HomeButton/EaselsAndNotesContentView.swift` (STR) is the Library page. Comments prove two title variants ("Title for Easels and Notes page" and "Title for Easels page") and two empty states ("Click the + sign in the Sidebar to create a new Easel or Note." / "…a new Easel."). Data sources `EaselLibraryClient` and `DocumentsLibraryClient`; delete allowed, hide not ("LibraryDataClient does not support hiding easels/documents"). Menu rows "View all Easels & Notes" / "Hide all Easels & Notes" and Easel-only variants (STR). In the 1.170 capture the tile title is "Easels" (library-overlay.md). Page layout, card size and thumbnail rule (`customOGImageID`): needs capture.

## 6. Consequences for Open today

- `OpenImport/ArcImport.swift` and `ArcProbe.swift` count `note` items; Arc writes `arcDocument`, so real Notes fall into "Skipped unknown". Fix when Notes import lands (or now, as a count-only change).
- Nothing on this Mac holds Easel content. Import of Easels needs the user's Arc 1.172 export zip (§3.8). Import of Notes needs the "Export Arc Notes" zip, or `StorableARCDocuments/` if a user still has local copies.

## 7. Not settled (needs capture)

Visible English values whose keys appear only as comments (Library page title, empty-state title, untitled placeholders, Arc Notes option title, menu titles of comment-only rows); toolbar position, size and order; tool hover texts; text menu; colour picker grid; pan and zoom gestures and limits; selection handles and snap-guide look; live web card toggle; capture → Easel flow; Easel sidebar icon; Notes editor margins, fonts and sizes; gutter and format menus; Default Document App menu; the Library Easels page and export card; New Note availability in 1.172 under the phase-out flags. See `F1-report.md` §3 for the session list.
