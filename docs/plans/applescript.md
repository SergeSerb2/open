# AppleScript / `Open.sdef` — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not copy Arc code or Arc files. Write every file in this plan from scratch.
Keep the same scripting **terms and four-character codes** so existing scripts work.
Reference behavior source: [features-advanced.md §10](../re/features-advanced.md).
Architecture context: [architecture.md](../architecture.md). Model context: [model.md](../model.md).
Command context: [commands.md](../commands.md). Milestone: M7 in [plan.md](../plan.md).

How to use this plan:

1. Work the steps in §12 in order. Do not skip ahead.
2. Each step lists exact files, exact signatures, and acceptance checks.
   A step is done only when its checks pass.
3. If a signature in this plan conflicts with the real `OpenEngine` API when it lands,
   keep the `OpenScripting` types in this plan and adapt only the thin app-side adapter in §7.
   Do not redesign the dictionary to fit a draft engine API.
4. No unit tests. Verify with the `osascript` checks in §11 against the real app, per AGENTS.md rule 6.
5. Never launch `/Applications/Arc.app`. Never read Arc script results from a running Arc.
   You may read `/Applications/Arc.app/Contents/Resources/Arc.sdef` read-only to confirm a code.
   Do not copy that file into this repo. Write `Open.sdef` from §3 of this plan.

---

## 0. Scope and non-scope

### 0.1 In scope (this plan)

| Area | Deliverable |
|---|---|
| Scripting dictionary | New file `App/Resources/Open.sdef`, our own XML, same suite, classes, properties, commands, and codes as Arc §10. Full XML in §3. |
| Cocoa Scripting layer | New `OpenScripting` library target in `Packages/OpenKit`. Wrapper classes over `BrowserModel`, `NSScriptCommand` handling, object specifiers, KVC accessors. No engine import. |
| App-side adapter | Thin hooks in the App target: provide the live `BrowserModel`, provide an engine bridge for navigation and JavaScript, copy `Open.sdef` to the bundle, set two `Info.plist` keys. Exact hooks in §7. |
| Compatibility | `tell application "Open"` scripts that used `tell application "Arc"` work after the user changes only the app name. Raycast-style queries in §11.4 must pass. |
| Verification | `osascript` and JXA check list in §11. Run against the built `Open.app` on this Mac. |

### 0.2 Out of scope (do not build)

- Scripting for Easels, Notes, Arc Max, accounts, or sync. Arc §10 does not expose them. Do not add classes for them.
- A `space` creation verb. `make new space` is not supported in v1. See §5.7 and open question Q2.
- Scripting access to passwords, history search, downloads, or extensions. Not in Arc §10. Do not invent properties.
- AppleScript recording, `osascript` inside the app, or a script editor UI.
- Changing `OpenModel` persisted fields to fit scripting. Scripting reads the live model. If a field is missing, add a wrapper computed property, not a stored field.
- Showing the word "Arc" in any UI, menu, dialog, or error string. The word "Arc" may appear only in code comments that explain compatibility, in this plan, and in `docs/re/`. The app name that scripts see is "Open".

### 0.3 Brand and naming rule

- Bundle display name is `Open`. `application name` returns `"Open"`.
- Suite name stays `Standard Suite`, code `core`. Class and command **names** stay the same words Arc uses (`window`, `tab`, `space`, `go back`, and so on) because scripts match on those names. Those words are facts, not brand assets.
- Cocoa class names in our code are ours: `ScriptWindow`, `ScriptSpace`, `ScriptTab`. Do not use Arc's names `AppleScriptWindowWrapper`, `AppleScriptTabWrapper`, or `AppleScriptSpaceWrapper` in our sources. The `cocoa class` attributes in §3 already use our names.
- Never copy Arc icons, strings files, or nibs. Every description string in §3 is written for Open.

---

## 1. Locked facts from the behavior spec (do not re-derive)

These are facts from `docs/re/features-advanced.md` §10. Implement these; do not re-investigate Arc.

| ID | Fact | Where it lands in this plan |
|---|---|---|
| AS-1 | Same suite (`Standard Suite`, `core`), same class names and codes, same property names and codes, same command codes. Quirks are part of the contract: `CrSuFwd ` has a trailing space, `ID  ` is `I` `D` plus two spaces, `URL ` is `U` `R` `L` plus one space, class codes are `WiND`, `tAbB`, `sPaC`. | §3 (full XML), §13.1 (code table) |
| AS-2 | Access modes match: `id`, `title`, `loading`, `active tab`, `active space` are read-only. `URL`, `location`, `minimized`, `visible`, `zoomed`, `index` are writable. `application.tab` is write-only in behavior. | §3, §5 |
| AS-3 | Object graph: `application` → `window` → (`tab`, `space`); `space` → `tab`. IDs are stable strings. | §4 |
| AS-4 | Implementation is ours. Only the scripting surface must match. | §2, §5 |
| §10.1 | `tab.location` strings are exactly `topApp`, `pinned`, `unpinned`. Setting `location` moves the tab between sidebar sections. | §5.5 |
| §10.1 | `window.mode` is `normal` or `incognito`. It can be set only once, at creation. Later sets have no effect and return an error. | §5.6 |
| §10.1 | `make new tab` on `application` creates a Little Arc tab. `make new tab` on a `window` or `space` creates a normal tab in that container. | §5.7 |
| §10.1 | `window.active tab` and `window.active space` are read-only. Use the `select` command to change the active tab. There is no writable active-tab property. | §3, §6.3 |
| §10.2 | Commands: `make` (`corecrel`), `count` (`corecnte`), `close` (`coreclos`), `select` (`CrSelect`), `go back` (`CrSuBack`), `go forward` (`CrSuFwd `), `reload` (`CrSuRlod`), `stop` (`CrSustop`), `execute` (`CrSuExJa` with `javascript` / `JvSc`, returns text), `focus` (`SpaFocus`). `application` responds to `quit`. | §3, §6 |
| §10.2 | `go back` / `go forward` are no-ops when there is no entry. They do not return an error in that case. | §6.4 |
| §10.4 Q1–Q3 | Three Arc behaviors are unverified: `execute` string form and JS-error behavior, `make new space` support, and `location` ordering. This plan fixes a default for each and marks it. See §14. | §6.6, §5.7, §5.5 |

Evidence note: `Arc.sdef` was read from `/Applications/Arc.app/Contents/Resources/Arc.sdef` on 2026-10-25.
`plutil -p /Applications/Arc.app/Contents/Info.plist` shows `NSAppleScriptEnabled = true` and
`OSAScriptingDefinition = Arc.sdef`. Open uses the same two keys with its own file name.

---

## 2. Package and file inventory

### 2.1 Package change (only build-system edit in `Packages/OpenKit`)

Edit exactly one existing build file: [Package.swift](../../Packages/OpenKit/Package.swift).

Current products include `OpenModel`, `OpenStore`, `OpenImport`, `OpenSuggest`, `OpenCommands`,
and executables `openkit` and `commands-dump`. Add one library product and one target.
`OpenScripting` depends on `OpenModel` and `OpenCommands` only.
Do not make `OpenScripting` depend on `OpenStore`, `OpenImport`, `OpenSuggest`, or any engine target.
Do not edit any file under `Sources/OpenModel/` or `Sources/OpenCommands/` in this milestone.

```swift
// In products: add
.library(name: "OpenScripting", targets: ["OpenScripting"]),

// In targets: add
.target(
    name: "OpenScripting",
    dependencies: ["OpenModel", "OpenCommands"]
),
```

Do not add `OpenScripting` to the `openkit` or `commands-dump` executable targets.
Verification is through the real app and `osascript` (§11), not through a CLI.

### 2.2 New files in `OpenScripting` (create exactly these)

```
Packages/OpenKit/Sources/OpenScripting/
  ScriptHost.swift            §5.1  ScriptHost protocol + shared holder the App target fills
  ScriptApplication.swift     §5.2  NSApplication scripting category: windows, tabs (write-only), name/frontmost/version, quit
  ScriptWindow.swift          §5.3  ScriptWindow wrapper over BrowserWindowState + NSWindow
  ScriptSpace.swift           §5.4  ScriptSpace wrapper over Space
  ScriptTab.swift             §5.5  ScriptTab wrapper over Tab
  ScriptCommands.swift        §6    NSScriptCommand subclasses: select, go back/forward, reload, stop, execute, focus, plus make/count/close glue
  ScriptEngineBridge.swift    §7.2  ScriptEngineBridge protocol (app implements it over OpenEngine)
  ScriptErrors.swift          §8    error numbers, messages, NSScriptCommand error helper
```

All eight files are `@MainActor` unless a section says otherwise.
Every wrapper is a `final class … : NSObject`. NSObject is required for KVC and for Cocoa Scripting.
Do not make wrappers `struct` or `Sendable` value types.

### 2.3 App-side files (App target — built by another agent; this plan lists the hooks)

The App target does not exist in this checkout yet. The implementer of this plan creates only the
`OpenScripting` target and the `Open.sdef` file. The App agent later wires these four hooks.
Until the App target exists, Steps 1–4 in §12 verify by `swift build` only. Steps 5–7 verify with `osascript`.

| Hook | Exact location when the App target lands | What it must do |
|---|---|---|
| H1 — model provider | `App/AppDelegate.swift`, in `applicationDidFinishLaunching` | Set `ScriptHost.shared.modelProvider = { browserModel }` and `ScriptHost.shared.windowProvider = { nsWindow in … }`. See §7.1 for the exact closure types. |
| H2 — engine bridge | `App/Scripting/AppScriptEngineBridge.swift` (new file, App target only) | Conform to `ScriptEngineBridge` (§7.2). Forward each call to `OpenEngine`. This file is the only App file that imports both `OpenScripting` and `OpenEngine`. |
| H3 — dictionary file | `App/Resources/Open.sdef` | Copy of the XML in §3, written from scratch. Add it to the App target's Resources build phase so it lands at `Open.app/Contents/Resources/Open.sdef`. |
| H4 — Info.plist keys | `App/Info.plist` | Add `NSAppleScriptEnabled` and `OSAScriptingDefinition`. Exact XML in §9.1. |

If the App target's folder layout differs, keep the hook **names** (`ScriptHost.shared.modelProvider`,
`ScriptHost.shared.engineBridge`) and move only the file paths. Do not rename the protocol or the holder.

### 2.4 Files the implementer must read before coding (already in repo)

- [Packages/OpenKit/Sources/OpenModel/Identifiers.swift](../../Packages/OpenKit/Sources/OpenModel/Identifiers.swift) — `Identifier<Tag>`, `ItemID`, `SpaceID`, `WindowID`, `ProfileID`. IDs are `UUID`-backed. Scripting exposes `rawValue.uuidString`.
- [Packages/OpenKit/Sources/OpenModel/LiveNodes.swift](../../Packages/OpenKit/Sources/OpenModel/LiveNodes.swift) — `Tab` (`id`, `url`, `title`, `customTitle`, `displayTitle`, `live.isLoading`), `Folder`, `Split`, `SidebarNode`.
- [Packages/OpenKit/Sources/OpenModel/Containers.swift](../../Packages/OpenKit/Sources/OpenModel/Containers.swift) — `Space` (`id`, `title`, `pinned`, `today`, `profileID`), `Profile` (`favorites`), `BrowserWindowState` (`id`, `focusedSpaceID`, `selectedNodeBySpace`, `style`).
- [Packages/OpenKit/Sources/OpenModel/BrowserModel.swift](../../Packages/OpenKit/Sources/OpenModel/BrowserModel.swift) — `BrowserModel` (`spaces`, `windows`, `profiles`, `tab(id:)`, `parent(of:)`, `isPinned(tabID:)`, `newTab(in:url:title:at:)`, `closeTab(id:)`, `moveNode(id:to:at:)`, `addFavorite(tabID:to:at:)`, `removeFavorite(tabID:into:)`, `focusSpace(windowID:spaceID:)`, `selectNode(windowID:spaceID:nodeID:)`, `createSpace(title:profileID:…)`).
- [Packages/OpenKit/Sources/OpenCommands/MenuBuilder.swift](../../Packages/OpenKit/Sources/OpenCommands/MenuBuilder.swift) — `CommandDispatcher` protocol (`performCommand(_:)`, `performCommand(_:payload:)`, `isCommandEnabled(_:enabledKey:)`). Scripting does **not** route tab commands through the dispatcher. See §6.1.

### 2.5 Naming rules

- Wrapper types: `ScriptWindow`, `ScriptSpace`, `ScriptTab`. File names match type names.
- KVC keys match the `cocoa key` values in §3 exactly, including case: `appleScriptWindows`, `appleScriptTabs`, `appleScriptSpaces`, `activeTab`, `activeSpace`, `orderedIndex`, `hasCloseBox`, `isMiniaturizable`, `isMiniaturized`, `isResizable`, `isVisible`, `isZoomable`, `isZoomed`, `isIncognito`, `isActive`, `URL`, `location`.
- Scripting IDs on the wire are lowercase UUID strings? No. Use `UUID.uuidString` as-is (uppercase hex with hyphens). `Identifier.description` already returns `rawValue.uuidString`. Scripts compare IDs as opaque text; case must be stable. Always return `id.rawValue.uuidString` and always parse with `UUID(uuidString:)` which accepts either case.
- Do not add a prefix such as `open-` to any scripting ID. Raycast and user scripts store Arc IDs and compare them only within one app run. Open IDs are Open UUIDs. Stability across launches comes from the persisted model, not from a prefix.

---

## 3. `Open.sdef` — the complete dictionary (write this file from scratch)

Create `App/Resources/Open.sdef` with **exactly** the XML below. Type it fresh in the editor.
Do not copy `/Applications/Arc.app/Contents/Resources/Arc.sdef` into the repo and do not copy the
evidence file `.re/features-advanced/Arc.sdef.xml` into `App/`. The terms and codes must match;
the Cocoa class names, description wording, and file layout are ours.

Rules for this file:

- Suite: one suite only, `Standard Suite`, code `core`.
- Classes: `application` (`capp`), `window` (`WiND`), `tab` (`tAbB`), `space` (`sPaC`). No other classes.
- Commands: `make`, `count`, `close`, `select`, `go back`, `go forward`, `reload`, `stop`, `execute`, `focus`. Plus `application` responds to `quit`. No other commands.
- Preserve the padded codes exactly: `ID  ` (I, D, space, space), `URL ` (U, R, L, space), `CrSuFwd ` (C, r, S, u, F, w, d, space). In XML, write the trailing space inside the attribute value. Do not trim it.
- `access` attributes must match §10: read-only where Arc is read-only. Where Arc omits `access`, the default is read-write; keep the omission so the access matches.
- Every `cocoa key` and `cocoa class` / `cocoa method` value below is normative. The Swift code in §5–§6 implements these exact keys and selectors.
- After you create the file, validate it (Step 1, §12): `xmllint --noout App/Resources/Open.sdef` and `sdef /Applications/Arc.app/Contents/Resources/Arc.sdef` is **not** a check for Open. The check for Open is in §11.1: Script Editor must show the Open dictionary with no missing terms.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
<dictionary title="Open">
  <!--
    Standard Suite. Terms and four-character codes match the public
    scripting surface that existing scripts and the Raycast extension use.
    This file is written for Open. It is not a copy of any other app's file.
  -->
  <suite name="Standard Suite" code="core" description="Common classes and commands for all applications.">

    <command name="make" code="corecrel" description="Make a new object.">
      <cocoa class="NSCreateCommand"/>
      <access-group identifier="*"/>
      <parameter name="new" code="kocl" description="The class of the new object." type="type">
        <cocoa key="ObjectClass"/>
      </parameter>
      <parameter name="with properties" code="prdt" type="record" optional="yes" description="The initial values for properties of the object.">
        <cocoa key="KeyDictionary"/>
      </parameter>
      <result description="to the new object" type="specifier"/>
    </command>

    <command name="count" code="corecnte" description="Return the number of elements of a particular class within an object.">
      <cocoa class="NSCountCommand"/>
      <access-group identifier="*"/>
      <direct-parameter description="the object whose elements are to be counted" type="specifier"/>
      <parameter name="each" code="kocl" description="The class of objects to be counted." type="type" optional="yes">
        <cocoa key="ObjectClass"/>
      </parameter>
      <result description="the number of elements" type="integer"/>
    </command>

    <class name="application" code="capp" description="The application's top-level scripting object.">
      <cocoa class="NSApplication"/>
      <element description="The windows contained within this application, ordered front to back." type="window">
        <cocoa key="appleScriptWindows"/>
      </element>
      <property name="name" code="pnam" description="The name of the application." type="text" access="r"/>
      <property name="frontmost" code="pisf" description="Is this the frontmost (active) application?" type="boolean" access="r">
        <cocoa key="isActive"/>
      </property>
      <property name="version" code="vers" description="The version of the application." type="text" access="r"/>
      <responds-to command="quit">
        <cocoa method="handleQuitScriptCommand:"/>
      </responds-to>
      <element description="The tabs associated with this application. This is a write-only collection that allows you to create new Little Arc tabs. In Open, these are Little Open windows." type="tab" access="w">
        <cocoa key="appleScriptTabs"/>
      </element>
    </class>

    <command name="close" code="coreclos" description="Close an object.">
      <direct-parameter description="The object to execute the command on." type="specifier"/>
    </command>

    <class name="window" code="WiND" description="A browser window." plural="windows">
      <cocoa class="ScriptWindow"/>
      <element description="The tabs contained within this window." type="tab" access="rw">
        <cocoa key="appleScriptTabs"/>
      </element>
      <element description="The spaces accessible within this window." type="space">
        <cocoa key="appleScriptSpaces"/>
      </element>
      <property name="id" code="ID  " type="text" access="r" description="The unique identifier of the window.">
        <cocoa key="id"/>
      </property>
      <property name="name" code="pnam" type="text" access="r" description="The full title of the window.">
        <cocoa key="title"/>
      </property>
      <property name="index" code="pidx" type="integer" description="The index of the window, ordered front to back.">
        <cocoa key="orderedIndex"/>
      </property>
      <property name="closeable" code="hclb" description="Whether the window has a close box." type="boolean" access="r">
        <cocoa key="hasCloseBox"/>
      </property>
      <property name="minimizable" code="ismn" description="Whether the window can be minimized." type="boolean" access="r">
        <cocoa key="isMiniaturizable"/>
      </property>
      <property name="minimized" code="pmnd" description="Whether the window is currently minimized." type="boolean">
        <cocoa key="isMiniaturized"/>
      </property>
      <property name="resizable" code="prsz" description="Whether the window can be resized." type="boolean" access="r">
        <cocoa key="isResizable"/>
      </property>
      <property name="visible" code="pvis" description="Whether the window is currently visible." type="boolean">
        <cocoa key="isVisible"/>
      </property>
      <property name="zoomable" code="iszm" description="Whether the window can be zoomed." type="boolean" access="r">
        <cocoa key="isZoomable"/>
      </property>
      <property name="zoomed" code="pzum" description="Whether the window is currently zoomed." type="boolean">
        <cocoa key="isZoomed"/>
      </property>
      <property name="active tab" code="acTa" description="Returns the currently selected tab." type="tab" access="r">
        <cocoa key="activeTab"/>
      </property>
      <property name="active space" code="acSp" description="Returns the currently active space." type="space" access="r">
        <cocoa key="activeSpace"/>
      </property>
      <property name="incognito" code="inco" description="Whether the window is an incognito window." type="boolean">
        <cocoa key="isIncognito"/>
      </property>
      <property name="mode" code="mode" description="Represents the mode of the window which can be 'normal' or 'incognito', can be set only once during creation of the window." type="text">
        <cocoa key="mode"/>
      </property>
      <responds-to command="close">
        <cocoa method="close:"/>
      </responds-to>
    </class>

    <command name="select" code="CrSelect" description="Select the tab.">
      <direct-parameter description="The tab to execute the command in." type="specifier"/>
    </command>

    <command name="go back" code="CrSuBack" description="Go Back (If Possible).">
      <direct-parameter description="The tab to execute the command in." type="specifier"/>
    </command>

    <command name="go forward" code="CrSuFwd " description="Go Forward (If Possible).">
      <direct-parameter description="The tab to execute the command in." type="specifier"/>
    </command>

    <command name="reload" code="CrSuRlod" description="Reload a tab.">
      <direct-parameter description="The tab to execute the command in." type="specifier"/>
    </command>

    <command name="stop" code="CrSustop" description="Stop the current tab from loading.">
      <direct-parameter description="The tab to execute the command in." type="specifier"/>
    </command>

    <command name="execute" code="CrSuExJa" description="Execute a piece of javascript.">
      <direct-parameter description="The tab to execute the command in." type="specifier"/>
      <parameter name="javascript" code="JvSc" description="The javascript code to execute." type="text">
        <cocoa key="javascript"/>
      </parameter>
      <result type="text"/>
    </command>

    <class name="tab" code="tAbB" description="A browser tab." plural="tabs">
      <cocoa class="ScriptTab"/>
      <property name="id" code="ID  " type="text" access="r" description="The unique identifier of the tab.">
        <cocoa key="id"/>
      </property>
      <property name="title" code="pnam" type="text" access="r" description="The full title of the tab.">
        <cocoa key="title"/>
      </property>
      <property name="URL" code="URL " description="The url of the tab." type="text" access="rw">
        <cocoa key="URL"/>
      </property>
      <property name="loading" code="ldng" description="Is loading?" type="boolean" access="r"/>
      <property name="location" code="loca" description="Represents the location of the tab in the sidebar. Can be 'topApp', 'pinned', or 'unpinned'." type="text">
        <cocoa key="location"/>
      </property>
      <responds-to command="select">
        <cocoa method="select:"/>
      </responds-to>
      <responds-to command="go back">
        <cocoa method="goBack:"/>
      </responds-to>
      <responds-to command="go forward">
        <cocoa method="goForward:"/>
      </responds-to>
      <responds-to command="reload">
        <cocoa method="reload:"/>
      </responds-to>
      <responds-to command="stop">
        <cocoa method="stopLoading:"/>
      </responds-to>
      <responds-to command="execute">
        <cocoa method="executeJavascript:"/>
      </responds-to>
      <responds-to command="close">
        <cocoa method="close:"/>
      </responds-to>
    </class>

    <command name="focus" code="SpaFocus" description="Focus on a space.">
      <direct-parameter description="The space to focus." type="specifier"/>
    </command>

    <class name="space" code="sPaC" description="A space." plural="spaces">
      <cocoa class="ScriptSpace"/>
      <property name="id" code="ID  " type="text" access="r" description="The unique identifier of the space.">
        <cocoa key="id"/>
      </property>
      <property name="title" code="pnam" type="text" access="r" description="The full title of the space.">
        <cocoa key="title"/>
      </property>
      <element description="The tabs contained within this space." type="tab" access="rw">
        <cocoa key="appleScriptTabs"/>
      </element>
      <responds-to command="focus">
        <cocoa method="focus:"/>
      </responds-to>
    </class>
  </suite>
</dictionary>
```

Open-specific notes on this dictionary (read before you change anything):

- The `application.tab` element description in Arc says "Little Arc tabs". Our file says "Little Open windows" in the same element. The **term** (`tab`), the **code path**, and the **behavior** (create a small standalone tab window) match. The product name in prose is ours. Do not change the element type or the `appleScriptTabs` key to chase wording.
- Cocoa class names are `ScriptWindow`, `ScriptTab`, `ScriptSpace`, not Arc's wrapper names. This is required by AS-4. Scripts do not see Cocoa class names; they see terms and codes only.
- The `window` property `mode` and the `tab` property `location` have no explicit `access` attribute in Arc's file, so they are read-write by default. Keep the omission. Do not add `access="rw"`; the meaning is the same, but a byte-level diff against the term table in §13.1 stays clean when the plan's table is generated from this file.
- The `tab.loading` property has no `cocoa key` child in Arc's file. Keep the omission. §5.5 supplies the value through KVC with the property name `loading` itself. Do not invent a different key.
- Do not add `enumeration`, `record-type`, or a second suite. Arc has none. Extra terms break the "exactly the set in §10" rule and can shadow Standard Suite terms from other apps.

### 3.1 Term and code checklist (normative)

Generate this table from the file above. Every row must match §10. If a row differs, the file is wrong.

| Kind | Name | Code (in quotes; `_` shows a space) | Access / notes |
|---|---|---|---|
| suite | Standard Suite | `core` | — |
| command | make | `corecrel` | `NSCreateCommand` |
| command | count | `corecnte` | `NSCountCommand` |
| command | close | `coreclos` | via `close:` on window/tab |
| command | select | `CrSelect` | direct param: tab |
| command | go back | `CrSuBack` | direct param: tab |
| command | go forward | `CrSuFwd_` | trailing space is required |
| command | reload | `CrSuRlod` | direct param: tab |
| command | stop | `CrSustop` | selector `stopLoading:` |
| command | execute | `CrSuExJa` | param `javascript` / `JvSc`, returns text |
| command | focus | `SpaFocus` | direct param: space, selector `focus:` |
| class | application | `capp` | `NSApplication` |
| class | window | `WiND` | `ScriptWindow` |
| class | tab | `tAbB` | `ScriptTab` |
| class | space | `sPaC` | `ScriptSpace` |
| property (all) | id | `ID__` | two trailing spaces; on window/tab/space, r |
| property | URL | `URL_` | one trailing space; on tab, rw |
| property | active tab | `acTa` | on window, r |
| property | active space | `acSp` | on window, r |
| property | loading | `ldng` | on tab, r |
| property | location | `loca` | on tab, rw, values in §5.5 |

---

## 4. Object graph, identity, and flattening rules

Scripts see four object kinds. The live model has more kinds (`Folder`, `Split`, `Profile`).
Scripting flattens the model. This section is normative. Implement it exactly.

### 4.1 Graph

```
application (NSApplication)
  ├─ window*  (ScriptWindow)          ordered front to back, index 1-based in AppleScript
  │    ├─ tab*    (ScriptTab)         all tabs in the window, see §4.3
  │    └─ space*  (ScriptSpace)       all spaces in the window, model order
  └─ tab* (write-only)                make-only; creates a Little Open tab, see §5.7
space (ScriptSpace)
  └─ tab* (ScriptTab)                 tabs in that space, see §4.3
```

- `application.windows` returns one `ScriptWindow` per `BrowserWindowState` in `BrowserModel.windows`, ordered front to back. Front-to-back means: key window first, then by `NSWindow.orderedIndex`? No. The model does not store z-order. Use `NSApplication.shared.windows` filtered to browser windows, ordered as AppKit returns them (front to back), and map each `NSWindow` to its `BrowserWindowState` through `ScriptHost.windowStateID(for:)`. If the App target cannot map an `NSWindow`, skip it. Never invent a window that has no `NSWindow`.
- `window.spaces` returns one `ScriptSpace` per `BrowserModel.spaces` entry, in model order. Every window shows the same Space list in Open v1 (Spaces are per-profile-set, windows share them; the focused Space differs per window). Do not filter Spaces by window. The focused Space is `window.active space`.
- `window.active space` is the `ScriptSpace` for `BrowserWindowState.focusedSpaceID`.
- `window.active tab` is the `ScriptTab` for `BrowserWindowState.selectedNodeBySpace[focusedSpaceID]`. If that node is a `Folder` or `Split`, resolve to the split's focused pane tab, or the first tab inside the folder in depth-first order. If there is no selection, return `missing value` (nil specifier). Never crash.

### 4.2 Identity and ID strings

- Window ID text: `BrowserWindowState.id.rawValue.uuidString`.
- Space ID text: `Space.id.rawValue.uuidString`.
- Tab ID text: `Tab.id.rawValue.uuidString`. `ItemID` and the tab's `id` are the same value.
- IDs are stable for the life of the object and across launches, because the model persists them. Do not generate a new UUID in a wrapper getter. The wrapper reads the model's ID.
- Lookup by ID text: parse with `UUID(uuidString:)`. If parsing fails, the object does not exist. Return error 1000 (§8). Compare against `rawValue` after parsing. Never compare lowercased strings.
- Wrapper identity: within one script evaluation, the same model object must vend the same wrapper instance for `is equal` / `whose` tests to behave. `ScriptHost` keeps a weak cache (§5.1): `[WindowID: ScriptWindow]`, `[SpaceID: ScriptSpace]`, `[ItemID: ScriptTab]`. Wrappers are created on demand and reused. A wrapper holds a weak reference to its model object plus the `BrowserModel`. If the model object leaves the tree (tab closed, Space deleted), the wrapper's getters return error 1000 and its `objectSpecifier` still returns its last unique ID so the error message can name it.

### 4.3 Which tabs a container returns (flattening)

The model nests tabs inside `Folder.children` and `Split.panes`, and splits tabs across
`Space.pinned`, `Space.today`, and `Profile.favorites`. Scripts see a flat list.

- `space.appleScriptTabs`: walk `Space.pinned` then `Space.today`, depth-first. For a `Folder`, yield its children in order (recursively). For a `Split`, yield its `panes` in pane order. For a `Tab`, yield it. Favorites are **not** in a Space. Do not include them here.
- `window.appleScriptTabs`: concatenation, in Space order, of each Space's flattened tabs, followed by the focused profile's `favorites` flattened the same way. The focused profile is the profile of `window.active space`. If the window has no active Space, use the first Space's profile, or if there are no Spaces, return an empty list. Order is normative: Raycast lists tabs in this order. Document it in the PR.
- `application.appleScriptTabs` (read): write-only. A `get` returns error 1004 (§8) with message "tabs of application is write-only; make a new tab on application to create a Little Open window, or read tabs of a window or space." A `count` on it returns error 1004 as well. Only `make` writes to it. See §5.7. This matches AS-2: the element is `access="w"` in the sdef.
- Index semantics: AppleScript indices are 1-based. `tab 1 of space 1` is the first flattened tab. KVC array access in §5 uses 0-based Swift arrays; the Cocoa Scripting layer converts. Do not off-by-one: `objectInAppleScriptTabsAtIndex:` receives a 0-based index from KVC. Test A3 in §11 checks this.

### 4.4 What scripts cannot see

Folders and splits have no scripting class. A script cannot address a folder. Moving a tab out of a folder by `set location` or by `set URL` keeps the tab's folder membership except for the `location` moves in §5.5, which explicitly reparent it. Closing a split pane tab through scripting calls `BrowserModel.closeTab(id:)`, which collapses a one-pane split per model rules. Do not add folder or split terms to work around this.

---

## 5. Cocoa Scripting implementation — wrappers and KVC

Cocoa Scripting finds objects through `NSScriptClassDescription` (built from the sdef at launch),
then reads and writes them with KVC (`value(forKey:)` / `setValue(_:forKey:)`), and runs commands
through `NSScriptCommand` or through `responds-to` methods on the direct object.
All scripting runs on the main thread. Every type in this section is `@MainActor`.

### 5.1 `ScriptHost.swift` — the holder the App target fills

`OpenScripting` never creates a `BrowserModel`. The App target owns the one live model.
`ScriptHost` is the single bridge. Define it exactly as below.

```swift
import AppKit
import Foundation
import OpenModel

/// Filled by the App target at launch. Read on the main actor only.
/// OpenScripting never creates a BrowserModel and never imports the engine.
@MainActor
public final class ScriptHost {
    public static let shared = ScriptHost()
    private init() {}

    /// Returns the one live model. The App target sets this in applicationDidFinishLaunching.
    /// Nil before launch finishes: every scripting getter then returns error 1005.
    public var modelProvider: (() -> BrowserModel?)?

    /// Returns the engine bridge. Nil until the engine is ready:
    /// navigation and execute then return error 1006, reads still work.
    public var engineBridge: (any ScriptEngineBridge)?

    /// Maps an NSWindow to its BrowserWindowState id. The App target sets this.
    /// Returns nil for panels and non-browser windows: scripting skips those windows.
    public var windowStateID: ((NSWindow) -> WindowID?)?

    /// Maps a BrowserWindowState id back to its NSWindow. Nil means the window is not on screen.
    public var windowForState: ((WindowID) -> NSWindow?)?

    /// Creates a Little Open window for `make new tab` on application. The App target sets this.
    /// Returns the new tab id, or nil on failure. OpenScripting does not create windows itself.
    public var makeLittleTab: ((URL?) -> ItemID?)?

    /// Creates a new browser window state + NSWindow for `make new window`.
    /// The second value is true when the caller asked for incognito. Returns the new window id.
    public var makeWindow: ((Bool) -> WindowID?)?

    public var model: BrowserModel? { modelProvider?() }

    // Wrapper caches. Weak values: a wrapper lives only while a script or the cache holds it.
    // NSMapTable with weak values is not @MainActor-friendly in Swift 6; use dictionaries of WeakBox.
    var windowWrappers: [WindowID: ScriptWindow] = [:]
    var spaceWrappers: [SpaceID: ScriptSpace] = [:]
    var tabWrappers: [ItemID: ScriptTab] = [:]

    public func windowWrapper(for state: BrowserWindowState) -> ScriptWindow {
        if let w = windowWrappers[state.id], w.stateID == state.id { return w }
        let w = ScriptWindow(state: state)
        windowWrappers[state.id] = w
        return w
    }
    public func spaceWrapper(for space: Space) -> ScriptSpace {
        if let s = spaceWrappers[space.id] { return s }
        let s = ScriptSpace(space: space)
        spaceWrappers[space.id] = s
        return s
    }
    public func tabWrapper(for tab: Tab) -> ScriptTab {
        if let t = tabWrappers[tab.id] { return t }
        let t = ScriptTab(tab: tab)
        tabWrappers[tab.id] = t
        return t
    }
}
```

Notes:

- Do not store `BrowserModel` in a global `let`. The model is created by the App target and can be replaced on profile switch. Always read `ScriptHost.shared.model`.
- If `model` is nil, every property getter and every command returns error 1005 ("Open is not ready."). Do not return empty lists to hide a missing model; an empty list is a valid answer when the model exists and has no tabs.
- The caches use strong references so wrapper identity is stable during a script run. Purge an entry when its model object leaves the tree: `ScriptTab` calls `ScriptHost.shared.tabWrappers[tabID] = nil` from its `close` path, and the App target's model observer purges on `.remove` tree changes. A stale wrapper that is still retained by a script returns error 1000 from its getters instead of stale data. Check `model.tab(id:) != nil` before every read.

### 5.2 `ScriptApplication.swift` — `NSApplication` scripting

Cocoa Scripting uses `NSApplication` itself as the `application` object (`cocoa class="NSApplication"`).
You cannot subclass it. Add the scripting surface in an extension. The sdef keys are
`appleScriptWindows`, `appleScriptTabs`, `isActive`, plus the inherited `name` and `version`.

```swift
import AppKit
import Foundation
import OpenModel

extension NSApplication {
    /// Ordered front to back. Key: appleScriptWindows.
    @objc dynamic var appleScriptWindows: [ScriptWindow] {
        // Implementation in prose below; do not put @MainActor on an @objc dynamic var
        // without checking the compiler. If Swift 6 rejects it, wrap the body in
        // MainActor.assumeIsolated { … } because Apple events arrive on the main thread.
    }
}
```

Implement the extension as follows (write the bodies, not just the signatures):

- `appleScriptWindows`: get `ScriptHost.shared.model`. If nil, return `[]` and set no error; `NSApplication` getters cannot throw, so the `count windows` check in §11 A1 still returns 0 before launch and the real count after. Map `NSApplication.shared.windows` in order, keep windows where `ScriptHost.shared.windowStateID?(window) != nil`, then map each state ID to its `BrowserWindowState` and vend `ScriptHost.shared.windowWrapper(for:)`. If `windowStateID` is nil (App hook not yet set), fall back to model order: `model.windows.map { ScriptHost.shared.windowWrapper(for: $0) }`.
- `appleScriptTabs` on `NSApplication`: the getter returns `[]`. The setter / insertion path is the write-only creation path. Cocoa calls `insertInAppleScriptTabs(_:at:)` and `insertInAppleScriptTabs(_:)` for `make`. Implement both to call the Little-tab creation in §5.7. A plain `get tabs of application` must error: KVC cannot throw from a getter, so the `ScriptMakeCommand` and count glue in §6.7 intercept reads of `application.tabs` before KVC and set error 1004. Document that a direct `value(forKey: "appleScriptTabs")` from Swift returns `[]`; only Apple-event evaluation goes through the interception. This is the one place where Swift-side KVC and script-side behavior differ, and §11 A14 checks the script side.
- `isActive`: return `NSApplication.shared.isActive`. The sdef maps `frontmost` (`pisf`) to this key. Do not add a separate `frontmost` property.
- `name` (`pnam`) and `version` (`vers`): do **not** implement them in the extension. AppKit already supplies `name` from the bundle and the scripting layer supplies `version` from `CFBundleShortVersionString`. Verify with §11 A1. If `version` returns empty in the debug build, add a getter that returns `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"`. Add it only if the check fails.
- `handleQuitScriptCommand:`: implement `@objc func handleQuitScriptCommand(_ command: NSScriptCommand) -> Any?` in the extension. It calls `NSApplication.shared.terminate(nil)` and returns nil. The sdef declares this through `responds-to command="quit"`. Do not add a `quit` command element to the sdef; there is none.

Also implement KVC insertion/removal stubs that Cocoa may call and that must not silently succeed:

- `insertInAppleScriptWindows(_ window: ScriptWindow, at index: Int)` and `removeFromAppleScriptWindows(at:)`: windows are created and closed only through `make new window` and `close`. If Cocoa calls these directly, set the current command's error to 1007 ("Use make new window and close window.") through `NSScriptCommand.current()` when one exists, and do nothing. Never insert a `ScriptWindow` into a Swift array and hope a real window appears.

### 5.3 `ScriptWindow.swift` — wrapper over `BrowserWindowState` + `NSWindow`

```swift
import AppKit
import Foundation
import OpenModel

@MainActor
public final class ScriptWindow: NSObject {
    public let stateID: WindowID
    // The live state object. Look it up by ID on every access; do not cache a stale copy
    // after a profile switch replaces the model.
    var state: BrowserWindowState? {
        ScriptHost.shared.model?.windows.first(where: { $0.id == stateID })
    }
    var nsWindow: NSWindow? { ScriptHost.shared.windowForState?(stateID) }

    init(state: BrowserWindowState) { self.stateID = state.id; super.init() }
}
```

KVC properties (each is `@objc dynamic var` unless it says otherwise; the key is the `cocoa key` in §3):

| Key | Swift signature | Read | Write |
|---|---|---|---|
| `id` | `@objc dynamic var id: String` | `stateID.rawValue.uuidString` | — (sdef r) |
| `title` | `@objc dynamic var title: String` | `nsWindow?.title ?? state.map { _ in "Open" } ?? "Open"`; if the window shows a tab, AppKit's title is the tab title. Never return the Space title here. | — |
| `orderedIndex` | `@objc dynamic var orderedIndex: Int` | 1-based position in `appleScriptWindows`. Compute by finding `stateID` in the application list. 0 if not on screen. | Setting reorders: call `nsWindow` ordering (`order(_:relativeTo:)`) through the App hook? No model command reorders windows. Implement the setter by bringing the window forward: if the new index is 1, `nsWindow?.makeKeyAndOrderFront(nil)`; otherwise set error 1007. See note below. |
| `hasCloseBox` | `@objc dynamic var hasCloseBox: Bool` | `nsWindow?.styleMask.contains(.closable) ?? true` | — |
| `isMiniaturizable` | `@objc dynamic var isMiniaturizable: Bool` | `nsWindow?.styleMask.contains(.miniaturizable) ?? true` | — |
| `isMiniaturized` | `@objc dynamic var isMiniaturized: Bool` | `nsWindow?.isMiniaturized ?? false` | `nsWindow?.miniaturize(nil)` / `deminiaturize(nil)` |
| `isResizable` | `@objc dynamic var isResizable: Bool` | `nsWindow?.styleMask.contains(.resizable) ?? true` | — |
| `isVisible` | `@objc dynamic var isVisible: Bool` | `nsWindow?.isVisible ?? false` | `true` → `orderFront`; `false` → `orderOut` |
| `isZoomable` | `@objc dynamic var isZoomable: Bool` | `nsWindow?.styleMask.contains(.resizable) ?? true` (AppKit has no separate zoomable mask bit on modern macOS; use resizable) | — |
| `isZoomed` | `@objc dynamic var isZoomed: Bool` | `nsWindow?.isZoomed ?? false` | `nsWindow?.zoom(nil)` toggles; set only when the value differs |
| `activeTab` | `@objc dynamic var activeTab: ScriptTab?` | §4.1 resolution. Nil → scripts see `missing value`. | — |
| `activeSpace` | `@objc dynamic var activeSpace: ScriptSpace?` | wrapper for `state.focusedSpaceID`. Nil only when the model has no Spaces. | — |
| `isIncognito` | `@objc dynamic var isIncognito: Bool` | `mode == "incognito"`. Until profiles/incognito land, always `false` for normal windows. See §5.6. | Setting after creation returns error 1008. Do not flip state. |
| `mode` | `@objc dynamic var mode: String` | `"incognito"` if the window was created incognito, else `"normal"`. Store the creation mode on the wrapper at `make` time in `ScriptHost` (`windowModes: [WindowID: String]`). Default `"normal"`. | Set only at creation (§5.7). Later sets return error 1008. |

`orderedIndex` setter note: Arc marks `index` (`pidx`) read-write. Cocoa will call the setter for `set index of window 2 to 1`. Full z-order control needs AppKit window ordering for every window, which the model does not own. Implement the useful subset (bring to front when set to 1; otherwise error 1007 with a clear message). Record this as a known limit in the PR. Do not pretend to reorder by mutating `model.windows` order; that order is creation order, not z-order, and mutating it would corrupt restore.

Element accessors (KVC to-many):

```swift
// Key: appleScriptTabs (window tabs, flattened per §4.3)
@objc dynamic var appleScriptTabs: [ScriptTab] { … }
@objc func countOfAppleScriptTabs() -> Int
@objc func objectInAppleScriptTabsAtIndex(_ index: Int) -> ScriptTab
@objc func insertInAppleScriptTabs(_ tab: ScriptTab, at index: Int)
@objc func removeFromAppleScriptTabs(at index: Int)

// Key: appleScriptSpaces
@objc dynamic var appleScriptSpaces: [ScriptSpace] { … }
@objc func countOfAppleScriptSpaces() -> Int
@objc func objectInAppleScriptSpacesAtIndex(_ index: Int) -> ScriptSpace
```

- `insertInAppleScriptTabs(_:at:)`: called by `make new tab at window`. The `ScriptTab` Cocoa passes is a blank instance created by `NSCreateCommand`. Do not insert that instance. Read its `URL` property (Cocoa sets `with properties` first), then call `BrowserModel.newTab(in:at:)` for the window's active Space and return the wrapper for the real tab through the command glue in §6.7. If you implement insertion literally, `make` returns a specifier to a tab that is not in the model. §6.7 owns this; the accessor here forwards to §6.7's helper `ScriptCreation.makeTab(inWindow:atIndex:properties:)`.
- `removeFromAppleScriptTabs(at:)`: resolve the tab at that flattened index and call `BrowserModel.closeTab(id:)`. Cocoa calls this for `delete tab 1 of window`. `delete` is not a declared command, but Cocoa may still route it. Support it; it costs three lines.
- Spaces have no insertion or removal accessors. `make new space` and `delete space` return error 1009 (§5.7).

Object specifier:

```swift
public override var objectSpecifier: NSScriptObjectSpecifier? {
    guard let cls = NSScriptClassDescription(for: NSApplication.self) else { return nil }
    return NSUniqueIDSpecifier(
        containerClassDescription: cls,
        containerSpecifier: nil,
        key: "appleScriptWindows",
        uniqueID: stateID.rawValue.uuidString
    )
}
```

### 5.4 `ScriptSpace.swift` — wrapper over `Space`

```swift
import Foundation
import OpenModel

@MainActor
public final class ScriptSpace: NSObject {
    public let spaceID: SpaceID
    var space: Space? { ScriptHost.shared.model?.space(id: spaceID) }
    init(space: Space) { self.spaceID = space.id; super.init() }
}
```

| Key | Swift signature | Read | Write |
|---|---|---|---|
| `id` | `@objc dynamic var id: String` | `spaceID.rawValue.uuidString` | — |
| `title` | `@objc dynamic var title: String` | `space?.title ?? ""`. If the Space is gone, return `""` and let command paths return error 1000. A getter cannot set a script error; commands check existence first. | — |

Element accessors for `appleScriptTabs`: same flattening as §4.3 for this Space only.
`insertInAppleScriptTabs(_:at:)` forwards to `ScriptCreation.makeTab(inSpace:atIndex:properties:)`.
`removeFromAppleScriptTabs(at:)` closes that tab through `BrowserModel.closeTab(id:)`.

Object specifier: `NSUniqueIDSpecifier` with container = the first window's specifier? Spaces are
contained by windows in the graph, but every window contains every Space. Cocoa needs a container.
Use the application as the container with key `appleScriptSpaces`? That key exists only on `window`.
To keep specifiers resolvable, use the **key window's** `ScriptWindow` object specifier as the container
and key `appleScriptSpaces`. If there is no window, fall back to a `NSNameSpecifier` by title.
Implement `objectSpecifier` as:

```swift
public override var objectSpecifier: NSScriptObjectSpecifier? {
    // Container is a window specifier (first window). Key is appleScriptSpaces.
    // uniqueID is the Space UUID string. Resolution walks window -> spaces -> unique ID.
}
```

Document this choice in the file header. The alternative (application-level spaces) would add a term
that Arc does not have. Do not add an `application.spaces` element to the sdef.

`focus:` responds-to method: see §6.5. The wrapper implements `@objc func focus(_ command: NSScriptCommand) -> Any?`.

### 5.5 `ScriptTab.swift` — wrapper over `Tab`

```swift
import Foundation
import OpenModel

@MainActor
public final class ScriptTab: NSObject {
    public let tabID: ItemID
    var tab: Tab? { ScriptHost.shared.model?.tab(id: tabID) }
    init(tab: Tab) { self.tabID = tab.id; super.init() }
    // Blank init for NSCreateCommand. Cocoa creates an empty instance, sets properties, then inserts it.
    // The insertion path in §6.7 reads `pendingURL` and creates the real tab. Never insert this instance.
    var pendingURL: String?
    override init() { self.tabID = ItemID(); super.init() }
}
```

Wait: `ItemID()` generates a new UUID. A blank tab must not enter the model with that ID.
Guard: `ScriptCreation` never inserts a blank `ScriptTab`. It reads `pendingURL` / the KVC `URL`
value and calls `BrowserModel.newTab`, which creates the real `Tab` with its own ID.
Delete the blank-init path if your `NSCreateCommand` flow does not need it; do not ship a path
that can insert a wrapper whose `tabID` is not in the model.

KVC properties:

| Key | Swift signature | Read | Write |
|---|---|---|---|
| `id` | `@objc dynamic var id: String` | `tabID.rawValue.uuidString` | — |
| `title` | `@objc dynamic var title: String` | `tab?.displayTitle ?? tab?.title ?? ""`. Use `displayTitle` (custom title wins). Raycast shows this value. | — |
| `URL` | `@objc dynamic var URL: String` | `tab?.url.absoluteString ?? ""` | Parse with `URL(string:)`. On success, set `tab.url` through the engine bridge `navigate` (§7.2), not by mutating `tab.url` alone — the page must load. If the tab has a `pinnedURL` and the tab is pinned or a favorite, update the live URL only; do not change `pinnedURL`. `resetPinnedTab` is a separate menu command, not a scripting setter. Invalid string → error 1001. See §6.2 note. |
| `loading` | `@objc dynamic var loading: Bool` | `tab?.live.isLoading ?? false`. Key is `loading` (no cocoa key child in the sdef). | — |
| `location` | `@objc dynamic var location: String` | Compute from `model.parent(of: tabID)` and the section walk: favorites → `"topApp"`, pinned section → `"pinned"`, today section → `"unpinned"`. A tab inside a folder or split reports its section, not `"folder"`. If the tab is not in the model, return `"unpinned"`. | See move table below. Unknown string → error 1002. |

`location` setter (normative). Current section is computed the same way as the getter.
The setter moves the tab to the **end** of the destination list (Arc ordering inside a section is
unverified; end-of-list is the documented default, open question Q3). Use model commands only:

| From → To | Model calls (in order) |
|---|---|
| any → `topApp` | `model.addFavorite(tabID:to: profileID, at: nil)`. Profile is the tab's Space profile; for a tab already in favorites, no-op. If the tab is a split pane, first `model.removePane(splitID:tabID:archive:false)`? No: favorites hold single tabs only and `addFavorite` on a pane is not valid. Return error 1003 ("A split pane cannot move to favorites. Separate it first.") |
| `topApp` → `pinned` | `model.removeFavorite(tabID:into: spaceID)` then `model.pinTab(id:)`. Space is the window's active Space, or the first Space of that profile. |
| `topApp` → `unpinned` | `model.removeFavorite(tabID:into: spaceID)`. |
| `unpinned` → `pinned` | `model.pinTab(id:)`. |
| `pinned` → `unpinned` | `model.unpinTab(id:)`. |
| `pinned`/`unpinned` → same value | No-op. Return without a model call so undo does not gain a step. |
| any → unknown | Error 1002. Do not move. |

After a move, `pinnedURL` handling is the model's job (§model.md pinned-URL rule). Do not set `pinnedURL` in the wrapper.

Object specifier: container is ambiguous — a tab lives under a window and under a space.
Use the **space** as the container when the tab has a Space parent, because `space.tabs` is the
narrower list and Raycast resolves `tab id "…" of space id "…"`. Implement:

```swift
public override var objectSpecifier: NSScriptObjectSpecifier? {
    // If the tab is a favorite, container is the window (window tabs include favorites).
    // Otherwise container is its Space specifier, key appleScriptTabs, uniqueID = tab UUID.
    // Fall back to the first window specifier when the Space cannot be found.
}
```

Responds-to methods on `ScriptTab`: `select:`, `goBack:`, `goForward:`, `reload:`, `stopLoading:`,
`executeJavascript:`, `close:`. Signatures and bodies are in §6. Each method has the form
`@objc func goBack(_ command: NSScriptCommand) -> Any?`. Return nil except `executeJavascript:`,
which returns the result string.

### 5.6 Window `mode` and `incognito` semantics

Open v1 has Profiles but no verified incognito window model in `OpenModel`
(`BrowserWindowState.style` is `.standard` / `.littleArc`; there is no incognito flag).
Do not add an incognito field to `OpenModel` in this milestone.

- Every existing window reports `mode == "normal"` and `isIncognito == false`.
- `make new window with properties {mode:"incognito"}`: the creation hook `ScriptHost.makeWindow`
  receives `isIncognito: true`. Until the App target supports incognito windows, the App hook
  returns nil and scripting returns error 1010 ("Incognito windows are not available in this build.").
  When incognito lands, the App hook creates the window and `ScriptHost.windowModes[windowID] = "incognito"`.
  The scripting layer does not change.
- Setting `mode` or `isIncognito` on an existing window returns error 1008 and changes nothing.
  The message is "mode can be set only once during creation of the window." Use that exact text;
  it mirrors the sdef description and tells the script author what to do.

### 5.7 Creation semantics (`make`)

`make` is `NSCreateCommand` (`corecrel`). Cocoa flow: create a blank instance of the requested class,
apply `with properties` through KVC, then insert it into the container's element array.
Our insertion accessors intercept that last step and create the real model object instead.
Implement a helper enum in `ScriptCommands.swift`:

```swift
@MainActor
enum ScriptCreation {
    static func makeTab(inSpace spaceID: SpaceID, atIndex index: Int?, properties: [String: Any]) -> ScriptTab?
    static func makeTab(inWindow windowID: WindowID, atIndex index: Int?, properties: [String: Any]) -> ScriptTab?
    static func makeLittleTab(properties: [String: Any]) -> ScriptTab?
    static func makeWindow(properties: [String: Any]) -> ScriptWindow?
}
```

Rules:

- `make new tab` with a `window` container: create in that window's active Space, at the end of Today (`BrowserModel.newTab(in:url:title:at:)` with `at: nil`). `with properties {URL:"…"}` sets the initial URL. Default URL when absent: `about:blank`. The model requires a `URL`; use `URL(string: "about:blank")!`. After creation, select the new tab (`selectNode`) and vend its specifier as the command result. Arc selects a new tab; match that.
- `make new tab` with a `space` container: same, in that Space.
- `make new tab` with an `application` container (write-only element): Little Open tab. Call `ScriptHost.makeLittleTab?(url)`. If the hook is nil, return error 1011 ("Little windows are not available yet."). The returned `ItemID` may not be in `BrowserModel` (Little windows can live outside the sidebar tree). Vend a `ScriptTab` wrapper whose `tab` lookup checks a second provider: add `ScriptHost.littleTabProvider: ((ItemID) -> Tab?)?` if Little tabs are not model tabs. If the App target models Little tabs as model tabs in a hidden Space, this provider is unnecessary. Decide when Little Arc lands (M4); until then, `make tab at application` returns error 1011 and §11 A15 records it as a known limit, not a failure.
- `make new window`: call `ScriptHost.makeWindow?(isIncognito)`. `with properties {mode:"incognito"}` sets the flag. Any other property in the record is ignored except `mode`. Return the new window's specifier.
- `make new space`: return error 1009 ("Making a new space is not supported. Create a Space in the sidebar."). Do not call `BrowserModel.createSpace`. The sdef does not forbid `new: space`, but Arc support is unverified (Q2) and a Space needs a profile and theme that a record cannot supply cleanly. Record the choice in the PR.
- `make new tab` with no container (`make new tab` at top level): AppleScript routes this to the application. Treat it as the Little-tab path. If that path errors with 1011, the script gets a clear message.
- Properties record keys: scripts pass property names (`URL`, `title`). Cocoa maps them to KVC keys through the sdef. Read `properties["URL"] as? String`. Title for a new tab is ignored by the model (the page sets it); accept and ignore it so scripts that pass `{URL:…, title:…}` do not fail.

---

## 6. Commands — `ScriptCommands.swift`

### 6.1 Routing rule (read first)

Scripting commands act on a **specific** tab, space, or window that the script named.
`OpenCommands`' `CommandDispatcher` acts on the **current** tab (`performCommand("reload")` reloads
whatever is selected). Do not route scripting through the dispatcher. A script that says
`reload tab id "X"` must reload tab X even when X is not selected.

- Model state (which tab exists, which Space is focused, which tab is selected, sidebar moves) goes through `BrowserModel` methods directly.
- Page state (back, forward, reload, stop, JavaScript, navigation to a new URL) goes through `ScriptEngineBridge` (§7.2) with the tab's `ItemID`.
- Window chrome state (minimize, zoom, visible) goes through the `NSWindow` from `ScriptHost.windowForState`.
- The one dispatcher exception: none. If you find yourself calling `performCommand` from `OpenScripting`, stop. Add a `BrowserModel` or bridge call instead.

### 6.2 Command implementation pattern

Arc declares tab and space verbs through `responds-to` methods on the wrapper, not through
`cocoa class` on the command. Keep that pattern. Each verb is an `@objc` method on the wrapper
that receives the `NSScriptCommand`. The method validates, acts, and returns a value or nil.
Set errors with the helper in §8 (`command.setScriptError(number:message:)`). Never throw across
the `@objc` boundary and never `fatalError`.

The sdef also declares `make` and `count` with system Cocoa classes. You do not write command
classes for those two. Cocoa's `NSCreateCommand` and `NSCountCommand` drive them through the
KVC accessors in §5 plus the interception in §6.7.

Define these helper types in `ScriptCommands.swift`:

```swift
import AppKit
import Foundation
import OpenModel

/// Resolves the direct object of a command to a live wrapper, or sets error 1000.
@MainActor
enum ScriptTarget {
    static func tab(from command: NSScriptCommand) -> ScriptTab?
    static func space(from command: NSScriptCommand) -> ScriptSpace?
    static func window(from command: NSScriptCommand) -> ScriptWindow?
}
```

Each resolver reads `command.directParameter` as an `NSScriptObjectSpecifier`, calls
`objectsByEvaluatingSpecifier` (or `evaluatedReceivers` for `responds-to` paths — see §6.3),
and casts. If the specifier evaluates to nil or the model lookup fails, set error 1000 with the
specifier's text when available and return nil. Every command body starts with a resolver guard.

### 6.3 Tab verbs (on `ScriptTab`)

Implement each as an instance method. Cocoa calls the method on the evaluated direct object.

```swift
// In ScriptTab.swift (signatures here are normative; bodies follow the table)
@objc func select(_ command: NSScriptCommand) -> Any?
@objc func goBack(_ command: NSScriptCommand) -> Any?
@objc func goForward(_ command: NSScriptCommand) -> Any?
@objc func reload(_ command: NSScriptCommand) -> Any?
@objc func stopLoading(_ command: NSScriptCommand) -> Any?
@objc func executeJavascript(_ command: NSScriptCommand) -> Any?
@objc func close(_ command: NSScriptCommand) -> Any?
```

| Verb (code) | Body (in order) | Return |
|---|---|---|
| `select` (`CrSelect`) | 1. Guard `model` and `tab` exist, else error 1000. 2. Find the tab's Space: walk `model.parent(of:)` up to a Space section; for a favorite, use the first window's active Space. 3. Find a window that can show it: prefer the key window's state, else the first window. If no window exists, error 1012. 4. `model.focusSpace(windowID:spaceID:)` when the tab's Space is not the window's focused Space. 5. `model.selectNode(windowID:spaceID:nodeID:)`. 6. Bring the window forward: `nsWindow.makeKeyAndOrderFront(nil)` and `NSApp.activate()`. | nil |
| `go back` (`CrSuBack`) | Guard tab exists. If `tab.live.canGoBack == false`, return nil (no-op, no error). Else `bridge.goBack(tabID:)`. If bridge is nil, error 1006. | nil |
| `go forward` (`CrSuFwd `) | Same with `canGoForward` and `bridge.goForward(tabID:)`. | nil |
| `reload` (`CrSuRlod`) | Guard tab exists. `bridge.reload(tabID:)`. Bridge nil → error 1006. Reload works on a sleeping tab too: the App bridge wakes it. Do not check `isLoading`. | nil |
| `stop` (`CrSustop`) | Guard tab exists. If not loading, no-op. Else `bridge.stopLoading(tabID:)`. | nil |
| `execute` (`CrSuExJa`) | §6.6. | result text |
| `close` (`coreclos`) | Guard tab exists. `model.closeTab(id:)`. Purge the wrapper cache entry. Closing the last tab in a window leaves the window open with no selection; do not close the window. | nil |

The `close` verb is shared: `ScriptWindow.close(_:)` closes the window (model state removal is
the App target's job: it observes the `NSWindow` close and removes the `BrowserWindowState`;
scripting must call `nsWindow.close()` and let that flow run — do not remove the state directly,
or the next launch restores a window with no view). `ScriptTab.close(_:)` archives through the model.

### 6.4 Navigation no-op rule

`go back` and `go forward` never error for "cannot navigate". `TabLiveState.canGoBack` /
`canGoForward` are the source of truth, fed by the engine. When the flag is false, return nil
at once. When the flag is stale (engine says it moved but the page did not), the bridge call is
still a no-op in CEF. This matches the sdef text "If Possible".

### 6.5 Space verb (on `ScriptSpace`)

```swift
@objc func focus(_ command: NSScriptCommand) -> Any?
```

Body: guard model and Space exist, else error 1000. Pick the target window: the key window if it
exists, else the first window. If no window exists, error 1012. Call
`model.focusSpace(windowID:spaceID:)`. Bring that window forward (`makeKeyAndOrderFront`, `NSApp.activate()`).
Do not change the selected tab; `focus` changes only the Space. Return nil.

### 6.6 `execute` — JavaScript (`CrSuExJa` / `JvSc`)

Signature on `ScriptTab`:

```swift
@objc func executeJavascript(_ command: NSScriptCommand) -> Any?
```

Steps:

1. Guard tab exists, else error 1000.
2. Read the script: `command.arguments?["javascript"] as? String`. The sdef `cocoa key` is `javascript` (lowercase). If missing or empty after trimming, error 1002 ("execute needs a javascript string.").
3. Guard bridge exists, else error 1006. Guard the tab has a live web content: if the App bridge reports the tab is sleeping with no content, wake it first (bridge owns waking; scripting just calls `executeJavaScript`).
4. Call the bridge. The bridge is synchronous from scripting's point of view (§7.2). It returns the completion value as text. Conversion (normative, fixes Q1 default):
   - JS `undefined` / `null` → `""` (empty text). Scripts test `result is ""`, not `missing value`.
   - JS string → itself. JS number / boolean → its `String(describing:)` decimal / `true` / `false` text, matching JavaScript `String(value)` for the values CEF returns (`42` → `"42"`, `true` → `"true"`).
   - JS object / array → JSON text via `JSONSerialization` when the bridge returns structured data; if the bridge already returns a string, pass it through. Never return `"[object Object]"`.
   - JS exception / syntax error → error 1013. Message is `"JavaScript error: " + ` the engine's exception text (first line only, max 300 characters). Do not return the error as a successful empty string; Raycast distinguishes success from failure by the error.
5. Return the text as `NSString`. AppleScript coerces it to `text`. JXA receives a string.

Timeout: the bridge call must not block the main thread forever. The App bridge runs the script
with a 10-second timeout. On timeout, error 1014 ("JavaScript did not finish in 10 seconds.").
Document the timeout in the error text so script authors can split long work.

### 6.7 `make`, `count`, and `close` glue

`make` (`NSCreateCommand`) and `count` (`NSCountCommand`) have no wrapper method. Cocoa drives
them through KVC. Add two `NSScriptCommand` subclasses **only** if the system classes cannot
express the write-only and creation rules. Try the system classes first (Step 5). The known gaps:

- Reading `tabs of application` must error (1004), but a KVC getter cannot set a command error with a custom number reliably. If `count tabs of application` returns 0 instead of erroring with the system `NSCountCommand`, add:

```swift
@MainActor
final class ScriptCountCommand: NSCountCommand {
    override func performDefaultImplementation() -> Any? {
        // If the direct specifier's container is the application and the key is appleScriptTabs,
        // set error 1004 and return nil. Otherwise call super.
    }
}
```

  and change the sdef `count` command's `cocoa class` to `ScriptCountCommand`. Do this only when the check A14 fails with the system class. Changing the Cocoa class does not change the term or code, so compatibility holds. Record which path you shipped in the PR.

- `make` result specifier: `NSCreateCommand` returns the inserted object's specifier. Because our insertion creates a *different* real object (§5.7), the blank instance's specifier is wrong. If `make new tab …` returns a specifier that does not resolve (`whose id` fails in A9), add:

```swift
@MainActor
final class ScriptMakeCommand: NSCreateCommand {
    override func performDefaultImplementation() -> Any? {
        // Create through ScriptCreation, then return the real wrapper's objectSpecifier.
    }
}
```

  and point the sdef `make` command at it. Again: term and code stay `make` / `corecrel`.

Do not write these subclasses speculatively. Build with the system classes, run A9 and A14,
and add a subclass only for a failing check. Each subclass is ~40 lines. The plan's default is:
**system classes first**.

`close` needs no subclass. The `responds-to` methods in §6.3 handle it.

### 6.8 `quit`

`application` responds to `quit` through `handleQuitScriptCommand:` on `NSApplication` (§5.2).
There is no `quit` command element in the sdef. `tell application "Open" to quit` routes through
the standard application quit Apple event. Verify with A16. Do not intercept quit to save state
synchronously inside the scripting handler; the App target's `applicationWillTerminate` already
flushes the snapshot (`saveNow` + `flush`, per model.md). The handler only calls `terminate`.

---

## 7. App-side adapter — the exact hooks

`OpenScripting` defines the contract. The App target implements it. This section is the contract.
If the App target already exists when you read this, implement the App files now.
If it does not, finish `OpenScripting` against these signatures and leave the App files for the App agent.

### 7.1 `ScriptHost` assignments (Hook H1)

In `App/AppDelegate.swift`, after the `BrowserModel` and the main window exist:

```swift
import OpenScripting

// In applicationDidFinishLaunching, after browserModel and window wiring:
ScriptHost.shared.modelProvider = { [weak browserModel] in browserModel }
ScriptHost.shared.windowStateID = { nsWindow in
    // Return the BrowserWindowState.id for this NSWindow, or nil for panels.
    windowRegistry.stateID(for: nsWindow)
}
ScriptHost.shared.windowForState = { windowID in
    windowRegistry.window(for: windowID)
}
ScriptHost.shared.makeWindow = { isIncognito in
    // Create BrowserWindowState + NSWindow. Return the new WindowID, or nil.
    // Until incognito exists, return nil when isIncognito is true (scripting errors 1010).
    windowRegistry.makeBrowserWindow(incognito: isIncognito)
}
ScriptHost.shared.makeLittleTab = { url in
    // Create a Little Open window showing url. Return its tab ItemID if it is a model tab,
    // else nil (scripting then errors 1011). Wire this in M4; leave nil before M4.
    littleWindowRegistry.makeLittleTab(url: url)
}
ScriptHost.shared.engineBridge = AppScriptEngineBridge(engine: openEngine, model: browserModel)
```

Types must match §5.1 exactly. `modelProvider` returns `BrowserModel?` (optional) so a profile
switch that briefly has no model errors cleanly (1005) instead of crashing.

### 7.2 `ScriptEngineBridge.swift` — minimal engine interface (Hook H2)

Define this protocol in `OpenScripting`. Assume nothing else about the engine.
The App target's `AppScriptEngineBridge` is the only conformer.

```swift
import Foundation
import OpenModel

/// Minimal engine surface that scripting needs. The App target implements this over OpenEngine.
/// All calls arrive on the main actor. Implementations must not block on network or disk.
@MainActor
public protocol ScriptEngineBridge: AnyObject {
    /// Navigate an existing tab to a new URL (tab.URL setter). Loads the page.
    func navigate(tabID: ItemID, to url: URL)
    func goBack(tabID: ItemID)
    func goForward(tabID: ItemID)
    func reload(tabID: ItemID)
    func stopLoading(tabID: ItemID)
    /// Runs JavaScript in the tab's main frame and returns the completion value as text.
    /// Conversion rules are in §6.6. Throws ScriptEngineError on JS failure or timeout.
    func executeJavaScript(tabID: ItemID, script: String) throws -> String
}

public enum ScriptEngineError: Error {
    case javascriptError(String)   // first line of the JS exception text
    case timedOut
    case noLiveContent             // tab is sleeping and could not be woken
}
```

Assumed engine facts (state them in the adapter file header; if one is false, fix the adapter, not the protocol):

1. The engine can address a web content by `ItemID`. The App target already maps sidebar tabs to web contents for tab switching (architecture: "The App target maps them to model updates"). The bridge uses that same map.
2. `executeJavaScript` can run on a background CEF thread and complete through a callback. The App adapter bridges it to the synchronous protocol method with a semaphore or a synchronous CEF evaluation call. It must enforce the 10-second timeout and must not spin the main run loop (no `RunLoop.run` pumping that can re-enter scripting). If CEF only offers an async API, the adapter dispatches to a background queue and waits on a `DispatchSemaphore` with the timeout; the main thread blocks briefly, which is correct for AppleScript (the script waits).
3. Navigation calls are fire-and-forget. Title, URL, loading, and `canGoBack` / `canGoForward` flow back into `Tab` / `TabLiveState` through the existing engine-event path. The bridge does not set `tab.url` itself; the engine event does. (The `URL` setter in §5.5 therefore only calls `navigate`.)
4. A sleeping tab can be woken by any bridge call. If it cannot, the adapter throws `noLiveContent` for `execute` and treats navigation calls as wake-then-act.

List this interface in the adapter PR. Do not add methods for find, zoom, or print. They are not in the dictionary.

### 7.3 Where `CommandDispatcher` fits

The App target already has one `CommandDispatcher` for menus and keys (commands.md).
Scripting does not use it (§6.1). The App agent must not "reuse" the dispatcher for scripting
to save code. The failure mode is real: `reload` through the dispatcher reloads the selected tab,
so `reload tab id "X"` would reload the wrong page whenever X is not selected.
Keep the two paths separate. They converge only inside `BrowserModel` and the engine.

---

## 8. Errors — numbers and messages (`ScriptErrors.swift`)

Every failure sets a scripting error number and a human message. Scripts branch on the number.
Messages are ours; never show the word "Arc" and never show a raw Swift error description.

```swift
import AppKit
import Foundation

public enum ScriptError {
    public static let objectNotFound = 1000
    public static let invalidURL = 1001
    public static let invalidValue = 1002
    public static let invalidMove = 1003
    public static let writeOnly = 1004
    public static let notReady = 1005
    public static let engineUnavailable = 1006
    public static let useMakeAndClose = 1007
    public static let modeSetOnce = 1008
    public static let makeSpaceUnsupported = 1009
    public static let incognitoUnavailable = 1010
    public static let littleUnavailable = 1011
    public static let noWindow = 1012
    public static let javascriptFailed = 1013
    public static let javascriptTimedOut = 1014
}
```

| Number | When | Message (exact; `<…>` is filled in) |
|---|---|---|
| 1000 | ID or index names an object that is not in the model | `The tab (or space, or window) <id> does not exist.` Use the right noun. |
| 1001 | `set URL` or `make … {URL:…}` with text that is not a URL, or a URL with no scheme and no host | `"<text>" is not a valid URL.` |
| 1002 | Unknown `location` string; missing `javascript` parameter | `"<value>" is not a location. Use topApp, pinned, or unpinned.` / `execute needs a javascript string.` |
| 1003 | `location` move the model refuses (split pane to favorites) | `A split pane cannot move to favorites. Separate it first.` |
| 1004 | Read or count of `tabs of application` | `tabs of application is write-only; make a new tab on application to create a Little Open window, or read tabs of a window or space.` |
| 1005 | `ScriptHost.model` is nil | `Open is not ready.` |
| 1006 | Bridge is nil, or a navigation call has no engine yet | `The page engine is not ready.` |
| 1007 | Direct KVC insert/remove on windows; `orderedIndex` set to a value other than 1 | `Use make new window and close window.` / `Only set index to 1 (bring to front) is supported.` |
| 1008 | Set `mode` or `incognito` on an existing window | `mode can be set only once during creation of the window.` |
| 1009 | `make new space` | `Making a new space is not supported. Create a Space in the sidebar.` |
| 1010 | `make new window … {mode:"incognito"}` before incognito exists | `Incognito windows are not available in this build.` |
| 1011 | `make new tab` on application before Little windows exist, or the App hook returns nil | `Little windows are not available yet.` |
| 1012 | `select` or `focus` with no browser window | `There is no browser window.` |
| 1013 | JavaScript threw | `JavaScript error: <first line, max 300 chars>` |
| 1014 | JavaScript exceeded 10 seconds | `JavaScript did not finish in 10 seconds.` |

Implementation helper (in `ScriptErrors.swift`):

```swift
extension NSScriptCommand {
    /// Sets the scripting error and returns nil for `return` convenience.
    @MainActor
    func fail(_ number: Int, _ message: String) -> Any? {
        scriptErrorNumber = number
        scriptErrorString = message
        return nil
    }
}
```

Use `command.fail(…)` as the last expression of a failing path. For KVC setters, which have no
command, read `NSScriptCommand.current()`; if it is nil (a Swift-side `setValue` in a check),
store the error in `ScriptHost.lastSetterError` and log it in debug builds only. Script-side sets
always have a current command.

Do not reuse AppleScript's built-in error numbers (-1700, -1728, and so on) for these cases.
Built-in numbers have fixed meanings that Script Editor displays with its own text, which would
hide our message. Our 1000-series numbers display our text verbatim.

---

## 9. Bundle, Info.plist, and build settings

### 9.1 Info.plist keys (Hook H4)

Add to the App target's `Info.plist`:

```xml
<key>NSAppleScriptEnabled</key>
<true/>
<key>OSAScriptingDefinition</key>
<string>Open.sdef</string>
```

- `NSAppleScriptEnabled` (boolean, true): allows Apple events to reach the scripting layer.
- `OSAScriptingDefinition` (string): the sdef file name **inside `Contents/Resources/`**. It is a file name, not a path. `Open.sdef`, not `Resources/Open.sdef`.

Also confirm the bundle has `CFBundleName` = `Open` and a unique `CFBundleIdentifier`
(the App target owns these; scripting needs `tell application "Open"` to resolve by name,
which uses `CFBundleName` / the app file name). Do not set the bundle identifier to Arc's
`company.thebrowser.Browser`. Scripts address Open by the name "Open", never by Arc's ID.

### 9.2 Resources build phase (Hook H3)

Add `App/Resources/Open.sdef` to the App target's **Copy Bundle Resources** phase.
After a build, the file must exist at `Open.app/Contents/Resources/Open.sdef`.
Check: `ls Open.app/Contents/Resources/Open.sdef` and `plutil -p Open.app/Contents/Info.plist | grep -A1 OSAScriptingDefinition`.

### 9.3 Entitlements and sandbox notes

- Being scriptable (receiving Apple events) needs no entitlement in a non-sandboxed build.
- If the App target is sandboxed, it needs `com.apple.security.automation.apple-events` only to **send** events to other apps. Open scripting **receives** events. Receiving needs the `NSAppleEventsUsageDescription` string only when another app is sandboxed and targets Open. Add this key to `Info.plist` so Finder and Script Editor show a clear prompt text if the system asks:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Scripts control Open windows, spaces, and tabs.</string>
```

- Do not add a `com.apple.security.scripting-targets` dictionary. That key limits which apps a sandboxed Open may script. Open scripts nothing in v1.

### 9.4 Scripting definition cache

macOS caches scripting definitions by bundle. During development, after each sdef change,
run `sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f Open.app`
(or delete the built app and rebuild) so Script Editor and `osascript` see the new terms.
Put this command in the PR's test notes. A stale cache is the most common cause of
"term not understood" during development; it is not a code bug.

---

## 10. Threading, concurrency, and performance rules

- Apple events arrive on the main thread. Cocoa Scripting evaluates specifiers and calls KVC and command methods there. Every wrapper, `ScriptHost`, and the bridge protocol are `@MainActor`. If the compiler asks for `nonisolated`, you have the wrong shape: Cocoa needs `NSObject` + `@objc dynamic`, and the main-actor isolation comes from the caller. Use `MainActor.assumeIsolated` at the `NSApplication` extension boundary only (§5.2), with a comment that Apple events are main-thread by definition.
- Never block the main thread except in the `execute` bridge wait (§7.2, max 10 seconds). Navigation calls return at once.
- Wrapper getters must be cheap: a dictionary lookup (`model.tab(id:)`), a parent walk of depth ≤ folder depth, or a flattened list build. Flattening a Space builds an array of wrappers through the cache; it does not copy `Tab` objects. A window with 500 tabs must answer `count tabs` without a visible pause. Do not observe, sort, or hit the disk in a getter.
- Do not register `BrowserModel` observers from `OpenScripting` except the one cache-purge observer the App target installs. Scripting is pull-based: each evaluation reads current state. No push, no invalidation traffic at 120 Hz.
- `ScriptTab.URL` getter returns `tab.url.absoluteString`. The model updates `tab.url` from engine events, so a script that navigates and then reads `URL` sees the final URL after redirects, not the requested string. This is correct and matches browser behavior. Note it in the PR.

---

## 11. Acceptance checks — `osascript` and JXA (run every one)

Run all checks against the **built** `Open.app` (debug or release) on this Mac.
Never against Arc. Setup first, then checks in order. Record pass or fail for each check in the PR.
A check that hits a documented known limit (A15 before M4, incognito in A13) is recorded as
"known limit", not as a pass and not as a failure.

### 11.0 Setup (do this before A1)

1. Build and launch Open: `open /path/to/Open.app` (the App agent's build output). Wait for the sidebar.
2. Through the real UI (or the debug automation channel in `docs/automation.md` when it lands, which can open URLs and read tab state without driving the desktop), create this known state:
   - Space 1 titled `Research`, Space 2 titled `Fun`. (Rename through the UI if the defaults differ.)
   - In `Research`: one pinned tab `https://example.com/` (title becomes "Example Domain"), one Today tab `https://example.org/`.
   - In `Fun`: one Today tab `https://example.net/`.
   - Make `Research` the focused Space and the `example.org` tab the selected tab in window 1.
3. Confirm by eye: two Spaces, three tabs. The checks below assume this state. If you add tabs during checks, later count checks must account for them; run the checks in order and close what you create, or restart from Setup.

`sdef` inspection without launching Script Editor:

```bash
sdef Open.app > /tmp/Open.sdef.txt   # must list Standard Suite, window/tab/space, all §3 commands
grep -c "CrSuFwd " /tmp/Open.sdef.txt  # at least 1; the trailing space must be present in the code attribute
```

### 11.1 Dictionary and application checks

```applescript
-- A1: application basics
tell application "Open"
    get name            -- expect: "Open"
    get version         -- expect: the CFBundleShortVersionString, non-empty
    get frontmost       -- expect: true when Open is frontmost, false otherwise; never an error
    count windows       -- expect: >= 1
    count spaces of window 1   -- expect: 2 (Research, Fun); use "count (spaces of window 1)" if needed
end tell
```

```applescript
-- A2: window properties
tell application "Open"
    set w to window 1
    get id of w               -- expect: a UUID string, stable across two runs of this line
    get name of w             -- expect: text (the window/tab title), non-empty
    get index of w            -- expect: 1
    get closeable of w        -- expect: true
    get minimizable of w      -- expect: true
    get resizable of w        -- expect: true
    get zoomable of w         -- expect: true
    get visible of w          -- expect: true
    get minimized of w        -- expect: false
    get zoomed of w           -- expect: false or true; record the value
    get mode of w             -- expect: "normal"
    get incognito of w        -- expect: false
    get title of active space of w   -- expect: "Research"
    get URL of active tab of w       -- expect: "https://example.org/"
end tell
```

JXA equivalent for A1 (run with `osascript -l JavaScript`):

```javascript
// A1-J: JXA application basics
var Open = Application("Open");
Open.name();        // "Open"
Open.version();     // non-empty string
Open.windows.length; // >= 1
```

### 11.2 Space and tab listing (the Raycast core)

```applescript
-- A3: spaces and flattened tabs, index base
tell application "Open"
    set out to {}
    repeat with s in spaces of window 1
        set end of out to (title of s) & ": " & (count tabs of s)
    end repeat
    return out   -- expect: {"Research: 2", "Fun: 1"} for the Setup state
end tell
```

```applescript
-- A4: list tabs of all spaces with title and URL (Raycast-style, §11.4 R1 core)
tell application "Open"
    set rows to {}
    repeat with s in spaces of window 1
        repeat with t in tabs of s
            set end of rows to (title of s) & " | " & (title of t) & " | " & (URL of t)
        end repeat
    end repeat
    return rows
    -- expect 3 rows; Research/example.com row first (pinned before today),
    -- then Research/example.org, then Fun/example.net. Titles must be non-empty after pages load.
end tell
```

```applescript
-- A5: tab properties
tell application "Open"
    set t to tab 1 of space 1 of window 1   -- the pinned example.com tab
    get id of t        -- UUID string
    get title of t     -- "Example Domain" after load (may be "" before load; wait and retry)
    get URL of t       -- "https://example.com/"
    get loading of t   -- false after load; true during a reload (see A10)
    get location of t  -- "pinned"
    set t2 to tab 1 of space 2 of window 1
    get location of t2 -- "unpinned"
end tell
```

### 11.3 Lookup by ID and selection

```applescript
-- A6: resolve by id with whose, then select (Raycast "focus a tab by id")
tell application "Open"
    set targetID to id of tab 1 of space 2 of window 1   -- Fun tab
    set found to first tab of window 1 whose id is targetID
    select found
    -- expect: Fun becomes the focused space; the Fun tab is the active tab
    get title of active space of window 1   -- expect: "Fun"
    get id of active tab of window 1        -- expect: targetID
end tell
```

```applescript
-- A7: focus a space
tell application "Open"
    set research to first space of window 1 whose title is "Research"
    focus research
    get title of active space of window 1   -- expect: "Research"
end tell
```

### 11.4 Creation, navigation, and mutation

```applescript
-- A8: open a URL in a new tab in a given Space (Raycast-style)
tell application "Open"
    set funSpace to first space of window 1 whose title is "Fun"
    set newTab to make new tab at funSpace with properties {URL:"https://example.com/"}
    get URL of newTab    -- expect: "https://example.com/" (after load; the specifier must resolve)
    get id of newTab     -- UUID string; "first tab whose id is (id of newTab)" must find it
    count tabs of funSpace   -- expect: previous count + 1
    close newTab
    count tabs of funSpace   -- expect: back to the previous count
end tell
```

```applescript
-- A9: make returns a resolvable specifier
tell application "Open"
    set s to space 1 of window 1
    set nt to make new tab at s with properties {URL:"https://example.org/"}
    set nid to id of nt
    set again to first tab of s whose id is nid
    -- expect: no error; (id of again) is nid
    close nt
end tell
```

```applescript
-- A10: reload, loading, back/forward, stop
tell application "Open"
    set t to active tab of window 1
    reload t
    -- loading may read true on an immediate get; the check is that reload does not error
    -- and a later get loading is false. Poll at most 20 times with delay 0.25.
    go back t      -- no error whether or not history exists
    go forward t   -- no error; exercises the CrSuFwd<space> code path
    stop t         -- no error
end tell
```

```applescript
-- A11: set URL navigates
tell application "Open"
    set t to make new tab at space 1 of window 1 with properties {URL:"https://example.com/"}
    delay 1
    set URL of t to "https://example.org/"
    delay 1
    get URL of t   -- expect: "https://example.org/"
    close t
end tell
```

```applescript
-- A12: location moves
tell application "Open"
    set t to make new tab at space 1 of window 1 with properties {URL:"https://example.net/"}
    get location of t        -- expect: "unpinned"
    set location of t to "pinned"
    get location of t        -- expect: "pinned"
    set location of t to "topApp"
    get location of t        -- expect: "topApp"
    set location of t to "unpinned"
    get location of t        -- expect: "unpinned"
    close t
    -- setting an unknown location must error 1002:
    set t2 to make new tab at space 1 of window 1 with properties {URL:"https://example.com/"}
    try
        set location of t2 to "nowhere"
        -- expect: does not reach here
    on error msg number n
        -- expect: n is 1002
    end try
    close t2
end tell
```

```applescript
-- A13: window creation and mode guard
tell application "Open"
    set w2 to make new window
    count windows   -- expect: previous count + 1
    close w2
    count windows   -- expect: back to previous count
    -- mode is set-once:
    try
        set mode of window 1 to "incognito"
        -- expect: does not reach here (error 1008), unless incognito creation already set it
    on error msg number n
        -- expect: n is 1008
    end try
end tell
```

### 11.5 Write-only, execute, count, quit, and error paths

```applescript
-- A14: application tabs are write-only
tell application "Open"
    try
        get tabs
        -- expect: does not reach here
    on error msg number n
        -- expect: n is 1004 (if the system NSCountCommand path shipped, "count tabs" may
        -- return 0 instead; then ship ScriptCountCommand per §6.7 and re-run)
    end try
    try
        count tabs
    on error msg number n
        -- expect: n is 1004
    end try
end tell
```

```applescript
-- A15: Little tab creation (known limit before M4)
tell application "Open"
    try
        set lt to make new tab with properties {URL:"https://example.com/"}
        -- After M4: expect a Little window and (id of lt) resolves; close lt if it is a model tab.
        -- Before M4: expect error 1011. Record as known limit, not a failure.
    on error msg number n
        -- expect before M4: n is 1011
    end try
end tell
```

```applescript
-- A16: execute JavaScript
tell application "Open"
    set t to make new tab at space 1 of window 1 with properties {URL:"https://example.com/"}
    delay 1
    set r1 to execute t javascript "1 + 2"          -- expect: "3"
    set r2 to execute t javascript "document.title" -- expect: "Example Domain"
    set r3 to execute t javascript "undefined"      -- expect: "" (empty text)
    try
        execute t javascript "throw new Error('boom')"
        -- expect: does not reach here
    on error msg number n
        -- expect: n is 1013 and msg contains "boom"
    end try
    close t
end tell
```

JXA execute equivalent (`osascript -l JavaScript`):

```javascript
// A16-J: JXA execute. JXA verb form: tab.execute({javascript: "…"})
// If JXA cannot phrase the custom verb, record that and rely on the AppleScript A16.
// JXA support is best-effort; AppleScript is the compatibility contract.
```

```applescript
-- A17: count and bad-ID errors
tell application "Open"
    count tabs of space 1 of window 1   -- expect: 2 in Setup state
    count spaces of window 1            -- expect: 2
    try
        get tab id "00000000-0000-0000-0000-000000000000" of window 1
        -- expect: does not reach here, or returns missing value; never a crash
    on error msg number n
        -- expect: n is 1000 when it errors
    end try
end tell
```

Quit check (run last; it closes the app):

```applescript
-- A18: quit (run in its own osascript call, after all other checks)
tell application "Open" to quit
-- expect: Open quits; relaunch it for any further work
```

### 11.6 Raycast-style queries (must all pass)

Raycast's extension and user scripts use these shapes. Port each one by changing
`tell application "Arc"` to `tell application "Open"`. No other change is allowed.

```applescript
-- R1: list tabs of all spaces with title and URL (same as A4; kept here as the Raycast contract)
tell application "Open"
    set rows to {}
    repeat with w in windows
        repeat with s in spaces of w
            repeat with t in tabs of s
                set end of rows to {spaceTitle:title of s, tabTitle:title of t, tabURL:URL of t, tabID:id of t}
            end repeat
        end repeat
    end repeat
    return count of rows   -- expect: >= 3 in Setup state; every row has non-empty tabURL
end tell
```

Note: R1 iterates `spaces of w` per window, so with two windows it lists each Space's tabs twice
(once per window). That matches the object graph (every window contains every Space). Raycast
dedupes by tab ID. The check is that IDs are identical across windows, not that rows are unique.
Add this line to the PR evidence: run R1, confirm the same tab ID appears once per window.

```applescript
-- R2: focus a tab by id (same as A6; the Raycast "switch to tab" action)
-- R3: open URL in a new tab in a given Space (same as A8)
-- Both must pass without modification beyond the app name.
```

### 11.7 How to run these checks

```bash
# One check per file keeps failures attributable. Paste a check into /tmp/a4.applescript, then:
osascript /tmp/a4.applescript
echo exit:$?

# JXA:
osascript -l JavaScript /tmp/a1.js
```

- Run A1–A14, A16, A17, R1 in order in one session. Run A15 and note its status. Run A18 last.
- When `docs/automation.md` lands (debug automation channel), Setup (§11.0) may create its state through that channel instead of the UI. The checks themselves still run through `osascript`; the channel must not become a second scripting surface that bypasses the sdef.
- If a check fails with "term not understood", first re-register the bundle (§9.4), rebuild, and re-run before changing code.

---

## 12. Implementation order (work top to bottom)

Do the steps in order. Each step ends with acceptance criteria. Do not start the next step with a
failing criterion unless the failure is a documented known limit in §11 or §14.

### Step 1 — Dictionary file and term table

Files: create `App/Resources/Open.sdef` (§3) when the App target exists; until then, create
`Packages/OpenKit/Sources/OpenScripting/Open.sdef` as the checked-in source and copy it to the App
bundle in Step 6. (SwiftPM ignores an `.sdef` in sources only if the target has no resources;
declare `resources: [.copy("Open.sdef")]` on the `OpenScripting` target in this step so the file
is versioned with the code, then have the App target read it from the package or duplicate it —
decide once: **source of truth is `App/Resources/Open.sdef`**; the package copy, if any, is a test
fixture. Do not maintain two drifting copies. Preferred: keep only `App/Resources/Open.sdef`.
Before the App target exists, keep the file at `docs/plans/Open.sdef.draft`? No — keep it at
`App/Resources/Open.sdef` and create the `App/Resources` folder now. The App agent adopts it.)

Do:
- Type the §3 XML fresh. Validate: `xmllint --noout App/Resources/Open.sdef`.
- Grep the padded codes: `grep -n 'code="ID  "' App/Resources/Open.sdef` (two spaces),
  `grep -n 'code="URL "' …` (one space), `grep -n 'code="CrSuFwd "' …` (trailing space).
  Editors and formatters trim trailing spaces inside attribute values only if you reformat the file;
  do not run a formatter on this file. Add `App/Resources/Open.sdef` to `.editorconfig` exceptions if one exists.

Accept:
- [ ] `xmllint --noout` succeeds.
- [ ] The three greps find their codes with the exact spacing.
- [ ] The term table in §3.1 matches the file (generate it by reading the file, not by copying §3.1).
- [ ] `git status` shows only `App/Resources/Open.sdef` new. No Arc file was copied (`git diff` contains no Arc bundle path).

### Step 2 — Package skeleton + `ScriptHost` + errors

Files: edit `Packages/OpenKit/Package.swift` (§2.1). Create
`Sources/OpenScripting/ScriptHost.swift` (§5.1), `ScriptErrors.swift` (§8),
`ScriptEngineBridge.swift` (§7.2), and stub wrappers (`ScriptWindow`, `ScriptSpace`, `ScriptTab`
with only `id` and `objectSpecifier`) so the target compiles.

Do: `swift build` in `Packages/OpenKit`. Fix Swift 6 isolation errors here:
wrappers are `@MainActor final class … : NSObject`; `@objc dynamic` properties on a `@MainActor`
class need the class to be `@MainActor` and all accesses on the main actor, which scripting guarantees.

Accept:
- [ ] `swift build` succeeds with zero new warnings in `OpenScripting`. Existing targets still build.
- [ ] `git status` shows only `Package.swift` modified and `Sources/OpenScripting/` new. No `OpenModel` or `OpenCommands` file is modified.

### Step 3 — Wrappers and KVC (read paths)

Files: complete `ScriptWindow.swift`, `ScriptSpace.swift`, `ScriptTab.swift`, `ScriptApplication.swift`
(read paths only: all getters, element accessors without insertion, object specifiers, flattening §4.3).

Do: implement the tables in §5.3–§5.5. Read `BrowserModel` through `ScriptHost.shared.model` on every access.

Accept (scratch check before the App target exists):
- [ ] A throwaway Swift probe under `/tmp/script-check/` (not in the repo) builds a `BrowserModel` with two Spaces (pinned + today + a folder + a split), sets `ScriptHost.shared.modelProvider`, and prints: space tab counts, flattened tab titles per Space, a tab's `location` for a favorite, a pinned tab, and a Today tab. Expected values come from the probe's own construction. Paste the output into the PR. Delete nothing in the repo.
- [ ] `swift build` stays clean.

### Step 4 — Commands (write paths and verbs)

Files: complete `ScriptCommands.swift` (§6), the insertion/removal accessors in §5, the `location`
setter (§5.5), `mode` guards (§5.6), creation (`ScriptCreation`, §5.7), and the `URL` setter (§5.5).
Add `ScriptCountCommand` / `ScriptMakeCommand` only if §6.7 says a check needs them — you cannot
know until Step 6, so leave the hooks (a comment naming §6.7) and decide in Step 6.

Accept (scratch probe, same `/tmp` rig as Step 3, extended):
- [ ] `select` on a Fun tab makes it the window's active tab in the probe model.
- [ ] `location` round-trips `unpinned → pinned → topApp → unpinned` through the wrapper setter.
- [ ] `close` on a tab removes it from the probe model and archives it (probe sink counts entries).
- [ ] `swift build` stays clean.

### Step 5 — App wiring (Hooks H1–H4)

Files: App target — `App/AppDelegate.swift` (H1 assignments), `App/Scripting/AppScriptEngineBridge.swift` (H2),
`App/Resources/Open.sdef` (H3, from Step 1), `App/Info.plist` (H4, §9.1, plus `NSAppleEventsUsageDescription`).
Add `OpenScripting` to the App target's dependencies. This step needs the App target and a runnable
`OpenEngine` (or a stub bridge that returns error 1006 for navigation and 1013-free empty results
for reads — reads must work even with a stub bridge).

Do: build the app, launch it, run `sdef Open.app` (§11.0) and confirm the terms appear.

Accept:
- [ ] The built bundle contains `Contents/Resources/Open.sdef` and the two Info.plist keys.
- [ ] `sdef Open.app` lists window/tab/space and all ten commands.
- [ ] Script Editor's Library shows the Open dictionary with no missing-term warnings.

### Step 6 — Full `osascript` pass

Files: none (verification step). Fix bugs in `OpenScripting` or the adapter as checks demand.
Add `ScriptCountCommand` / `ScriptMakeCommand` now if A9 or A14 requires them (§6.7).

Do: Setup (§11.0), then A1–A14, A16, A17, R1–R3. Record each result in the PR.

Accept:
- [ ] A1–A14, A16, A17, R1, R2, R3 all pass. A15 and incognito creation are recorded as known limits or passes per their text.
- [ ] No check needed a change beyond the app name when ported from an Arc-shaped script.

### Step 7 — Hardening and docs

Files: header comments in each `OpenScripting` file (one short paragraph: what the file owns,
which sdef keys it implements). No behavior change.

Do: re-run the full §11 pass after a cold relaunch (quit with A18, relaunch, Setup, re-run).
Confirm IDs survive the relaunch (A2's window/space/tab IDs match the pre-quit values for the
same restored state; tab IDs come from the persisted model and must match).

Accept:
- [ ] Full pass green after relaunch. ID stability confirmed.
- [ ] `swift build -c release` in `Packages/OpenKit` clean. App release build launches and answers A1.

### Step order dependency summary

`1 → 2 → 3 → 4` (dictionary, skeleton, reads, writes; verifiable without the App target through Step 4).
`5` needs the App target. `6` needs a real engine or stub bridge for navigation; reads pass with a stub.
`7` is the ship gate.

---

## 13. Cross-cutting rules

### 13.1 Code table (single source)

The normative term/code/access table is §3.1, generated from `Open.sdef`. If §3.1 and the sdef
file ever disagree, the sdef file wins and §3.1 is regenerated. The error table is §8.
The flattening order is §4.3. Do not restate these tables in code comments with different values;
link to the section instead.

### 13.2 Errors and logging

- Script-facing errors: §8 only. No other numbers.
- Diagnostics: `#if DEBUG` stderr lines prefixed `OpenScripting:` (file and verb). Release builds stay silent. Idle CPU stays near zero; no logging in getters.
- Never log URLs or page titles at info level. A debug line may log a tab ID and a verb, not its URL.

### 13.3 Security and privacy

- Any local app can script Open once the user allows it (standard macOS automation consent, TCC `kTCCServiceAppleEvents`). Do not add a second in-app permission prompt in v1; the system prompt is the gate. Note this in the PR so the settings milestone can add an "Allow scripts" toggle later if product wants one.
- `execute` runs arbitrary JavaScript with page privileges. That is the feature (it matches Arc). Do not sandbox it, and do not log the script text.
- Scripts can read every tab title and URL. That is the dictionary's purpose (Raycast needs it). Do not redact.

### 13.4 What "done" means for this milestone

`OpenScripting` builds clean; the full §11 pass is green against the real `Open.app`;
Raycast-style queries R1–R3 pass with only the app name changed; IDs are stable across a relaunch.
No claim about Little tabs (A15) or incognito windows beyond what §11 records.

---

## 14. Open questions (need a decision or a user-run Arc check)

| ID | Question | Blocks | Default assumed in this plan |
|---|---|---|---|
| Q1 | Does Arc's `execute` return the JS completion value stringified, and what happens on a JS error? (§10.4 Q1; needs a user script run against Arc — agents must not launch Arc.) | Exact `execute` text forms | §6.6 conversion table; JS errors error 1013. If a user later runs Arc and reports a different form (for example errors returned as text), change §6.6 step 4 only. |
| Q2 | Does Arc's `make` support creating `space` objects? (§10.4 Q2) | `make new space` | Unsupported (error 1009, §5.7). The sdef does not restrict `new`; Open restricts by behavior. |
| Q3 | Where does a tab land when its `location` is set — start, end, or original position? (§10.4 Q3) | `location` setter ordering | End of the destination list (§5.5). One-line change if Arc evidence arrives. |
| Q4 | Are Little tabs model tabs in a hidden Space, or separate window state? (M4 owns Little Arc.) | A15 full pass | `ScriptHost.makeLittleTab` hook returns nil → error 1011 until M4 decides. The hook shape does not change. |
| Q5 | Does Open need an "Allow JavaScript from Apple Events" gate like Arc's menu item (`allow-js-apple-events` in commands.md)? Arc has the menu command; §10 does not say `execute` checks it. | `execute` availability | No gate in v1: `execute` always runs. If product adds the gate, check it in `executeJavascript:` and error 1013 with "JavaScript from Apple Events is off." Do not add the check speculatively. |
| Q6 | Should `window index` setting support full z-order, or only bring-to-front? | `orderedIndex` setter | Bring-to-front for 1, error 1007 otherwise (§5.3). Full ordering needs App-target window-registry work. |
| Q7 | `ScriptCountCommand` / `ScriptMakeCommand`: system classes or subclasses? | A9, A14 | System classes first; subclass only on a failing check (§6.7). Either path keeps terms and codes identical. |

Decision discipline: Q4 unblocks only A15. Q1–Q3 have defaults; implement the defaults and note
the assumption in the PR. Do not block Steps 1–4 on any open question.







## Appendix — Lead decisions (2026-10-25)

- Q1–Q3: accept the defaults stated in §14.
- Q4: A15 may return error 1011 until Little Open (M4) lands; add it back to the pass list then.
- Phasing: Steps 1–4 now (no App target needed). Steps 5–7 run after the App target with the engine bridge exists (PR from the engine team); they become a separate task.
- Naming: the dictionary terms stay identical to Arc's for script compatibility, but every user-visible description string says "Open", never "Arc".
- Q5 (changed 2026-11-02, page-platform lead decision Q3): `execute` is gated behind View ▸ Developer ▸ Allow JavaScript from Apple Events, off by default (Chromium's default). When off, `executeJavascript:` returns error 1013 with "JavaScript from Apple Events is off. Turn it on in View ▸ Developer." The gate is `ScriptHost.allowsJavaScriptFromAppleEvents` (defaults key `open.developer.allowJavaScriptFromAppleEvents`) in `OpenScripting/ScriptCommands.swift`; it takes effect once the App hosts OpenScripting (Steps 5–7).
