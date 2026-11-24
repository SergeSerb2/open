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

See [`SyncServer/README.md`](../SyncServer/README.md) for local Node.js 22+ and Docker setup instructions.
