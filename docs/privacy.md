# Your data in Open

Open is a macOS browser. By default, your browsing data stays on your Mac.

- **Optional account and zero-knowledge sync.** Open works offline with no account. If you turn on Account & Sync in Settings (or during setup), you choose a self-hosted or custom Open Sync server. Your browser setup is end-to-end encrypted on your Mac with AES-256-GCM before upload, using a vault key wrapped by your password and recovery key. The server never sees your raw password, encryption key, tabs, settings, history, or passwords.
- **No telemetry.** Open does not collect usage analytics, crash reports or other telemetry.
- **Safe Browsing is off.** Open does not send the addresses you visit to a Safe Browsing service.

## What Open connects to on its own

Besides the websites you open, Open makes these requests:

| Request | When | Sent to |
|---|---|---|
| Account & Sync | Only if you sign in to an Open account | The Open Sync server URL you configured |
| Update check | Periodically, to find a new version of Open | The Open release feed (`sergeserb2.github.io`) |
| Ad-block filter lists | When the ad blocker refreshes its lists | The publishers of the lists you have turned on |
| Search suggestions | While you type in the command bar, only if suggestions are on for the Profile | The search engine of that Profile |
| Extensions | When you add or update an extension | The Chrome Web Store |

## Your data on disk

Open keeps its data in its own folder under `~/Library/Application Support`. Deleting that folder removes this data from the Mac.

## What websites can read

With Settings ▸ Advanced ▸ "Allow websites to get your theme data" on (the default), pages can read the colours of the current Space's theme as CSS variables. Turn the setting off to stop this.

Questions: <https://github.com/SergeSerb2/open/issues>
