# Update UI

Open uses one custom AppKit Sparkle user driver. Sparkle stays in the App.
OpenKit contains only banner state and views. The UI follows the legacy update
surfaces recorded in [software-update.md](../re/software-update.md).

The Open menu shows Check for Updates…, Updating…, or Update Available….
An available update has a count badge. The command remains enabled during an
update and brings its current window forward.

The small status window shows checking, download bytes, preparation progress,
and Ready to Install. Download can be cancelled. Preparation cannot be
cancelled. Install and Relaunch asks Sparkle to finish the update.

The update window shows the current and offered versions. It has Download and
Remind me Later buttons. Critical and minimum-version updates cannot be
dismissed. Information-only updates open their page in a new foreground tab.
The up-to-date window says Your browser is up to date.

Release notes use Foundation's full Markdown parser and an NSTextView. The
source is limited to the first 64 KiB before parsing. HTML-format descriptions
are plain text after one bounded tag scan. Only amp, lt, gt, quot, and #39
entities are decoded. The update UI creates no WebKit view and calls no HTML
importer. Notes use 12 pt system text, 20 pt lines, white or black backgrounds,
and #458AFF links. Links open in a new foreground Open tab.

Sparkle 2.10.1 exposes `SUAppcastItem.itemDescriptionFormat` and accepts
`<description sparkle:format="markdown">`. Its source reads this attribute in
`SUAppcast.m` and accepts `markdown` in `SUAppcastItem.m`. The published header
comment omits Markdown. **Pipeline follow-up for the lead:** `tools/release.sh`
must embed the release Markdown in the item description with this attribute.
The current release plan uses Markdown source (§8.3) but describes HTML output.
This UI change does not change the release script.

Known launch-cost item: the pinned Sparkle binary eagerly links WebKit. The
launch-fixes work owns delaying the Sparkle load. This UI keeps the existing
Sparkle dependency and does not build it from source.

The UI uses event callbacks. It adds no timers, polling, or display links.
Status and updater windows are created when needed and released on close.
Banner views exist only while a banner or its dismissal animation is needed.

A background update ready to install takes the bottom sidebar banner slot.
Clicking it asks for Restart or Cancel. Dismissal lasts for the session. With
automatic updates off, dismissal increments a count and applies no threshold.
The auto-archive education banner waits while an update banner uses the slot.

On the first launch after a build increase, the summary banner says Open
Updated! Its What's New action opens that version's release page. Dismissal
is stored for the build. A first install shows no summary. Neither update
banner has an automatic dismissal timer.

User-requested errors show Update error!, OK, and Download manually.
Background errors use the existing toast system. General has the automatic
update switch, its help link, Check for Updates…, and the core's status text.

Signed install and relaunch remain a user qualification step. An ad-hoc test
build cannot prove the production signing, installation, or relaunch path.
