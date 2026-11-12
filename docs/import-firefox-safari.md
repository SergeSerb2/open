# Import from Firefox and Safari

Settings ▸ Import ▸ Firefox (or Zen, LibreWolf, Floorp) or Safari. The source picker and the Chromium path are IMC's (`ImportSourcePicker`, `AppImportRunner+Browsers.swift`). This page covers the Firefox family and Safari (IMF). Findings: `docs/re/browser-import.md`.

## What is imported

| Data | Firefox family | Safari |
|---|---|---|
| Bookmarks | `places.sqlite`: Toolbar, Menu, Other, Mobile roots. Tags, separators, `place:` and `javascript:` URLs are skipped and counted. | Live `Bookmarks.plist` (Favorites, Bookmarks Menu, Reading List), or the bookmarks HTML in the export ZIP |
| History | `moz_historyvisits` (embeds and framed links skipped, as Chromium subframes) | Live `History.db`, or `History.json` in the export ZIP |
| Passwords | `logins.json` + `key4.db`. Primary Password: the user types it on the Choose step; it is used once and never stored | The `Passwords.csv` in the export ZIP, or a CSV that the user picks (Safari or Passwords app ▸ File ▸ Export All Passwords) |
| Search engine | not imported | not imported |
| Form data | read and counted by `FirefoxFormHistoryReader`; not written (no engine write path, IMF question 1) | — |
| Cookies | no (lead ruling 2) | no (not readable) |

Bookmarks become one pinned folder "Imported from <Browser>" in the focused Space (Arc parity, F3 §5), built by `BrowserBookmarksImport.sourceModel`. History goes to that Space's Profile. Passwords go to the same Profile through the engine login sink. Undo (Edit ▸ Undo "Import from <Browser>") removes the bookmarks and the history; imported passwords stay, as for the Arc import.

## Access

- **Safari: Full Disk Access.** Safari stays selectable without access. On Next, Open opens System Settings ▸ Privacy & Security ▸ Full Disk Access at once (Arc does the same: C-report-s5 §1, u3 00:55:08) and shows the Access step. Open checks once per second and continues by itself when access is on. "Use Exported File…" skips the need for access.
- **Firefox running.** When Firefox (or Developer Edition, Nightly) runs, or a profile's `.parentlock` is locked, the Access step says "Quit Firefox to continue importing." (Arc's string). Open continues by itself when the lock is gone.

## Two Safari routes, two folders

The export ZIP has no bookmark UUIDs; the live `Bookmarks.plist` has them. The two routes therefore use different import keys (`safari:safari:Safari` and `…:export`). If a user imports both ways, the sidebar gets two "Imported from Safari" folders. This is accepted (lead 01:25, 12 Nov). Arc has the same split: two separate engine importers. Re-importing through the same route updates in place.

## Checks

- `openkit import-firefox --expect` and `openkit import-safari --expect` on `openkit firefox-fixture` / `safari-fixture` output (readers only).
- `tools/e2e/engine_e2e.py --only import-other-browsers`: the real Settings sheet with a synthetic `--browser-import-library`. Under the mock keychain the engine accepts only `example.com` logins and only with `--open-allow-mock-keychain-secrets`; the fixtures and the suite follow both rules.
