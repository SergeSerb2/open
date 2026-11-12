# Favorite tile badges and subtitles (audit A2)

Arc calls Favorites "Top Apps". Static facts come from Arc 1.170.0 (the reference copy) and the shared
`ArcMain` Ghidra project. The raw output is in `.re/a2/`, which is not committed. A capture item for
the look and the badge source is in PB2-questions.md, "EZ 13:20".

| Kind | Finding | Evidence |
|---|---|---|
| FACT | The Favorite context menu has a checkmark item "Show Unread Badge" (comment: toggles Top App badging) and a checkmark item "Show Time to Next Meeting" (comment: toggles GCal Top App subtitles). | `strings -a` on the Arc binary (string "Show Unread Badge" and its comment); the 25-byte title at `0x103a37900` and its comment at `0x103a384f0`, read from the arm64 slice. Both are used in `FUN_102ee07bc`, whose fatal-error path is `ContextMenus/SidebarMenu+PlatformSpecificItems.swift`. |
| FACT | The item's checkmark is a membership test of the tile's kind in a stored set (`FUN_10025008c`: a Swift `Set` lookup by hash). The preference keys are `topAppsBadgingDisabledHosts` and `topAppsSubtitleDisabledHosts`. | `FUN_102ee07bc` → `FUN_10025008c`; key strings in `strings -a`. |
| FACT | The tile kind comes from the Favorite URL's host through one Swift string switch with 11 cases; no match means no kind (`0xb`). The kind's string is a host: twitter.com, mail.google.com, calendar.google.com, outlook.live.com, calendar.notion.com, spotify.com, youtube.com, notion.so, slack.com and figma.com are among them. The display names include WhatsApp, Twitter, Gmail, Google Calendar, Notion Calendar, Spotify, Notion and Figma. | `FUN_102ee14c0` (URL host) → `FUN_102ee1d50` (`_findStringSwitchCase`, result > 10 → `0xb`); `FUN_100d63ee0` jump table (small-string immediates; long strings at `0x10394cb00`, `0x10394a2e0`, `0x10394cb20`); the name table at `0x100d64064`. |
| FACT | Kinds 3, 4 and 10 are behind feature flags (`0x15`, `0x1d`, `0x17`). | `FUN_102ee17f8`. |
| FACT | Badge and subtitle colors (sRGB): GMailBadgeRed and WhatsAppBadgeRed (0.918, 0.263, 0.208); GithubBadgeBlack (0, 0, 0); TwitterBadgeGray (0.267 gray light, white dark); GCalSubtitle* as in docs/re/live-data.md. | `xcrun assetutil --info ARC_AppTray.bundle/…/Assets.car`. |
| FACT | Two more switches: `twitterBadgeEnabled`, `whatsAppBadgeEnabled`. No Settings row uses them. | `strings -a`; docs/re/live-data.md §3.1. |
| GUESS (strong) | The unread count comes from the page title. A number parser (`failed to process "Int"`) follows the `AppTrayBadgingProvider.swift` path, and the binary holds a `\s\(\d+` regex fragment. | `strings -a` lines next to `Arc/AppTrayBadgingProvider.swift`; the regex fragment. |
| GUESS | Which kinds show a badge (Open: Twitter/X, WhatsApp, Gmail, Outlook, Slack); the badge shape, size, position and the "99+" cap; that the Twitter and WhatsApp items write their own switches; the menu position of both items. | Capture pending. |
