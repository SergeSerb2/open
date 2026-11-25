# Open Unified Browser — Architecture & Implementation Plan (Option A: Chromium Views + Preact WebUI)

Status: Active Master Plan (2026-11-25)
Base Engine: Chromium `156.0.8078.48` (`d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`) — **no CEF**.
Targets: **Windows x64**, **Linux x64**, **macOS arm64** from one unified codebase under `Unified/`.
Existing macOS AppKit/CEF app (`App/`, `Packages/OpenKit/`, `Engine/`) remains untouched until parity.

---

## 1. Core Architectural Principles

1. **Hot-path browser chrome in Chromium Views (C++/Skia):**
   - `OpenBrowserView` subclasses/integrates directly with Chromium's `BrowserView`, `TabStripModel`, `ToolbarActionsModel`, `views::Widget`, and `ui::Compositor`.
   - Zero CEF, zero hidden-browser hacks, zero Objective-C++ `OpenEngine` bridge, zero airspace bugs.
   - Covers: frameless rounded window, 10 pt themed frame inset, 64x64 OKLab dual-angle Space theme + grain shader, collapsible/resizable 120 Hz Sidebar (`164..500` pt, default `228` pt), hover-reveal card, Favorites grid, incremental tab/folder/split tree, Space switcher strip + spring pager (`R=0.20s, ζ=1.0`), 2–4 pane live Split View with 32 pt page-tinted `PaneChromeView`, zero-animation Command Bar (`766` pt), Peek overlay (`80%` width, `0.70` scrim), Little Open window (`47` pt `#272A37` header), Site Control bubble (`236` pt), Find bar, Toasts, and `Ctrl+Tab` switcher.
2. **Rich lower-frequency panels in Chromium WebUI (TypeScript + Preact + Vite):**
   - Served from internal `open://` hosts bundled into Chromium `.pak` GRD resources, loaded lazily on demand (zero startup or idle RAM penalty).
   - Hosts: `open://settings`, `open://library`, `open://boosts`, `open://easel`, `open://note`, `open://onboarding`, `open://welcome`.
   - Validated with `tsrs --noEmit -p tsconfig.json` + Vite production bundle.
3. **100% cross-platform C++20 core + Rust ad-block + existing `SyncServer/`:**
   - `Unified/src/open_unified/core/` implements `BrowserModel`, atomic `State/browser.json` (schema v1 compatible with macOS Open), SQLite FTS5 `HistoryStore`, `ArchiveStore`, `SleepStore` (exact OPNH v1 binary codec), `DownloadHistoryStore`, `FaviconStore`, `SleepScheduler`, `RoutingEvaluator`, `SuggestEngine`, `CommandRegistry`, `KeyBindings`, `Boosts`, `Documents`, cross-platform `Import`, and full zero-knowledge E2EE `OpenSync` v1 (using Chromium's BoringSSL, compatible with `SyncServer/`).
   - Reuses `Engine/fork/src/open/adblock/` (Rust `adblock 0.8.11` CXX bridge, URLLoaderFactory proxy, WebSocket/WebTransport checks, Blink isolated world 7 cosmetics) directly via a per-Profile Chromium `KeyedService` (`OpenAdBlockProfileService`), dropping all CEF wrappers.
4. **Thin OS adapters (~5% of codebase):**
   - `Unified/src/open_unified/browser/platform/`: `open_platform_win.cc` (DPAPI/CredMan, DWM Mica, Win32 `RegisterHotKey`, default browser), `open_platform_linux.cc` (Secret Service / 0600 file, X11/Wayland framing, xdg-settings), `open_platform_mac.mm` (Keychain, vibrancy/traffic-light insets, Carbon hotkeys).
5. **End-to-end verification (no unit tests):**
   - `OpenAutomationServer` implements the exact NDJSON protocol from `docs/automation.md` over `AF_UNIX` (`--automation-socket=PATH`, supported on Linux, macOS, and Windows 10/11) with loopback TCP fallback (`--automation-port=PORT`), letting our Python E2E harness (`Unified/tests/e2e/`) drive the real compiled browser binary, take real window PNGs, inspect real tabs/Spaces/splits/extensions/adblock/sync, and verify every feature end to end.

---

## 2. Build & Compute Topology

| Machine / Service | Role | Notes |
|---|---|---|
| `serge-pc WSL` (`x86_64`, 16c i7-12700K, 47 GiB RAM, 653 GiB free ext4, 577 GiB free `C:\`) | Primary Chromium `156.0.8078.48` checkout (`~/open-unified-chromium/src`), Siso build coordinator, Linux x64 real E2E host, Windows x64 cross-compile (`clang-cl` + `lld-link` using MSVC `14.44.35207` + Win11 SDK `10.0.26100.0` from `/mnt/c`) | Stages runnable Windows `open.exe` bundle to `/mnt/c/Users/serge/OpenUnified/` |
| `boat.dev` (`$17.92` credit left before Dec 4 = ~248 `large` 8-vCPU VM-hours) | Parallel Siso + NativeLink remote compile farm (`1` scheduler + `8–12` `large` workers = 64–96 remote vCPUs) accelerating Linux x64 and Windows x64 builds, plus clean Linux desktop verification sandboxes | Workers stopped/deleted immediately after heavy compile waves |
| `Serge's MacBook Pro (2)` (M5, `arm64`, 2.8 GiB free) | macOS arm64 target configs & Cocoa adapters written and checked in; full macOS Chromium build awaits freeing disk space on M5 | Never modify `~/Developer/open-engine*` without permission |

---

## 3. Canonical Namespace & Directory Ownership (Parallel Agent Contracts)

All C++ code under `Unified/src/open_unified/` lives in `namespace open_unified`.
Shared types are frozen in:
- `Unified/src/open_unified/core/model/open_types.h`
- `Unified/src/open_unified/ui/webui/open_ipc_contract.h`

### Parallel Implementation Tracks (Strictly Disjoint File Ownership)

| Track | Model | Owned Paths | Deliverable |
|---|---|---|---|
| **Track 1 (Infra & Bootstrap)** | `gemini-4-neon` (high) on `serge-pc WSL` | Remote `~/open-unified-chromium/` + `Unified/scripts/unified-bootstrap`, `Unified/scripts/unified-win-toolchain`, `Unified/scripts/boat-farm.sh` | Clone `open` repo on `serge-pc`, sync Chromium `156.0.8078.48`, pack Win11 SDK+MSVC sysroot, bring up `boat.dev` NativeLink/Siso worker farm, prove stock Linux x64 + Windows x64 cross-compile works |
| **Track 2 (Core Model, Store, Sleep, Suggest, Routing, Commands)** | `gemini-4-neon` (high) | `Unified/src/open_unified/core/{model,store,sleep,routing,suggest,commands}/` (except frozen `open_types.h`) | Complete C++20 `BrowserModel` + undo + `TreeChange`, JSON v1 `SnapshotStore`, SQLite FTS5 `HistoryStore`, `ArchiveStore`, `SleepStore` (OPNH v1), `DownloadHistoryStore`, `FaviconStore`, `SleepScheduler`, `RoutingEvaluator`, `SuggestEngine`, `CommandRegistry` + `KeyBindings` |
| **Track 3 (Sync v1, AdBlock, Boosts, Documents, Import, Platform)** | `gemini-4-neon` (high) | `Unified/src/open_unified/core/{sync,adblock,boosts,documents,import}/`, `Unified/src/open_unified/browser/platform/` | Full E2EE Open Sync v1 client (BoringSSL, 16 collections, HTTP/WS SyncServer protocol), `OpenAdBlockProfileService` wrapping `//open/adblock` (Rust 0.8.11, zero CEF), Boosts/Zap + Easel/Note stores, Chrome/Edge/Firefox/Arc importer, Win/Linux/Mac platform adapters |
| **Track 4 (Design System + Primary Hot Views)** | `claude-opus-5-5` (high) | `Unified/src/open_unified/ui/design/`, `Unified/src/open_unified/ui/views/{open_browser_view,open_sidebar_view,open_tab_tree_view,open_space_pager_view}.{h,cc}` | Exact `OpenMetrics`, OKLab 64x64 dual-angle gradient + grain `SkShader` (`OpenThemeMath`), `OpenTypography`, `OpenBrowserView`, `OpenSidebarView`, incremental `OpenTabTreeView`, spring-animated `OpenSpacePagerView` |
| **Track 5 (Secondary Hot Views)** | `claude-opus-5-5` (high) | `Unified/src/open_unified/ui/views/{open_split_container_view,open_command_bar_view,open_peek_overlay_view,open_little_open_view,open_site_control_bubble,open_find_bar_and_toasts}.{h,cc}` | Live 2–4 pane `OpenSplitContainerView` + `PaneChromeView`, zero-animation `OpenCommandBarView`, `OpenPeekOverlayView`, `OpenLittleOpenView`, `OpenSiteControlBubble`, Find bar, Toasts, `Ctrl+Tab` switcher |
| **Track 6 (Chromium 156 Integration, Patches, WebUI C++ & Automation)** | `claude-opus-5-5` (high) | `Unified/patches/chromium/`, `Unified/src/open_unified/BUILD.gn`, `Unified/src/open_unified/browser/` (non-platform), `Unified/src/open_unified/ui/webui/` (non-contract), `Unified/scripts/{unified-apply,unified-build}`, `Unified/tests/e2e/` | Surgical Chromium 156 patches (`0001`–`0009`), `OpenBrowserService`, `OpenTabBridge`, `OpenExtensionBridge`, `OpenSleepController`, `OpenBoostController`, `OpenWebUIConfig` + all `open://` C++ handlers, `OpenAutomationServer`, `BUILD.gn`, apply/build scripts, and E2E test harness |
| **Track 7 (Preact + Vite + TS WebUI Frontend)** | `gemini-4-neon` (high) | `Unified/webui/` | Full TypeScript + Preact + Vite frontend for all 7 `open://` apps (`settings`, `library`, `boosts`, `easel`, `note`, `onboarding`, `welcome`), typed IPC client matching `open_ipc_contract.h`, `tsrs` validated, Vite GRD bundle, live browser-verified |

---

## 4. Phased Execution & Verification Milestones

- **Milestone 1 (Core Unified Browser — Compile, Launch, End-to-End Verify):**
  - Apply `Unified/patches/chromium/` + overlay `Unified/src/open_unified/` + Rust adblock (`Engine/fork/src/open/adblock/`) + built `Unified/webui/dist/` onto Chromium `156.0.8078.48` on `serge-pc WSL`.
  - Compile **Linux x64** (`out/OpenLinux`) using the `boat.dev` Siso/NativeLink farm, fix all compile/link errors cleanly, launch real `open` binary under Xvfb, and run full end-to-end verification via `OpenAutomationServer` (sidebar, Spaces, theme gradients, tabs/folders, Split View, Command Bar, Extensions, Rust Ad-Block, Tab Sleep, E2EE Sync against live `SyncServer/`, and `open://settings` + `open://library` WebUI pages + window PNG snapshots).
  - Cross-compile **Windows x64** (`out/OpenWin64`) using MSVC `14.44.35207` + Win11 SDK `10.0.26100.0` + `boat.dev` Siso farm, verify zero unresolved symbols/missing DLLs, and stage runnable `C:\Users\serge\OpenUnified\open.exe` package.
- **Milestone 2 (Full Arc Parity Polish & Cross-Family Review):**
  - End-to-end verification of Peek, Little Open, Site Control Center, Boosts + Zap (world 6), Easels, Notes, Onboarding, Welcome, Import (Chrome/Edge/Firefox/Arc), Air Traffic Control routing, and performance/idle-CPU checks.
  - Cross-family code review (`Claude Opus 5.5` reviews Gemini tracks; `Gemini 4 Neon` reviews Claude tracks) and final clean commit/PR ready for macOS build once M5 disk space is freed.
