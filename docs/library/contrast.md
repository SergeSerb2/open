# Local contrast measurements

Native 2x PNGs converted from embedded ICC to sRGB. Foreground comes from the actual sidebar and Library socket tokens. Background is the median of a 5x5 pixel patch beside the text, outside glyph ink. Sidebar primary uses the unselected row immediately above the current row (x180, row midpoint); selected-row contrast is also retained in JSON, but its bright selected fill is not a fair comparison for unselected Library rows. Library row samples are x160 at title/subtitle baselines; rail samples are the bottom of each tile. The six annotated sample strips are in contrast-samples.png. Secondary and unselected tile text use the real 0.68 alpha. Thresholds: primary 4.5, secondary 3, tile labels 3. Sidebar was captured first in each pair.

| Theme | Appearance | Sidebar primary | Library primary | Secondary | Lowest tile | Result |
|---|---|---:|---:|---:|---:|---|
| peach | light | 7.22 | 7.22 | 3.89 | 3.47 | PASS |
| peach | dark | 1.90 | 1.90 | 1.56 | 1.71 | shared theme/fixture |
| ocean | light | 6.84 | 6.08 | 3.54 | 3.41 | PASS |
| ocean | dark | 2.01 | 2.26 | 1.75 | 1.52 | shared theme/fixture |
| night | light | 3.78 | 3.81 | 2.61 | 2.34 | shared theme/fixture |
| night | dark | 3.70 | 3.66 | 2.56 | 2.75 | shared theme/fixture |

Follow-up: the lead assigned shared sidebar/theme contrast to D2 after L2 review.
The Library uses the same foreground tokens as the real sidebar. This PR does
not change those tokens or claim that the four failing pairs pass.
