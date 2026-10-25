# Open build plan

Each milestone ends with a PR against `main`. Each PR is verified end to end on the running app.

| # | Milestone | Content | Depends on |
|---|---|---|---|
| M0 | Research + engine spike | Arc reverse-engineering reports (`docs/re/`). CEF spike: build system, `OpenEngine`, extensions verdict, automation channel. | — |
| M1 | Foundation | `OpenKit` package (model, store, design tokens, web protocols). Arc-style window: full-height sidebar, hidden title bar, inset rounded web content. Tabs: create, select, close, navigate. Menu bar skeleton with Arc shortcuts. | M0 |
| M2 | Sidebar 1:1 | Favorites grid, pinned and today sections, folders, drag and drop, Spaces with themes, Space switcher and swipe, archive and auto-archive, pinned-tab reset, sidebar toggle and hover reveal. | M1 |
| M3 | Command bar + URL | Cmd+T / Cmd+L command bar, history store with FTS5, tab search, actions, search engines, copy-URL toast. All remaining menus and hotkeys. | M1 |
| M4 | Split View, Peek, Little Arc | All three, plus default-browser handling for Little Arc. | M2 |
| M5 | Profiles + routing + settings | Profiles mapped to CEF request contexts, Space-to-profile link, Air Traffic Control rules, settings window. | M2 |
| M6 | Site tools | Boosts (CSS/JS/color/font), Zap, Site Control Center, ad blocking with filter lists. | M1 |
| M7 | Extensions + web platform | Extension toolbar/menu, popups, install flow; downloads, find in page, context menus, PiP + media controls, permissions, AppleScript (Arc's `.sdef` terms). | M0 verdict, M1 |
| M8 | Import from Arc | Spaces, pinned tabs, folders, favorites, archive; optional history, cookies, passwords. | M2, M5 |
| M9 | Polish + ship | Motion and sound pass, performance pass against budgets, signing, notarization, Sparkle updates. | all |

M2, M3, M6, and M7 can run in parallel after M1, because they live in different `OpenKit` libraries.
