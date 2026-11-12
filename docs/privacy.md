# Your data in Open

Open is a macOS browser. Your browsing data stays on your Mac.

- **No account.** Open has no sign-in and no Open account.
- **No sync.** Tabs, Spaces, history, passwords and settings are stored only on this Mac, in Open's data folder. Nothing is copied to a server.
- **No telemetry.** Open does not collect usage analytics, crash reports or other telemetry.
- **Safe Browsing is off.** Open does not send the addresses you visit to a Safe Browsing service.

## What Open connects to on its own

Besides the websites you open, Open makes these requests:

| Request | When | Sent to |
|---|---|---|
| Update check | Periodically, to find a new version of Open | The Open release feed (`sergeserb2.github.io`) |
| Ad-block filter lists | When the ad blocker refreshes its lists | The publishers of the lists you have turned on |
| Search suggestions | While you type in the command bar, only if suggestions are on for the Profile | The search engine of that Profile |
| Extensions | When you add or update an extension | The Chrome Web Store |

## Your data on disk

Open keeps its data in its own folder under `~/Library/Application Support`. Deleting that folder removes this data from the Mac.

Questions: <https://github.com/SergeSerb2/open/issues>
