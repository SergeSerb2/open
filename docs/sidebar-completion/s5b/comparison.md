# Previews sheet comparison

Reference: parent-supplied S2 02/0050 at
`/Users/m1-dev/.t3/projects/open/.re/runtime/sessions/20261026-100621-02-settings-setup/0050-100747/`.
Read-only evidence: `win-71416.png` and `ax.json` (`AXSheet.frame` width/height
422/370, seven `AXCheckBox` source rows, Done button). No capture, AX dump,
or user data is committed. This comparison records facts in our own words.

| Property | Supplied capture | Open real-window rest/hover | Interpretation |
|---|---|---|---|
| Delay control | None | None | S5b matches this behavior. |
| Sheet size | 422×370 pt | 480×320 pt | Accepted Open size, unchanged by S5b. |
| Source controls | Seven checkboxes for folders and service integrations | Master, Folders, Pinned tabs and Favorites switches | Accepted v1 Open source set; service integrations are deferred. |
| Header and explanatory copy | Master-style heading plus description and Learn more | Previews title, master switch | Existing Open sheet structure retained as specified. |
| Done | Bottom-right default button, shortcut badge visible | Bottom-right existing default button | Placement/function retained; existing button appearance differs. |

The supplied frame is a single reference state. It does not provide an
independent Arc hover-state transition. Compare both Open snapshots against
that same frame without inferring a new Arc hover color or motion value.
No cross-product pixel-equality claim is made for these intentionally different
sheet layouts. The parent owns formal code and UI review.

The real Open run is `app-flow.json`: `SheetPresentationWindow` 5959 was
visible, key, attached to General Settings, and exactly 480×320 pt. Both
[rest](previews-rest@2x.png) and [Done hovered](previews-hover@2x.png) are
960×640 window-server captures (`windowserver+devtools`), not offscreen
renderer output. I inspected both against the supplied capture: all three
switch labels and Done are visible, and no Delay row remains. The rest and
Done-hover PNGs are byte-identical: the hover point is inside Done, and
`SettingsButtonStyle` changes on press rather than hover. Open's existing light sheet, switches and blue
Done button differ from the capture's dark sheet and checkboxes. S5b does
not change those colors, styles, or the accepted dimensions. No color-fidelity
claim is made across the two appearances.

This counted run uses the rebuilt 21:38 engine distribution. Its canonical
framework hash and exact signing transformation are recorded in `app-flow.json`
and `engine-signing-proof.json`. The earlier engine images are historical.
