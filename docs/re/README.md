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
| `interaction-states.md` | States captured during a user-driven session: hover/selected fills, command bar, Space switch, Split View, Peek, menus, sidebar hide/resize, settings |
| `arccore-engine.md` | ArcCore API surface, Chromium changes, extension UI hosting |
| `passwords-autofill.md` | Password, card, and address prompts; fill dropdown; Manage pages; Keychain key; passkeys; Arc's importer |
