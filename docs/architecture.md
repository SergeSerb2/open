# Open architecture

Status: draft v1 (2026-10-24). The engine spike (`docs/engine-spike.md`) and the reverse-engineering reports (`docs/re/`) will refine it.

## Goals, in priority order

1. Feel like Arc: same layout, metrics, colors, motion, sidebar behavior, and hotkeys.
2. Be lighter and faster than Arc: fast cold launch, instant tab switches, 120 Hz sidebar, near-zero idle CPU, low memory per idle tab.
3. Stay easy to change: clear module borders, so we can add sync and our own features later and swap the engine.

## What we do differently from Arc

| Arc | Open | Why |
|---|---|---|
| 80 MB Swift binary, many SwiftUI hosting views | AppKit views for the window chrome, sidebar, rows, and command bar. SwiftUI only for low-frequency panels (settings, editors). | SwiftUI list diffing and hosting views are the main source of sidebar lag. |
| Firebase, gRPC, Datadog, LaunchDarkly, Sentry, CloudKit sync | None in v1 | No account, no telemetry, no feature flags. Smaller binary, less launch work. |
| Own Chromium fork (591 MB framework) | CEF behind `OpenEngine` | Prebuilt engine, easy Chromium updates. The engine layer keeps a fork possible later. |
| All tabs as live web contents | Lazy load, plus sleep after inactivity | Most tab memory goes to tabs nobody looks at. |

## Process and module layout

```
Open.app
├── Contents/MacOS/Open                     Swift app (AppKit)
├── Contents/Frameworks/
│   ├── Chromium Embedded Framework.framework
│   ├── OpenEngine (ObjC++, the only code that includes CEF headers)
│   └── Open Helper (GPU|Renderer|Plugin|Alerts).app
```

Source tree:

```
App/                  App target: lifecycle, window controllers, wiring, menus
Engine/OpenEngine/    ObjC++ CEF wrapper with a Swift-friendly API
Packages/OpenKit/     SwiftPM package, engine-agnostic, one library per area:
  OpenModel           Value types: Profile, Space, SidebarItem (tab, folder, split), favorites, archive. Pure Swift, no AppKit.
  OpenStore           Persistence: sidebar snapshot (JSON, atomic, debounced), history and archive (SQLite + FTS5, system libsqlite3)
  OpenDesign          Design tokens (colors, metrics, fonts, motion), Space themes (gradients), our own icons and sounds
  OpenWeb             Swift protocols over the engine (WebEngine, WebContent, ExtensionHost). App target bridges them to OpenEngine.
  OpenSidebar         Sidebar views, rows, favorites grid, folders, drag and drop, Space switcher
  OpenCommandBar      Command bar panel, search sources, ranking, actions
  OpenFeatures        Split View, Peek, Little Arc, Boosts, Zap, Site Control Center, ad blocking, Air Traffic Control
  OpenImport          Import from Arc
tools/                Build, run, fetch-cef, and rea scripts
docs/                 Architecture, plans, RE reports, engine docs
```

Rules:

- Packages never import `OpenEngine` or CEF. They talk to `OpenWeb` protocols. Only the App target joins the two. This keeps the engine swappable.
- `OpenModel` has no UI and no I/O. All state changes go through one `BrowserState` store on the main actor, as small mutations. Views observe only the slices they draw.
- Each library target is owned by one agent at a time. This keeps parallel work free of merge conflicts.

## State and data flow

- One `BrowserState` per app, `@MainActor`. It holds profiles, Spaces, sidebar trees, windows, and the selection.
- Mutations are named commands (for example `pinTab`, `moveItem`, `archiveTab`). Each command updates the model, records undo, and marks the snapshot dirty.
- Views subscribe to fine-grained change events (item inserted, moved, updated, removed). A row redraws only when its own item changes. No full-list reloads.
- The engine reports events (URL, title, favicon, loading, audio) per web content. The App target maps them to model updates.

## Persistence

| Data | Format | Notes |
|---|---|---|
| Sidebar, Spaces, profiles, windows | One JSON snapshot per profile set, written atomically | Debounced about 1 s, written on a background queue, and flushed on quit. Arc also uses JSON. |
| History | SQLite with FTS5 | Our own store, fed by navigation events. The command bar searches it. CEF does not expose Chromium's history service. |
| Archive | SQLite | It can grow to thousands of rows. |
| Cookies, cache, passwords, extensions | Chromium profile folders managed by CEF | One CEF request context and cache path per Open profile |

Location: `~/Library/Application Support/Open/`.

## Performance budgets (release build, M5 Pro)

| Metric | Budget |
|---|---|
| Cold launch to sidebar drawn | ≤ 250 ms |
| Cold launch to first web paint (restored tab) | ≤ 700 ms |
| Tab switch to content visible (live tab) | ≤ 16 ms (one frame) |
| Sidebar scroll and drag | 120 fps, no dropped frames |
| Idle CPU (no media playing) | ≈ 0% |
| Command bar open to first results | ≤ 50 ms |

Tactics: build the window and sidebar from the snapshot before the engine finishes starting. Create web content only for visible or recently used tabs. Put tabs to sleep after a period without use (configurable). Load features on first use (command bar panel, settings, Little Arc, editors). Ship only the locales we need.

## Testing

No unit tests. Each feature is verified end to end on the real app through the automation channel (`docs/automation.md`, built by the engine spike): open URLs, read tab and sidebar state, run JavaScript in pages, and capture PNGs of our own window. We never drive the user's desktop.
