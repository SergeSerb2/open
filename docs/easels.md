# Easels

Easels are free-form canvases that sit in the sidebar like tabs (Arc parity; facts in `docs/re/easels.md` and
`docs/re/easels-notes.md`). Open keeps them local: no account, no hosted share links, no presence.

## Model and storage
- An Easel is a sidebar `Tab` with the internal URL `open://easel/<uuid>`. It pins, sits in folders, splits and
  archives like any tab, and never reaches OpenEngine. The App shows it with `EaselContentHost` (`App/Easel/`).
- Content: `<data root>/Easels/<uuid>/document.json` (`OpenEasel.EaselDocument`) and `images/<sha256>.<ext>`.
  Saves are debounced (500 ms) and atomic. Pending edits are written on close and on quit. A document that breaks a
  limit (`EaselDocument.isValid`, file ≤ 64 MiB) is renamed `document.refused-<time>.json`, and the row opens a
  fresh Easel.
- Object frames are in document points: the page is 1000 pt wide and grows downward. The export uses fractions of
  that width (findings §3.8 schema).

## Entry points
- File ▸ New Easel ⌃⇧E, the sidebar "+" menu, and the command bar.
- Capture card ▸ Add to Easel: New Easel, or each Easel of the Profile.
- Library ▸ Easels lists every Easel document. This includes Easels whose row or Space is gone, as in Arc. The page
  has the "Your Easels are yours to keep" card with Export All Easels, per-row Delete, and the empty state.
- Easel row menu (Arc's order): Copy Link (the Easel's own address; it opens the Easel from the command bar) ·
  Save as Web Page… · Change Icon… · Rename… · Add Split View · Move to ▸ · Remove Easel from Sidebar · Delete
  Easel.

## Canvas
Tools: Pointer, Image, Text, Ellipse, Rectangle, Arrow, Freehand, and the split button. The canvas has:
- Colour palettes (Vibrant, Chill) and alignment guides.
- Its own undo stack.
- Zoom (⌘− / ⌘= / ⌘0: 33 % … 400 %).
- Pictures, link cards (Open Graph metadata) and web cards (captures).
- Live web cards: at most 3 live pages per canvas. The pages are released when the Easel hides.

## Import and export
- Save as Web Page… writes one Easel, and Export All Easels writes a zip of every Easel. Each export holds our own
  viewer (`index.html`), `easel.json` and `images/`.
- Import: Arc's "Export All Easels" folder or zip (`EaselImporter`, `importArcEaselExport`). Each Arc Easel id maps
  to a stable Open document id, so re-imports update in place.

## Left out on purpose
- **Browser object and its search tool** (Arc's `browser` content and the DuckDuckGo search tool). Arc 1.172 keeps
  both behind a flag (`easel-search-tool-enabled`), and its toolbar's add button opens a Split instead. Open matches
  that default (LEAD 04:05). An imported `browser` object becomes a link card.
- Sharing by link, collaborators and presence (they need Arc's servers).
- The invite button at the toolbar's bottom-right.

## Verification
`tools/e2e/engine_e2e.py --only easel` (`tools/e2e/easel.py`) covers every row above through the automation socket.
The rows are E01–E38, I01–I03 and L01–L05.
