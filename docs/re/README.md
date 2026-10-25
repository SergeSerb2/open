# Arc reverse-engineering notes

Target: Arc 1.170.0 (build 89123, commit `9f5625b3`), `company.thebrowser.Browser`.
Engine: `ArcCore.framework` 156.0.8078.48 (Chromium branch 8078).

All files here are our own written findings. Raw output stays in `.re/` (git-ignored).

## Shared analysis assets (local only, in `.re/`)

| Asset | Path | Notes |
|---|---|---|
| Arc main binary, arm64 slice | `.re/bin/Arc-arm64` | 80 MB. Use this, not the fat binary. |
| ArcCore, arm64 slice | `.re/bin/ArcCore-arm64` | 239 MB Chromium fork. |
| Ghidra project for Arc main | `.re/ghidra/ArcMain.gpr` | Built once with `analyzeHeadless`. Query it with `analyzeHeadless .re/ghidra ArcMain -process Arc-arm64 -noanalysis -readOnly -postScript <script>`. Never re-import. |

`rea` CLI calls that use Ghidra (`search`, `decompile`, `function`, `xrefs`) re-analyze the whole binary on every call. Do not use them on the two large binaries. Use the saved Ghidra project instead.

## Reports

| File | Topic |
|---|---|
| `bundle-anatomy.md` | Bundle layout, frameworks, third-party SDKs, helpers |
| `architecture-map.md` | Swift modules, key types, state and persistence design |
| `menus-and-hotkeys.md` | Every menu item and keyboard shortcut |
| `design-tokens.md` | Colors, sizes, spacing, radii, fonts, motion timing |
| `data-model.md` | Sidebar, Spaces, tabs, and archive file schemas (for Import from Arc) |
| `features.md` | Behavior and settings of each v1 feature |
| `arccore-engine.md` | ArcCore API surface, Chromium changes, extension UI hosting |
