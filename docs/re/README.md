# Arc reverse-engineering notes

Target: Arc 1.170.0 (build 89123, commit `9f5625b3`), `company.thebrowser.Browser`.
Engine: `ArcCore.framework` 156.0.8078.48 (Chromium branch 8078).

All files here are our own written findings. Raw output stays in `.re/` (git-ignored).

## Shared analysis assets (local only, in `.re/`)

| Asset | Path | Notes |
|---|---|---|
| Arc main binary, arm64 slice | `.re/bin/Arc-arm64` | 80 MB. Use this, not the fat binary. |
| ArcCore, arm64 slice | `.re/bin/ArcCore-arm64` | 239 MB Chromium fork. |
| Ghidra project for Arc main | `~/Library/Caches/OpenRE/ghidra/ArcMain.gpr` | Ghidra rejects paths with dot folders (`.t3`, `.re`), so the project lives outside the repo. Build log: `.re/logs/ghidra-arcmain.log`. Query it with `GHIDRA_HEADLESS_MAXMEM=16G $GHIDRA_INSTALL_DIR/support/analyzeHeadless $OPEN_GHIDRA_DIR ArcMain -process Arc-arm64 -noanalysis -readOnly -scriptPath <dir> -postScript <script>`. Scripts must also live in a path without dot folders. Never re-import. |

`rea` CLI calls that use Ghidra (`search`, `decompile`, `function`, `xrefs`) re-analyze the whole binary on every call. Do not use them on the two large binaries. Use the saved Ghidra project instead.

## Reports

| File | Topic |
|---|---|
| `bundle-anatomy.md` | Bundle layout, frameworks, third-party SDKs, helpers |
| `architecture-map.md` | Swift modules, key types, state and persistence design |
| `menus-and-hotkeys.md` | Every menu item and keyboard shortcut |
| `design-tokens.md` | Colors, sizes, spacing, radii, fonts, motion timing |
| `data-model.md` | Sidebar, Spaces, tabs, and archive file schemas (for Import from Arc) |
| `features-core.md` | Sidebar, Spaces, tab lifecycle, command bar, profiles, routing, settings, windows |
| `features-advanced.md` | Split View, Peek, Little Arc, Boosts, Zap, Site Control Center, ad blocking, PiP, AppleScript |
| `runtime-observations.md` | Live data from the signed-in Arc: files, preferences, measured layout |
| `interaction-states.md` | States captured during user-driven sessions: hover/selected fills, command bar, Space switch, Split View, Peek, menus, sidebar hide/resize, settings; session 2 (§20): window chrome, Favorites, folders, Site Control Center, Boost editor, media, theme editor, Little Arc, Light mode, motion |
| `commandbar-completion.md` | Command bar inline autocomplete, Split View rows, scoped searches, hold-Command hints, Essential Keyboard Shortcuts window, optional toolbar |
| `arccore-engine.md` | ArcCore API surface, Chromium changes, extension UI hosting |
| `page-platform.md` | Toasts, Copy URL as Quote, zoom and pinch, page swipe, web notifications, Capture, translation, website appearance, clear-and-refresh, Developer menu and Developer Mode, Troubleshooting, Cast |
| `passwords-autofill.md` | Password, card, and address prompts; fill dropdown; Manage pages; Keychain key; passkeys; Arc's importer |
| `sidebar-completion.md` | Delete alerts copy, Space Manager, multi-select, Clear variants, pinned reset, folder archive, hover previews, tidy-title schema, unread dot, banner, first-hide hint (measured), haptics, sounds, gesture hide |
| `capture-session-2-results.md` | Capture session 2 (2026-10-26): what each plan and open PR must change, contradictions with lead decisions, and what stays uncaptured. Measurements are in `interaction-states.md` §20 |
| `live-data.md` | Live Folders (GitHub), Calendar Preview and mail previews, Live Calendar, Join Meeting, Peek Email: surfaces, data paths, storage, flags (F2, 2026-11-11) |
| `browser-import.md` | Arc's import from Safari, Chromium-family browsers and Firefox: surfaces, strings, categories, source file formats, consent matrix |
| `live-data.md` | Live Folders (GitHub), Calendar Preview and mail previews, Live Calendar, Join Meeting, Peek Email: surfaces, data paths, storage, flags (F2, 2026-11-11) |
