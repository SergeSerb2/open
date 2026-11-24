# Open Accounts & Browser Sync

Open provides optional, zero-knowledge end-to-end encrypted account syncing across Macs, backed by a self-hosted TypeScript/Node.js sync server in [`SyncServer/`](../SyncServer/README.md).

## Overview

- **Optional & offline-first**: Open works with no account. When signed out, sync adds zero network activity and zero launch work (`SyncStateStore.hasSavedAccount` checks one path after first paint).
- **Zero-knowledge E2EE**: All browser data is encrypted on-device with AES-256-GCM before upload. The server stores only ciphertext envelopes, encrypted binary blobs, salted `scrypt` verifier hashes, and per-account revision metadata. See [`docs/sync-protocol.md`](sync-protocol.md) for the exact cryptography and wire contract.
- **Recovery key**: Creating an account generates a 256-bit recovery key (`OPEN-XXXX-...`) that wraps the same random Vault Key as the user's password. Changing a password re-wraps the Vault Key without re-encrypting synced data; losing a password can be recovered with the recovery key.
- **Real-time delta sync**: Devices subscribe over WebSocket (`GET /v1/sync/ws`) for lightweight revision wakeups (`{ "type": "sync_available", "revision": ... }`), pulling and pushing only changed encrypted records and tombstones with per-entity last-write-wins conflict handling.

## What Syncs

Each category can be toggled independently in **Settings ▸ Account & Sync** (`open://settings/account-sync/categories`):

| Category | Synced Data |
|---|---|
| **Workspace** | Profiles (metadata, icons, search engines, auto-archive, sleep & download settings, Favorites), Spaces (order, titles, icons, themes, pinned tabs, folders, splits, Live Folders), Air Traffic Control routing rules & default destination, portable window layout (sidebar width, sidebar mode, toolbar visibility) |
| **Today Tabs** | Unpinned Today tabs, folders, and splits per Space |
| **Archive** | Archived tabs and folders per Profile (up to 2,000 most recent per Profile) |
| **Settings & Shortcuts** | Portable `open.*` browser preferences and custom Keyboard Shortcuts (`KeyBindingStore`) |
| **Ad Blocking** | Native ad-blocker enabled switch, per-Profile filter list choices, and allowed domains |
| **Boosts, Easels & Notes** | Per-Profile Boosts (CSS, JS, colors, fonts, text zoom, zaps), Easels and Notes with content-addressed encrypted image/asset blobs |
| **Browsing History** | Visited URLs, titles, and visit timestamps per Profile (up to 5,000 most recent per Profile) |
| **Chrome Extensions** | Chrome Web Store extension IDs, enabled state, and pinned toolbar order; missing extensions are queued in Settings ▸ Account & Sync for one-click install through Open's consent flow |
| **Passwords, Autofill & Site Permissions** | Autofill saving preferences, encrypted logins/addresses/credit cards (when running a signed Open build or with `--open-allow-mock-keychain-secrets`), and per-origin Site Permissions & content settings |

## First Sign-In Behavior

- **New / empty cloud account**: Signing up (or signing into an account with no cloud data) automatically encrypts and uploads the local Mac's setup.
- **Existing cloud account with data**: Open prompts the user to choose how to reconcile local and cloud state, defaulting to **Use Cloud Setup (Replace This Mac)** after saving an automatic local backup under `State/SyncBackups/` (retaining the 3 most recent backups). **Merge Local & Cloud** and **Keep This Mac (Replace Cloud)** are also available.

## UI Entry Points

- **Settings ▸ Account & Sync** (`open://settings/account-sync/account`): Sign In, Create Account, Recover Account, Recovery Key export, Initial Sync Choice, Sync Now, category toggles, pending Chrome extension installs, Connected Devices management, Change Password, Sign Out, and Delete Cloud Account.
- **Command Bar**: `Account & Sync…` (`account-sync`) and `Sync Now` (`sync-now`), plus all Account & Sync settings rows via `SettingsSearchIndex`.
- **Onboarding**: Skippable `Sync across your Macs` step between Ad Blocking and Default Browser (skipping writes nothing to disk).
- **Sidebar status banner**: `SyncBannerView` appears in the sidebar banner slot only when sync needs attention (error, re-authentication required, or pending initial sync choice).

## Running the Self-Hosted Server

The fastest way to spin up your own Open Sync Server is to click **Copy Agent Prompt** in **Open ▸ Settings ▸ Account & Sync** (or copy the prompt below) and paste it into any AI coding agent (Claude Code, Cursor, Codex, Antigravity, T3 Code, Windsurf, etc.):

```text
Set up a private Open Sync Server for my Open browser from https://github.com/SergeSerb2/open (the `SyncServer/` folder).

First, check which deployment tools I already have authenticated (such as `railway`, `flyctl`, `docker`, or `node`), or ask me where I want to host it:
- Railway (recommended easiest cloud setup)
- Fly.io
- Render
- Docker on a VPS / NAS / home server
- Local Mac (optionally over Tailscale)

Requirements:
1. Build and run `SyncServer/` using its `Dockerfile` (zero runtime dependencies, Node.js 22+ built-in SQLite + WebSockets). Do not modify server code unless required.
2. Run a single instance/replica only (SQLite WAL uses one writer).
3. Attach persistent storage mounted at `/data` and set `OPEN_SYNC_DATA_DIR=/data`.
   - On Railway: also set `RAILWAY_RUN_UID=0` (the entrypoint fixes `/data` ownership and drops back to unprivileged `node`).
   - Railway/Fly/Render `PORT` is supported automatically when `OPEN_SYNC_PORT` is unset.
4. Expose HTTPS with WebSocket upgrades forwarded on `/v1/sync/ws`, and set `OPEN_SYNC_TRUST_PROXY=1` whenever behind a reverse proxy or cloud edge.
5. Verify the live server before finishing:
   - `GET <url>/health` returns HTTP 200 with `{"ok":true,"service":"open-sync","version":1}`
   - Confirm `/v1/sync/ws` reaches the server (an unauthenticated upgrade returns HTTP 401, not 404/502)
   - Leave the database clean (delete any temporary test account).
6. Reply with my final `https://...` server URL so I can paste it into Open -> Settings -> Account & Sync -> Sync server.
```

See [`SyncServer/README.md`](../SyncServer/README.md) for manual Node.js 22+, Docker Compose, and Railway deployment details.
