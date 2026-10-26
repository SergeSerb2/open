# Boosts + Zap browser harness

From this directory, run `python3 serve.py --port 8931` in a managed background
session (or use `subprocess.Popen(..., start_new_session=True)`). The server binds
only 127.0.0.1 and serves this folder and the sibling production Resources folder.
It sends no CSP and disables caching. No install or build step is needed.

Start at http://127.0.0.1:8931/Harness/loader.html, then use:

- http://127.0.0.1:8931/Harness/static.html
- http://127.0.0.1:8931/Harness/spa.html
- http://127.0.0.1:8931/Harness/shadow-dom.html
- http://127.0.0.1:8931/Harness/obfuscated.html

The loader contains the canonical bridge/bar snippet, copied verbatim to all four
pages. It simulates the abstract engine bridge. It does not run the Swift matcher.
Use T3 `preview_open`, `preview_navigate`, `preview_click`, `preview_hover`,
`preview_press`, `preview_evaluate`, and `preview_snapshot`. Do not use the desktop.
The bar is excluded from Zap capture by `data-open-zap-ignore` so its controls work.

F1 adds a red header outline and hides the banner. F1b has identical content and a
different plan ID. F2 adds hue/saturation and Georgia (code stays monospace). F3
increments a page counter once per plan ID. F-shadow hides `#shadow-promo` in
reachable roots. Text controls apply 1.25 zoom and uppercase with form/editable
exclusions. Bad-zap combines F1 with an invalid selector. Clear removes managed
styles. Enter Zap starts picking; Undo reverses the last pick; Escape and Exit
end it. Re-apply with committed zaps simulates native persistence, including
replacement/removal events. The global checkbox sends an empty plan when off.

Harness fixtures run arbitrary JS by design.

## Measurements

Use `preview_evaluate` on static.html after clicking F1. Record all five values and
the median. The P1 gate is median < 1 ms. Clone outside the timed interval:

```js
(() => {
  const plan = window.__harness.lastPlan;
  const values = [];
  for (let i = 0; i < 5; i++) {
    window.__openBoosts.clear();
    const copy = structuredClone(plan);
    copy.planID = i % 2 ? "harness-F1b" : "harness-F1";
    const t0 = performance.now();
    window.__openBoosts.apply(copy);
    values.push(performance.now() - t0);
  }
  return { values, median: [...values].sort((a,b) => a-b)[2], state: window.__openBoosts.state() };
})()
```

P1 measures style construction after parse. It is an upper bound for that work,
not proof of production document-start timing. Engine measurements remain future work.

For P2, enter Zap, then use real `preview_hover` on five distinct visible elements.
Click **Perf hoveredAt**. Read `window.__harness.perfHover`: twenty pure hit-test
samples, median, and max, in ms. The median gate is < 2 ms. This is a proxy for the
hover callback; report full-hover latency qualitatively and state any capture limit.
No synthetic mouse event is used. On a fresh unapplied page, the same button gives
the baseline. Idle timer/observer absence is a source-reading check, not a tool claim.

For P3, use five runs at the article padding (not the child heading):

```js
(() => {
  const r = document.querySelector("article").getBoundingClientRect(), values = [];
  for (let i = 0; i < 5; i++) {
    const t0 = performance.now();
    window.__openZap.candidatesAt(r.x + 4, r.y + 4);
    values.push(performance.now() - t0);
  }
  return { values, median: [...values].sort((a,b) => a-b)[2] };
})()
```

The P3 guidance is < 50 ms. Selector generation runs on click, never on hover.
See docs/boosts.md for the complete H/A/S-A/S/O/E results and measured budgets.

## Known limits

A blanket font override can break icon fonts. Partial invert affects media; the
counter-rule is emitted only for full invert. Closed roots that predate the first
apply cannot be found. The shadow fixture exposes closure-based computed-value
helpers for that limit; it never exposes closed-root objects. The picker can pick
a closed host, not its internal content. Iframe content needs per-frame engine
injection. Inline Boost JS can be blocked by page CSP, and arbitrary JS side effects
cannot be undone by Clear. Editing JS needs reload for a clean execution state.
The runtime applies in both normal and incognito contexts; product policy and
settings/editor UI belong to later milestones.
