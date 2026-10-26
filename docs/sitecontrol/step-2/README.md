
## Round 2 review fixes

The current set contains 80 light/dark, 1x/2x renders, including static Reload,
section/row hover, keyboard focus, picker fallback, the native menu, ad-block tooltips
(on/off/unavailable), private-window tooltip, a pane bar and a dark-Space/light-system state.
The 16 motion frames were regenerated. SHA256SUMS covers the current files.
Native event flows cover tracked Return and menu cancellation, command-key guards,
fixed top-left motion, recovered error episodes, and unclipped Reload growth.
The host is exposed once through the panel AX description; actions precede the labeled scroll area.

Native menu capture waits for AppKit's actual visible popup surface, with a 2 s timeout.
It opens once; it does not retry a menu or a test. This fixes a first-popup capture race
found in the full Step 4 gate under machine load. The current menu renders are byte-identical.
The preceding raw gate is retained in review-r2-prior-checks.txt / review-r2-prior-verify-all.txt.
