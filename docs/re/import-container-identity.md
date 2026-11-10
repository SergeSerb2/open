# Arc sidebar container identity

`StorableSidebar.json` stores `sidebar.containers` as alternating identity/value
pairs. The global sidebar has identity `{"global": {}}`. A Little Browser
container has `{"littleBrowser": {"_0": "<redacted-id>"}}`.

The pair order is not stable. On 2026-11-10, Arc 1.172.2 on the M5 had several
Little Browser pairs before the global pair. The global value had six Spaces
and 60 item records. A Little Browser value had one Space and two or three
item records. Reading array element 1 therefore selected a Little Browser.
No title, URL, or source identifier is included here.

Evidence: read-only `StorableSidebar.json`, fields `sidebar.containers`,
`spaces`, and `items`; the counts-only extraction below reproduces the shape.
Agent P's independent before/after route receipt is
`.re/perf/setup/arc-active-route/route.json` in its performance worktree.

```python
import json
from pathlib import Path
root = Path.home() / 'Library/Application Support/Arc/StorableSidebar.json'
containers = json.loads(root.read_text())['sidebar']['containers']
for index in range(0, len(containers) - 1, 2):
    key, value = containers[index:index + 2]
    print(list(key), len(value.get('spaces', [])) // 2,
          len(value.get('items', [])) // 2)
```

Open now selects the unique global identity for model import, the count-only
probe, review mapping labels, and live-item filtering during Archive import.
Missing or duplicate global identities are malformed input. It never falls
back to an arbitrary pair or the container with the most items.

The real-App `import-robust` suite uses synthetic global and Little Browser
pairs in both orders through first run and Settings. It also checks refusal
without model mutation when the global identity is missing or duplicated.
`OPEN_E2E_IMPORT_ROBUST_ONLY=containers` selects those six rows.
The fixture contains no user data. Synthetic fixtures now use the observed
global identity instead of an unobserved string key.

The real `openkit import-arc` CLI also exercises both pair orders and the two
refusal cases. The saved pre-fix CLI from the 2026-11-10 main sweep imports
one Little Browser Space when that pair comes first, accepts a missing global
identity, and accepts a duplicate global identity. The fixed CLI imports the
two synthetic global Spaces in both orders and refuses both malformed cases.
All four source fixtures remain unchanged. Private receipts and the old binary
hash are in `.re/gate-health/step3/import-cli{,-old}/results.json`.
