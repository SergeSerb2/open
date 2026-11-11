# Library

Library opens inside the active browser window. The left rail contains Media,
Downloads, Spaces, Boosts, Archived Tabs and History. The web page stays visible
on the right. The sidebar Library button toggles the panel; ⌘Y opens History.
Downloads and the existing menu, command-bar, capture and Boost entry points use
the same panel. Little Open routes Library to a standard browser window.

The rail is 112pt wide. Ordinary sections end at x417; Spaces leaves 56pt of the
page visible. The selected tile has a fill. A focus ring appears during keyboard
navigation and clears with pointer input. Foreground and background come from
the active Space, using the sidebar's appearance resolution. Space cards use
their own opaque Space themes, a 0.5pt edge and soft shadow.

Before: the original separate Library, rendered with synthetic data:

![Original Library](settings/library-downloads@1x.png)

After: the in-window panel, captured from the real app with synthetic data:

![In-window Library](library/downloads.png)

[L3 correction frames](library/l3/README.md) show the approved row, Space-card,
Boost-chip and download-badge changes.

The native panel keeps a retained list host per section. An unchanged
warm switch shows the retained host without querying providers or configuring
rows. The first screen uses up to 60 lazy row sources; later sources append in
idle slices. Background snapshots cache sorting, day groups and folded search
keys. Each new query cancels the previous filter. Rows format text lazily. A background prefetch prepares cached text layout
and icons for the next two screens in the scroll direction. The panel keeps reusable 56pt rows, file icons and asynchronous
QuickLook image/PDF thumbnails. Downloads show numeric progress with an arrow
inside the progress ring. Archive and History retain their existing stores and
actions. Media shows page captures with the page title, or a host-based fallback;
its empty state says that captures appear here. Folder sources and Easels stay
behind default-off feature flags. History always appears.

Search stays separate for each section. Downloads, Archive and History have an
inline filter editor. Boost List/Gallery, Profile and card actions use theme
chips. Destructive actions use native confirmation sheets. Space cards retain
the existing rename, reorder, menu, delete/Undo and tab-navigation paths.

Escape closes a menu, then the filter editor, then clears search, then closes
Library. ⌘F focuses search. Arrow keys move the focused rail tile or list row;
Return opens a row. ⌘⌫ runs its destructive action. Tab follows the rail, search,
Filter and list. All keyboard checks use the application event path.

A completed download places a 39pt file preview over the sidebar Library button.
The newest file is on top; at most three previews stack at 3pt offsets. Hover
shows the filename, click opens Downloads and drag supplies a file URL. The
badge clears on Library open or expires after 60 seconds. The expiry task ends
when the last file expires. Private windows do not show the button.

`OpenLibrary` contains the AppKit panel, controls, reusable rows and filters.
`AppLibrarySession` owns one panel and `LibraryViewModel` per browser window.
Data providers and stores stay App-owned, with their existing actions. No Library
session or view is constructed at launch. An idle slice prepares the hidden
shell and first visible rows at least three seconds after the first sidebar draw and the last input;
new input cancels and reschedules it. It lays out and displays the hidden hierarchy
into retained layers, so a ready open only shows it. Closed store changes mark the
cache dirty and request another idle slice. Early opens use the cold path.
After Library first opens, input-cancelled idle slices warm each section's
first provider page without changing the visible section, query or filters.
Capture reads, Archive page merging/title decoding, History SQL and Boost
reads run off the main thread. A cold section commits its header and empty list
container first, then applies the returned rows. Plain skeleton plates appear
only if the provider takes more than 120 ms.

The viewport uses fixed frame geometry, cached attributed text and icons,
layer plates, and a bounded pool of native cells that stay attached. A settled
section configures, lays out and displays one screen of overscan above and
below. Scrolling reuses those cells. A fast scroll also prefetches the predicted
next viewport. The scroll benchmark records nested clip/dequeue/configure/layout,
tracking, display and flush phases. Its run-loop heartbeat and 2 ms background
watchdog exist only during that benchmark and stop before the socket reply. Search uses a retained plain
text field/editor with prediction and substitution disabled; text changes start
filtering in the same event. The idle slice also warms fonts, formatters, row kinds
and icon raster conversions. It has no constraints or row-height
delegate. Cheap store invalidation remains armed while closed; preparation stops;
60 seconds later the heavy views and model image caches are released. Reopen cancels
that release. Closing a browser window removes its session and releases its
panel on the next event-loop turn. The old `LibraryWindow`, SwiftUI section views and History feature
flag have been removed.

Open/close uses the 0.12/0.20-second page transition. Sections cross-fade over
0.10 seconds. Reduce Motion uses fades without movement. Closed panels have no
active animation, display link or repeating timer.

The automation socket retains existing Library entry points and adds `library`
state/actions for geometry, rows, search, filters, menus, focus, lifetime and
motion. `tools/e2e/library_overlay.py` and `library_content.py` drive the real app,
with a disposable profile and executable-path cleanup. They send no system
mouse or keyboard events. File/URL pasteboards and native source-drag start are
verified. **Manual check:** drag a download row to Finder and a web upload field;
foreign-app drop/end is unverified by automation.

[Validation and current qualification limits](library/validation.md) record the
five-pair timings, idle attribution and scroll result.

[Shared contrast measurements](library/contrast.md) retain the known theme
failures. The lead owns the D2 follow-up. Geometry comes from the approved Open
mock-up and the private C capture measurements; all icons are Open's own vectors.
No Arc assets or pixels are included.
