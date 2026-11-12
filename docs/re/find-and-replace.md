# Find and Replace (Edit ▸ Find ▸ Find and Replace, ⌘⌥F)

Arc 1.170.0 reference binary and the shared `ArcMain` Ghidra project; capture session 9 on Arc 1.172.2
(PB2-questions "C3 10:20" and "C3 10:30"). Raw output: `.re/find-replace/` (not committed).

| Kind | Finding | Evidence |
|---|---|---|
| FACT | Every item of the Find submenu sends `arc_performFindPanelAction:`; the item's tag selects the action (Find and Replace = 12, AppKit's "show replace interface"). | MainMenu nib ([menu report](menus-and-hotkeys.md)). |
| FACT | Four classes implement `arc_performFindPanelAction:`: `Arc.MainWindowController`, `Arc.FindInPageView`, `Arc.CommandFTextField` and `TextEditor.TextEditorViewController` (the Note editor). | The selector's slot in `__objc_selrefs` (`0x10449b278`) is named by four entries of `__objc_methlist`; their implementations are `0x10031fd94`, `0x10032bb14`, `0x100107e7c`, `0x101e7b68c`. |
| FACT | The window handler acts on tags 1 (show Find), 2 (next), 3 (previous) and 7 (use selection) only. Tag 12 falls through: no action. | `FUN_10031f6fc` (the body behind the thunk at `0x10031fd94`): comparisons `tag == 1`, `2`, `3`, `7`, no other case. |
| FACT | The Find bar's view and its text field handle tag 1 only (select all in the field, or run the field's ⌘F callback). Other tags go to the next responder with `tryToPerform:with:`. | `FUN_10032b884`, `FUN_100107cc0`. |
| FACT | The Note editor answers any Find menu action the same way: it makes a menu item with tag 1 ("show find interface") and sends its text view `performTextFinderAction:`. It does not read the sender's tag. | `FUN_101e7b5c0`; the Objective-C stub at `0x1035f7bc0` loads the selector `performTextFinderAction:`. |
| FACT | On a web page, Find and Replace shows nothing in Arc 1.172.2: no bar, panel or window, with or without a focused text input. | Capture session 9 (PB2-questions "C3 10:30"). |
| FACT | No Easel class implements the action. | The four implementations above are the complete list. |

## Open

- Web page: Find and Replace (menu item and ⌘⌥F) has no effect. The item stays enabled, as the other Find items are.
- Note: Find, Find Next, Find Previous, Use Selection to Find and Find and Replace show the Note body's native find
  bar (no replace field). Jump to Selection is disabled in a Note.
- Rows: `find` suite `F20_find_replace_no_page_effect`, `F20_find_replace_key_no_page_effect`,
  `F20_find_replace_keeps_open_bar`, `F33_note_find_replace_shows_find_bar`, `F33_note_find_shows_find_bar`.
