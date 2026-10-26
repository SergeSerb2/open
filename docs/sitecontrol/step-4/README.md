# Step 4: native Boost editor

The native child-panel editor uses the existing Profile BoostStore, matcher and injection planner.
All fixtures use synthetic sites and suite-scoped preferences. The app-shell binding stays in
Steps 3/5; Zap and code tools stay disabled until Steps 6/7.

Lead decisions are recorded in plan §§4.3–4.4: host scopes keep their existing subdomain meaning,
IP scopes offer one host item plus the path item, and the first legacy color edit replaces the
filter as one undoable change. The harness reloads brightness 2 / invert 0.5 from the real file,
edits through a native control, then compares serialized filter bytes after Cmd+Z and reload.

Generate with `sitecontrol-render screens --group editor --out docs/sitecontrol/step-4`.
`sitecontrol-render check` verifies every PNG against [SHA256SUMS](SHA256SUMS), all native flows,
real AX hierarchies, exact panel fill after resize, and the release performance budgets.

The menu contact sheet captures AppKit's actual popup content. CARenderer cannot reproduce the
WindowServer backdrop of NSVisualEffectView, so the contact sheet supplies an opaque panel-color
plate and places the captured content beside the offscreen anchor. Other editor states render
the native child panel directly over the synthetic page.

| State | Light 1x | Light 2x | Dark 1x | Dark 2x |
|---|---|---|---|---|
| editor-interstitial | [light 1x](editor-interstitial-light@1x.png) | [light 2x](editor-interstitial-light@2x.png) | [dark 1x](editor-interstitial-dark@1x.png) | [dark 2x](editor-interstitial-dark@2x.png) |
| editor-simple | [light 1x](editor-simple-light@1x.png) | [light 2x](editor-simple-light@2x.png) | [dark 1x](editor-simple-dark@1x.png) | [dark 2x](editor-simple-dark@2x.png) |
| editor-advanced-color | [light 1x](editor-advanced-color-light@1x.png) | [light 2x](editor-advanced-color-light@2x.png) | [dark 1x](editor-advanced-color-dark@1x.png) | [dark 2x](editor-advanced-color-dark@2x.png) |
| editor-neutral-page | [light 1x](editor-neutral-page-light@1x.png) | [light 2x](editor-neutral-page-light@2x.png) | [dark 1x](editor-neutral-page-dark@1x.png) | [dark 2x](editor-neutral-page-dark@2x.png) |
| editor-not-active | [light 1x](editor-not-active-light@1x.png) | [light 2x](editor-not-active-light@2x.png) | [dark 1x](editor-not-active-dark@1x.png) | [dark 2x](editor-not-active-dark@2x.png) |
| editor-global-off | [light 1x](editor-global-off-light@1x.png) | [light 2x](editor-global-off-light@2x.png) | [dark 1x](editor-global-off-dark@1x.png) | [dark 2x](editor-global-off-dark@2x.png) |
| editor-legacy | [light 1x](editor-legacy-light@1x.png) | [light 2x](editor-legacy-light@2x.png) | [dark 1x](editor-legacy-dark@1x.png) | [dark 2x](editor-legacy-dark@2x.png) |
| editor-menu | [light 1x](editor-menu-light@1x.png) | [light 2x](editor-menu-light@2x.png) | [dark 1x](editor-menu-dark@1x.png) | [dark 2x](editor-menu-dark@2x.png) |
