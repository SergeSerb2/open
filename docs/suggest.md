# OpenSuggest: command bar backend (M3)

Status: implemented. Package target `OpenSuggest` in `Packages/OpenKit`.
No third-party dependencies. Verification is end to end through the `openkit` CLI.
No unit tests, per AGENTS.md.

OpenSuggest is the engine-agnostic, UI-free backend of Open's command bar.
It covers Cmd+T (new tab), Cmd+L (edit current URL), and tab search.
Evidence for Arc behavior is in `docs/re/features-core.md` §4 and
`docs/re/menus-and-hotkeys.md`. Arc ranks with an on-device ML model
(`LocalCommandBarRanking`). Open uses the deterministic heuristic in this file.

## Modules

| Target | Role |
|---|---|
| `OpenSuggest` | Providers, ranking, Site Search, calculator, remote suggestions. |
| `openkit suggest` | Runs one query against a saved snapshot and prints every snapshot. |
| `openkit suggest-check` | Builds a synthetic model and history database. Runs fixed scenarios through the real engine. Prints PASS/FAIL per scenario and latency percentiles. Exits non-zero on any failure. |

OpenSuggest depends on `OpenModel` and `OpenStore` only.
It never imports the engine layer or AppKit.

## API

```swift
SuggestEngine(model:history:fetcher:)
engine.query(_:context:) -> AsyncStream<SuggestionSnapshot>
engine.prewarm()
engine.siteSearchTrigger(for:) -> SiteSearch?
engine.cancel()
```

`SuggestEngine` lives on the main actor. The app owns one engine.
`prewarm()` builds the tab index and loads the Public Suffix List off the main actor.
Call it when the command bar is about to open.

### Input

`query(_:context:)` takes the raw text and a `SuggestContext`.

| Field | Use |
|---|---|
| `mode` | `newTab` (Cmd+T), `editCurrentURL` (Cmd+L), or `searchTabs`. |
| `profileID` | Results come only from this Profile. Nil means the Profile of `spaceID`. If both are nil, every Profile is used. |
| `spaceID` | The Space of the window that opened the command bar. Its tabs get +3. |
| `currentTabID` | The selected tab. Edit mode never offers Switch to Tab for it. Action availability reads it. |
| `currentTabURL` | The current tab URL. Edit mode starts with this URL. Remote suggestions skip it. |
| `allowsRemoteSuggestions` | False turns off the network provider. This is the setting "Include search engine suggestions" and the CLI flag `--offline`. |
| `searchEngineID` | `SearchEngine.id`. Nil means Google. The Profile stores the choice. |
| `siteSearchID` | Set while Site Search is active. The query then searches that site. |
| `allowsInlineCompletion` | The command bar's rule: the last edit was an insertion at the end of the text (commandbar-completion §4.1.1 rule 2). Default false. With it, rule T3a may pick the top hit and the snapshot may carry `inlineCompletion`. |

### Output

The stream gives one or more `SuggestionSnapshot` values.

- Snapshot 0 holds every synchronous local provider.
  It is already buffered when `query` returns. The UI can read it at once.
- Each async provider (history, then remote) adds one snapshot when it finishes.
  `sequence` counts snapshots. The last snapshot has `isFinal == true`.
- `pendingProviders` lists async providers that still run.
- `timings` gives one entry per provider run, in milliseconds.
  Async entries have `isAsync == true`.
- `suggestions` holds at most `maxResults` rows (default 12), top hit first.
- `hasTopHit` is true when one row is the default Return action.
  `topHit` gives that row. `topHitRule` names the rule that picked it.
- `inlineCompletion` (`InlineCompletion`: `rowID`, `fieldText`, `typedLength`) is the
  text row 1 completes in the field, or nil. Only with `allowsInlineCompletion`;
  only for tab and history rows on http(s) pages; only for the top hit of T3a, T5, or T7.
  `fieldText` is the typed lead (`https://`, `http://`, `www.` as typed) plus the row's host
  (with a non-default port) when the text has no `/`, `?`, or `#`, else its URL without scheme,
  `www.`, fragment, or a root `/`; it must start with the typed text (folded) and be longer.
  UTF-16 `[typedLength, end)` is the completed part.
- A new `query` call cancels the previous stream.
  Cancel also stops its pending network request.
  `cancel()` stops the running query when the command bar closes.

Each `Suggestion` has:

| Field | Use |
|---|---|
| `id` | Stable across snapshots of one query. The UI can diff rows and keep the selection. |
| `kind` | `navigate`, `search`, `switchToTab`, `history`, `searchSuggestion`, `calculator`, `action`, `siteSearch`, or `siteSearchHint`. |
| `title`, `subtitle` | Text for the row. |
| `url` | Page to open. Nil for `calculator`, `action`, and `siteSearchHint` rows. |
| `actionID` | Browser command for `action` rows. The app runs the handler. |
| `icon` | `favicon(URL)`, `symbol(String)`, or `emoji(String)`. Nil means no icon hint. |
| `tabID`, `tabLocation` | Target tab and its place (`today`, `pinned`, `favorite`, `splitPane`) for `switchToTab` rows. |
| `spaceID`, `spaceTitle` | Space that holds the target tab. Nil for favorites. For a "Focus on \<Space\>" action, the target Space. |
| `siteSearchID` | Site for `siteSearch` and `siteSearchHint` rows. |
| `providers` | Providers that made this row. More than one after a merge, for example `tabs` + `history`. |
| `score`, `scoreDetail` | Final score and its parts (quality, weight, frecency, boost). |

The app acts on the top hit or the selected row:

- `navigate`, `search`, `history`, `siteSearch`, `searchSuggestion`: open `url`.
  In `newTab` mode, open it in a new Today tab.
  In `editCurrentURL` mode, navigate the current tab.
- `switchToTab`: select `tabID`. Switch to `spaceID` first when it names another Space.
- `calculator`: copy the answer. The title is the answer.
- `action`: run the handler for `actionID`. OpenSuggest has no handlers.
- `siteSearchHint`: enter Site Search for `siteSearchID`.
  Keep the typed text as the query. Show the site as a pill in the input.

## Modes

| Mode | Providers that run | Top hit |
|---|---|---|
| `newTab` | All. The current tab is offered like any open tab (F0043, F0063: the page behind the bar is a Switch to Tab row). | Rules T1-T8. |
| `editCurrentURL` | All. The current tab is not offered as Switch to Tab. The typed URL row never merges into a tab row. | Rules T1-T8. |
| `searchTabs` | Tabs only. History and remote do not run. | Best tab (T2). Empty query gives no top hit. |
| `searchActions` | Actions only (commandbar-completion §4.3.3). Any text, no 2-character minimum. The empty query lists the available actions in registry seed order (up to 12). Equal matches: the title the query covers more of first (Open rule; Arc ranks by recent use). | Best action (T2a). Empty query gives no top hit. |

Results respect the current Profile.
Open tabs come from every Space of that Profile, not only the current Space.
History comes from that Profile's database (one `HistoryStore` per Profile).
Remote suggestions use that Profile's search engine.

An empty query (not a scope, not Site Search) gives Arc's empty Cmd+T: up to four open tabs, then the
"Contact the Team" action, and no top hit. History does not run for it (S2 18/0008, 18/0014, 18/0040–0046 AX;
F0063; Section 2 item 9).
The UI shows it as a list, not as a default action.

## Providers

Each provider conforms to `SuggestProvider`.
Local providers run synchronously on the main actor and must stay fast.
Async providers return an operation. The engine runs operations in a task group
and cancels them on the next keystroke.

| # | Provider id | Kinds | Sync or async |
|---|---|---|---|
| 1 | `typed` | `navigate`, `search` | Sync |
| 2 | `tabs` | `switchToTab` | Sync |
| 3 | `history` | `history` | Async (`HistoryStore.search`) |
| 4 | `remote` | `searchSuggestion`, `navigate` | Async (network) |
| 5 | `calculator` | `calculator` | Sync |
| 6 | `actions` | `action` | Sync |
| 7 | `site-search` | `siteSearch`, `siteSearchHint` | Sync |

Provider order in this table is the order rows enter ranking.
Ranking decides the final order. Provider order does not decide it.

### 1. What you typed

`InputClassifier` reads the trimmed text once per keystroke.
It gives `empty`, `url(URL, URLReason)`, or `text(String)`.

URL rules, in order:

1. Explicit scheme: `https://`, `http://`, `file://`, `ftp://`,
   or a known scheme (`about`, `chrome`, `chrome-extension`, `view-source`, `mailto`),
   or any `scheme://` form. Spaces in the host reject it. Spaces in the path are encoded.
2. `javascript:` never navigates. It becomes search text.
3. File paths: text that starts with `/` (not `//`), is `~`, or starts with `~/`.
   `~` expands to the home folder.
4. The authority is the text before the first `/`, `?`, or `#`.
   Whitespace in the authority, or `@` in the authority, makes it search text.
   So `what is github.com` and `name@example.com` are searches.
5. `localhost` and `*.localhost` navigate with `http`.
6. IPv4 dotted quads (each part 0-255, no leading zeros except `0` itself)
   and bracketed IPv6 (checked with `inet_pton`) navigate with `http`.
7. Host syntax must hold: labels of 1-63 bytes, host at most 253 bytes,
   no label starts or ends with `-`, and at least one letter exists.
8. One label with a port (`myserver:8080`) or with a path (`intranet/`) navigates with `http`.
9. Last label in `local`, `localhost`, `test`, or `internal` navigates with `http`.
10. A host that the Public Suffix List calls registrable navigates with `https`.
    See the next section.
11. Any other host with an explicit port navigates with `http`.
12. All else is search text.

A port must be digits, at most 5 of them, and at most 65535.
Text after the authority (`/path?query#fragment`) is kept.
Characters that are not valid there are percent-encoded. Existing escapes stay.

Rows:

- URL input gives a `navigate` row. Its score part is quality 100, weight 1.0.
  For bare hosts, IPs, and file paths, a `search` row follows as the second row.
  The user may have meant words. Explicit schemes and file paths get no second row.
- Text input gives one `search` row for the context search engine.
  Its subtitle is `Search <engine name>`.

### Public Suffix List

The package bundles `public_suffix_list.dat` as a resource, MPL-2.0 header intact.
Source: https://publicsuffix.org/list/public_suffix_list.dat
Version in this build: `2026-10-22_08-36-41_UTC`, commit `8437e5262f13305f94087abe699b4fe2be1d1de8`.
The file is 338,012 bytes. It holds 6,949 ICANN rules in the suggest-check run.

`PublicSuffixList.shared` loads lazily. Only the ICANN section is used,
as Chromium does for URL detection. Private suffixes like `github.io`
count as registrable sites, not as suffixes.

- Rules become three sorted arrays of 64-bit FNV-1a hashes (about 60 KB total).
  Exact rules hash the rule text. Wildcard rules (`*.ck`) hash `ck`.
  Exception rules (`!www.ck`) hash `www.ck`.
- A lookup hashes each host suffix and binary-searches the arrays.
  It allocates nothing. An exception wins. Else the longest matching rule wins.

`isRegistrableHost(host)` is true when:

- The longest matching suffix (exception, then wildcard, then exact) leaves at least one label in front.
  An exception suffix drops its first label, so `www.ck` has suffix `ck` under `!www.ck`.
- So `github.com` and `gist.github.com` are registrable. `com` and `co.uk` alone are not.
- `example.invalid` and `example.example` are not. They become searches.

To update the list: download the new file from the URL above, replace the resource,
and keep its MPL-2.0 header. No code change is needed.

### 2. Open tabs, pinned tabs, favorites

Source: the live `BrowserModel`, current Profile, all its Spaces.

- Pinned and Today items include tabs inside folders and Split panes.
- Favorites come from the Profile. They have no Space.
- Each tab row carries its Space (`spaceID`, `spaceTitle`) and location.
- A Split View is one row (commandbar-completion §4.2, Arc CC-12): the index records each pane's
  split (`TabIndex.splits`, pane slots in pane order, orientation). Pane matches fold into one candidate
  per split: the best pane's quality and entry, the most recent pane's recency, the `.splitPane` and
  current-Space boosts. The row is `id = "split:<splitID>"`, kind `switchToTab`, `tabID` and `url` of the
  best-matching pane (empty query: the focused pane), `title` the pane titles joined with " | ", and
  `split: SplitRowInfo` (pane tab ids, titles, icons, URLs, `isVertical`). Any pane can make it exact (T5)
  or eligible (T7). Edit mode leaves out a split that holds the current tab. A history or typed row whose
  URL equals any pane's URL folds into the split row; a separate open tab with that URL stays its own row.

The engine keeps a `TabIndex` so a keystroke never walks the live model:

- The index builds once from the model (13.89 ms for 5,000 tabs in the check run,
  under 3 ms for a rebuild after a change; see Performance).
- The index holds flat arrays: folded title, host, and URL bytes for each tab,
  one bloom mask per tab, Space and Profile data, and last-active times.
- Between keystrokes the index is cached. A query with no model change pays no rebuild.
- A title or URL change patches one tab and re-folds only it.
- A structural change (new tab, move, pin) rebuilds the entry list
  and re-folds only new or changed tabs.
- `SuggestEngine.lastIndexBuildMilliseconds`, `indexBuildCount`, and
  `lastIndexFoldedCount` expose this for diagnostics.

Match: quality is the best of title (factor 1), host (factor 1), and URL (factor 0.9).
Tabs and history match the text without a typed `https://`, `http://`, then `www.`
(`SuggestInput.matchQuery`), so "https://goo" still finds google.com and can complete.
The scan first checks a 64-bit bloom mask of the query bytes.
A tab whose mask lacks a query byte cannot match, so most tabs cost one integer test.
Empty query: every tab of the Profile matches with quality 0, and recency decides.
At most 12 rows enter ranking (4 for an empty query outside search-tabs mode).

### 3. History

Source: `HistoryStore.search` for the context Profile. It is async and off the main actor.

- The store is SQLite with FTS5. It ranks by frecency and returns at most 24 matches.
  An empty query does not query history (Arc's empty Cmd+T lists no history).
- OpenSuggest re-scores each match with the same match quality as tabs,
  over title (1), host (1), and URL (0.9).
- If FTS matched but the local score is 0 (the token reads differ),
  quality becomes 20 so the row still shows.
- Only `http`, `https`, and `file` pages become rows.
- In Site Search scope, only pages of that site stay.
- Carry-over: when the text extends the previous query (same Profile), snapshot 0 already
  holds that query's history pages whose host or URL still matches, re-scored for the new text.
  The history snapshot replaces them. Without it a history completion would vanish for a
  frame on every keystroke (commandbar-completion §4.1.3). Same rule as the remote carry-over.

### 4. Remote search suggestions

Source: the context search engine's suggest endpoint. Pluggable per engine
through `SuggestionFetcher`. The default fetcher uses `URLSession`.

- Debounce: the fetch starts 80 ms after the keystroke.
  A new keystroke cancels the pending fetch before it starts.
- Timeout: 300 ms for the request. A slow server gives no remote rows.
  The stream still ends. There is no retry.
- Cache: the last result per (engine, query) is kept.
  A repeated query is served in snapshot 0, with no request.
- Carry-over: rows from the previous query that still match the new text
  appear in snapshot 0, marked as remote rows. Fresh rows replace them.
- No request runs when: suggestions are off or offline, the mode is search-tabs,
  the query is empty or over 200 characters, the input is a URL,
  the input equals the current tab URL, or the input is arithmetic.
  The session is ephemeral: no cookies, no cache, no credentials.
- In Site Search scope, suggestions run only when the site is a search engine
  (`engineID` set). Other sites send nothing. Scoped rows use the site's search URL.
- The typed search row stays the top hit. Remote rows never take the top hit.
  See rule T7/T8 and the `searchSuggestion` weight.

Response parsing (`SuggestResponseParser`):

- OpenSearch JSON: `["query", ["s1", "s2", ...], ...]`. Element 1 holds the texts.
- Google `client=chrome` JSON: the same shape, plus element 4
  (`google:suggesttype`). A `NAVIGATION` entry becomes a `navigate` row
  with the title from element 2. A `CALCULATOR` entry is dropped,
  because the local calculator answers arithmetic.
- Unknown shapes give an empty list. Nothing throws to the UI.

### 5. Calculator

`Calculator.evaluate` parses arithmetic. It never uses `NSExpression` on raw input.

Grammar (from `Calculator.swift`):

```
expr    := term (("+" | "-") term)*          // "x + y%" means x + x*y/100
term    := unary (("*" | "/" | "%") unary)*  // infix "%" is modulo
unary   := ("-" | "+") unary | power         // so -2^2 = -4
power   := postfix ("^" unary)?              // right-associative
postfix := primary ("%")*                    // "%" before an operator, ")" or the end is percent
primary := number | "(" expr ")"
number  := digits with at most one ".", like 3.14, .5, 5.
```

Operators also include `−` (U+2212), `·`, and `**` for power.
Input is at most 256 characters. Nesting is at most 64 deep.
The input must hold at least one binary operator.

- Operators: `+`, `-`, `*`, `×`, `/`, `÷`, `^` (power), `%`.
  `%` at the end of a term is percent: `200*15%` = 30, and after `+` or `-`
  it is a percent of the left side: `100+10%` = 110.
  `%` between two numbers is modulo: `10 % 3` = 1.
- Division or modulo by zero gives no row. So do overflow, `NaN`, and infinity.
- A lone number is not a calculation and gives no row.
- Text with letters gives no row. Only digits, `.`, the operators above,
  parentheses, and spaces may appear.
- The row title is the answer. Whole answers print without a decimal part.
  Other answers print with up to 12 significant digits (`%.12g`).
- Examples that give rows: `2+2*3` = 8, `2^10` = 1024, `2**10` = 1024,
  `-2^2` = -4, `200*15%` = 30, `100+10%` = 110, `10 % 3` = 1, `.5*4` = 2.
- Examples that give no row: `42`, `-5`, `50%` (no binary operator),
  `2+`, `1/0`, `hello`.

### 6. Actions

`ActionRegistry` is injectable. The app supplies handlers later by `actionID`.
OpenSuggest only surfaces matching rows.

Each `BrowserAction` has: `id`, `title`, `aliases`, `shortcut` (display text),
`symbol` (SF Symbol name), and `requirement`.

Seed set (from `docs/re/menus-and-hotkeys.md`, Arc 1.170.0).
Only commands that make sense in a command bar are seeded.

Seed ids, grouped as in `ActionRegistry.arcDefaults` (79 actions, plus the dynamic `focus-space`):

- Tabs and windows: `new-tab` (⌘T), `new-window` (⌘N), `new-incognito-window` (⇧⌘N),
  `new-little-open-window` (⌥⌘N), `archive-tab` (⌘W, current tab), `restore-last-closed-tab` (⇧⌘T),
  `duplicate-tab`, `rename-tab`, `pin-tab` (⌘D, Today tab), `unpin-tab` (⌘D, pinned tab),
  `add-to-favorites`, `remove-from-favorites`, `reset-tab`, `replace-pinned-url`,
  `copy-url` (⇧⌘C), `copy-url-markdown` (⌥⇧⌘C), `copy-url-quote` (⌃⇧⌘C),
  `clear-unpinned-tabs` (⇧⌘K), `new-folder` (⇧⌘N), `expand-all-folders`, `collapse-all-folders`,
  `mute-all-tabs`, `unmute-all-tabs`, `next-tab` (⌥⌘↓), `previous-tab` (⌥⌘↑),
  `reveal-tab-in-sidebar` (⌃Space).
- Split View: `add-split-view` (⌃⇧=, current tab), `close-split-pane` (⌃⇧-),
  `separate-from-split-view`, `expand-current-split` (last three need a tab in a Split).
- View: `toggle-sidebar` (⌘S), `toggle-toolbar` (⇧⌘D), `toggle-full-screen` (⌃⌘F),
  `reload` (⌘R), `force-reload` (⇧⌘R), `clear-cache-and-refresh`, `clear-cookies-and-refresh`,
  `zoom-in` (⌘+), `zoom-out` (⌘-), `zoom-actual-size` (⌘0), `find` (⌘F), `print` (⌘P),
  `save-page-as` (⇧⌘S), `go-back` (⌘[), `go-forward` (⌘]),
  `developer-tools` (⌥⌘I), `view-source` (⌥⌘U), `javascript-console` (⌥⌘J),
  `appearance-dark`, `appearance-light`, `appearance-automatic`.
  Page actions in this group need a current tab, except the appearance actions.
- Spaces: `new-space`, `next-space` (⌥⌘→, 2+ Spaces), `previous-space` (⌥⌘←, 2+ Spaces),
  `manage-spaces`, `rename-space`, `edit-theme`, `change-profile`, `reset-all-tabs-in-space`,
  `expand-pinned-section`, `collapse-pinned-section`, and dynamic `focus-space` (2+ Spaces).
- Library and windows: `view-archive`, `clear-archive`, `view-history` (⌘Y),
  `view-downloads` (⇧⌘J), `view-library` (⇧⌘L).
- Settings and features: `settings` (⌘,), `search-settings`, `air-traffic-control`,
  `manage-passwords`, `manage-extensions`, `add-extension`, `new-profile`,
  `new-boost` (current tab), `boost-gallery`, `task-manager`, `set-default-browser`,
  `import-from-browser`, `keyboard-shortcuts`.

Left out on purpose: Easels, Notes, Arc Max, Dia, account items, and Capture.
Full titles, aliases, symbols, and requirements are in `ActionRegistry.swift`.
Both "little open" and the old-name alias "little arc" find
`new-little-open-window`, displayed as "New Little Open Window".

Rules:

- The query needs at least 2 bytes. Matching reads the title, aliases,
  and the initials of the title words (`ts` → Toggle Sidebar, quality 50).
- Actions whose requirement fails are hidden, not disabled.
  For example, a Today tab shows Pin Tab. A pinned tab shows Unpin Tab.
- "Focus on \<Space\>" rows are built from the model's Spaces of this Profile.
- At most 3 action rows enter ranking.

### 7. Site Search

Scope keywords (commandbar-completion §4.3.2): two built-in trigger entries, `scope-actions` ("actions", "action", "commands") and `scope-tabs` ("tabs", "tab"), with no URL template. They match exact words only, never a prefix and never as a Space trigger, and a scope wins over a site with the same word. `siteSearchTrigger(for:)` returns them; the command bar maps them to its scopes.

Typing a known site name or keyword, then Tab, scopes the query to that site.
This matches Arc §4.6 rule 15.

Seed sites (`SiteSearches.popular`, 23 entries):
YouTube (`yt`), GitHub (`gh`), Wikipedia (`wiki`), Amazon (`amz`), Reddit,
X (`twitter`), Google Maps (`maps`, `gmaps`), Google Images (`images`), Google News,
Google Drive (`drive`, `gdrive`), Gmail, Google Translate (`translate`),
Stack Overflow, MDN, Apple Developer, npm, Hacker News (`hn`), IMDb, Spotify,
LinkedIn, Pinterest, Twitch, eBay.
Every search engine is added too, with id `engine-<engine id>`
(so `ddg` + Tab searches with DuckDuckGo).
Templates are the sites' public search URLs, written for Open.

Each `SiteSearch` has: `id`, `name`, `host`, `keywords`, `searchURLTemplate`
(`%s` is the percent-encoded query), and `engineID` when it is an engine.

Three ways a site row appears:

1. Space trigger: the first word equals a name, host, or keyword,
   and more text follows. `yt cats` gives a `siteSearch` row that opens
   `https://www.youtube.com/results?search_query=cats`.
2. Tab hint: a one-word query of 2+ bytes that equals or starts a name, host,
   or keyword gives a `siteSearchHint` row ("Press Tab to search YouTube").
   It has no URL. Tab (or Return on the hint) enters Site Search.
   `SuggestEngine.siteSearchTrigger(for:)` gives the same site for the Tab key.
3. Scoped mode: `context.siteSearchID` is set.
   The typed row becomes the site's search URL for the query text.
   Tab and history rows stay only when the page belongs to the site:
   same host or a subdomain; for a host/path scope like `google.com/maps`,
   the URL without scheme and `www.` starts with the scope.
   Backspace on an empty query exits the scope. The UI owns that key.

## Search engines

`SearchEngines.all`. Google is the default (Arc §4.5 rule 11).
Templates were checked by hand with `curl` on 2026-10-24.

| id | Name | Search URL template | Suggest URL template |
|---|---|---|---|
| `google` | Google | `https://www.google.com/search?q=%s` | `https://www.google.com/complete/search?client=chrome&ie=UTF-8&oe=UTF-8&q=%s` |
| `duckduckgo` | DuckDuckGo | `https://duckduckgo.com/?q=%s` | `https://duckduckgo.com/ac/?q=%s&type=list` |
| `bing` | Bing | `https://www.bing.com/search?q=%s` | `https://www.bing.com/osjson.aspx?query=%s` |
| `brave` | Brave Search | `https://search.brave.com/search?q=%s` | `https://search.brave.com/api/suggest?q=%s` |
| `ecosia` | Ecosia | `https://www.ecosia.org/search?q=%s` | `https://ac.ecosia.org/autocomplete?q=%s&type=list` |
| `kagi` | Kagi | `https://kagi.com/search?q=%s` | `https://kagi.com/api/autosuggest?q=%s` |
| `perplexity` | Perplexity | `https://www.perplexity.ai/search/new?q=%s` | none |
| `yahoo` | Yahoo | `https://search.yahoo.com/search?p=%s` | `https://search.yahoo.com/sugg/ff?output=fxjson&appid=ffd&command=%s` |

- `%s` is replaced by the query encoded with RFC 3986 unreserved characters only.
  So `c++ & rust` becomes `c%2B%2B%20%26%20rust`. `&` and `+` stay data, not syntax.
- Google suggest uses the `client=chrome` shape. Other engines use OpenSearch JSON.
- Perplexity has no suggest endpoint in this build. Remote rows never appear for it.
  Kagi suggest may need an account. A failed fetch gives no remote rows.
- Custom engines: pass a longer `searchEngines` list to `SuggestEngine`.
  `SearchEngines.engine(id:in:)` falls back to Google for an unknown id.

## Ranking

Deterministic. No ML. Every rule is in this section.

### Folding

All matching folds text first: lowercase, diacritic-insensitive, width-insensitive.
ASCII takes a fast path. `cafe menu` and `CAFÉ` both match `Café Menu`.
The query folds once per keystroke (`FoldedQuery`) and is shared by all providers.

### Match quality

Quality is 0-100. It is the best value over the row's fields.

| Match | Quality |
|---|---|
| Field equals the query | 100 (`exact`) |
| Field starts with the query | 80 (`prefix`) |
| Query occurs at a word start in the field | 60 (`wordPrefix`) |
| Every query word starts a word somewhere in the row | 50 (`allWordsPrefix`) |
| Action initials equal the query | 50 (`initials`, actions only) |
| Query occurs inside a word, query has 3+ bytes | 40 (`substring`) |
| Every query word occurs somewhere in the row | 30 (`allWordsSubstring`) |
| No match | 0 |

Field factors: title 1.0, host 1.0, URL 0.9.
A one-word query tries the whole field first, then the per-word rules.
A multi-word query that fails as a whole tries the two `allWords` rules.
Substring matches under 3 bytes do not count.
Short queries match only at word starts. This keeps `gi` from matching `digit`.

### Score

```
score = quality × weight + frecency + boost
```

Weights by kind:

| Kind | Weight |
|---|---|
| `switchToTab` | 1.00 |
| `navigate` | 1.00 |
| `calculator` | 1.00 |
| `history` | 0.90 |
| `action` | 0.85 |
| `siteSearch` | 0.80 |
| `siteSearchHint` | 0.60 |
| `search` | 0.50 |
| `searchSuggestion` | 0.45 |

Frecency:

- History: `min(30, 8 × ln(1 + (visits + 3 × typed) / (1 + 0.15 × ageDays)))`.
  This is the same shape as `HistoryStore` (visit count + 3 × typed count, decayed by age).
- Tab recency: `max(0, 6 − ln(1 + ageHours))`, from `lastActiveAt`. Range 0-6.
- Remote rows: quality is fixed at 100 and the boost is `−0.5 × rank`.
  So the first remote row scores 45.0 and each next row scores 0.5 less.
  Server order is kept. Rows equal to the typed text are dropped.

Boosts:

- Open tab location: Today and Split pane +12. Pinned and favorite +10.
  For the same URL, an open tab beats pinned, and pinned beats history,
  because history gets no location boost and a 0.90 weight.
- Current Space: +3 for tabs in `context.spaceID`.
- Merged history: an open tab that absorbs a history row gains
  0.5 × that row's frecency as boost.

### Order and caps

Rows sort by score, then kind priority, then title, then id. The order is total.
Kind priority for ties: `switchToTab` > `navigate` > `calculator` > `history` >
`action` > `siteSearch` > `siteSearchHint` > `search` > `searchSuggestion`.

Caps after the top hit (per kind, per snapshot):

| Kind | Cap |
|---|---|
| `switchToTab` | 6 (no cap in search-tabs mode) |
| `history` | 6 |
| `searchSuggestion` | 5 |
| `navigate` | 3 |
| `action` | 3 |
| `siteSearch` | 2 |
| `siteSearchHint`, `calculator`, `search` | 1 each |

The snapshot holds at most `maxResults` rows (default 12), top hit included.

### Dedupe and merge

One row per normalized URL. The key drops:

- scheme (`http` and `https` are the same; other schemes keep theirs),
- a leading `www.` on the host,
- the default port (80 for http, 443 for https),
- trailing slashes on the path (the root path becomes empty),
- the fragment.

The query string stays. `/watch?v=1` and `/watch?v=2` are different rows.

When rows share a key, one survives. Precedence:
open tab (5) > what-you-typed (4) > history (3) > navigate or site search (2) > other (1).
Ties inside one precedence level go to the higher score.
The loser folds into the winner:

- `providers` lists both providers.
- A what-you-typed flag on the loser moves to the winner.
  So a typed search that equals an open tab's search page gives one Switch to Tab row.
- An open tab that absorbs history gains 0.5 × the history frecency (see Boosts).
- A typed `navigate` row that absorbs history takes the history title as its subtitle
  (`github.com` shows `GitHub`).

In edit mode, the typed URL row never absorbs a tab row. Both rows stay:
Return navigates the current tab; the tab row switches.

Second pass, for multi-page apps: rows for the hosts in Arc's
`dedupByTitleAndHostList` (`figma.com`, `maps.google.com`, `notion.so`,
`app.notion.com`, `zoom.us`, `opentable.com`, `zillow.com`, `github.com`,
`app.mode.com`, `console.cloud.google.com`) dedupe by (title, host) as well.
Only tab and history rows take part. The same merge precedence applies.

### Top hit

The top hit is what Return does with no selection change.
`topHitRule` names the rule. First match wins:

| Rule | Condition | Top hit |
|---|---|---|
| T0 | Empty query, or no rule below applies and no typed row exists | none |
| T1 | Site Search scope is active | the scoped `siteSearch` row |
| T2 | Search-tabs mode, query not empty | the best tab row |
| T2a | Search-actions mode, query not empty | the best action row |
| T3a | `allowsInlineCompletion`, no scope, new-tab or edit mode, text without whitespace, no calculator row, no exact tab title or host (T5) | the highest-ranked row that may be top hit (a tab also when only its URL matched, 2+ bytes typed: "localhost:30") and that the text completes; sets `inlineCompletion` |
| T3 | Input is a URL | the what-you-typed row (after merge, this may be the open tab that has that URL, in new-tab mode) |
| T4 | Input is arithmetic | the calculator row |
| T5 | A tab title or host equals the query | that tab |
| T6 | Query has 3+ bytes and equals an action title or alias | that action |
| T7 | The best row that may be top hit, by score | that row (see below) |
| T8 | A what-you-typed row exists | the typed search row, or the open tab it merged into |

T7 eligibility (`canBeTopHit`):

- Tab: quality at least prefix (80) and query at least 2 bytes.
- History: host or URL quality at least prefix (80),
  and typed count at least 1 or visit count at least 3.
- Action: quality at least prefix (80) and query at least 3 bytes.
- Calculator and scoped site search: always eligible (T1/T4 pick them first).
- Remote suggestions: never eligible. The typed search stays on top.

T5 and T7 also set `inlineCompletion` when their row completes the text ("Google" = a tab title completes to `google.com` in lower case, F0062). T1–T4, T6, and T8 never do.

If the picked rule finds no row, the top hit falls back to none (T0),
except T8, which is the normal path for plain text.

Worked examples (all from suggest-check):

- `gith` → history GitHub. T7: host prefix, typed 5 times.
- `localhost:3000` → navigate. T3.
- `googl` with an open tab on google.com and completion allowed → that tab, completion `google.com`. T3a.
- `google.com` (whole host) → navigate, no completion. T3 (F0061).
- `2+2*3` → calculator 8. T4.
- `split` → Add Split View. T6: alias `Split` equals the query, case-folded.
- Exact tab title `Design Review` → that tab. T5.
- `youtube.com/watch` → navigate. T3.
- `github.com` → navigate, merged with its history row. The subtitle is `GitHub`. T3.
- Plain text with no strong row → typed search. T8.

## Performance

Budget: the first snapshot in under 5 ms for a 5,000-item model
and a 100k-URL history, on Apple Silicon.

How the budget holds:

- Snapshot 0 never waits for history or the network. Both are async snapshots.
- The tab index is cached between keystrokes (see Provider 2).
  A keystroke scans flat byte arrays and bloom masks. It builds `Suggestion`
  values only for the best 12 tab rows.
- Folding is byte-based. The query folds once. Tab fields fold at index time.
- The Public Suffix List loads lazily into hash sets. `prewarm()` moves it
  and the first index build off the first keystroke.

Measured by `openkit suggest-check` (release build, this machine, 2026-10-25;
see Verification). Load average was about 9 on 18 cores during the run,
so treat the numbers as loaded-machine values, not clean-room values:

| Metric | p50 | p95 | max |
|---|---|---|---|
| First snapshot, wall (1,000 queries) | 0.258 ms | 0.570 ms | 1.011 ms |
| First snapshot, main-thread CPU | 0.247 ms | 0.535 ms | 0.911 ms |
| History snapshot, wall | 11.877 ms | 16.224 ms | 20.538 ms |
| First snapshot right after a model change (50 changes) | 2.293 ms | 3.265 ms | 3.628 ms |

The history snapshot is slower because `HistoryStore.search` scores every
FTS match in SQLite. It never blocks snapshot 0. The product budget for the
command bar (docs/architecture.md) is 50 ms from open to first results;
snapshot 0 is two orders of magnitude inside it.

Per query class (first snapshot wall, p50 / p95): word prefix 0.468 / 0.665 ms,
two words 0.328 / 0.589 ms, host prefix 0.373 / 0.583 ms, URL-like 0.138 / 0.267 ms,
arithmetic 0.110 / 0.229 ms, action words 0.335 / 0.531 ms.

Index costs in the same run: first build of 5,000 tabs 13.89 ms;
rebuild after a structural change at most 2.99 ms, re-folding at most 1 tab.

Inline completion (suggest-check row 43, 2026-11-02, load average 10): the first snapshot with
`allowsInlineCompletion` costs main-thread CPU p50 0.156 ms, p95 0.446 ms (plain p95 0.511 ms over the
same queries; 115 of 1,000 snapshots completed). The completion check itself (T3a plus `inlineCompletion`
over the snapshot rows) is p50 0.0027 ms, p95 0.0116 ms, against a 0.05 ms budget.

## CLI

```text
openkit suggest --snapshot DIR [--history DB|DIR] [--offline]
                [--mode new-tab|edit|tabs] [--current-url URL]
                [--site SITE_ID] [--engine ID]
                [--show-titles] [--redact-hosts] "query"
openkit suggest-check
```

- `--snapshot DIR` loads `DIR/State/browser.json` (a SnapshotStore root,
  for example the `--out` folder of `openkit import-arc`).
- `--history` takes a HistoryStore root or its `State/history.sqlite3` file.
  With no `--history`, no history provider runs.
- `--offline` turns off remote suggestions.
- Output prints one block per snapshot: sequence, elapsed ms, final flag,
  input reading, top-hit rule, per-provider ms, then ranked rows
  (`*` marks the top hit). Each row shows kind, score, the score parts
  (`q<quality>×<weight>+f<frecency>+b<boost>`), and its target.
- Titles of tab and history rows, and URL paths, are hidden by default (`•••`).
  Hosts stay, because the host is the useful part of a result.
  `--show-titles` prints full titles and URLs. Never paste that output into docs.
  `--redact-hosts` replaces each host with `host-N`, stable within one run.

`suggest-check` builds a synthetic model and a 100k-URL history database,
runs the fixed scenarios below through the real engine, and measures
1,000 random queries. It prints PASS/FAIL per scenario and exits non-zero
on any failure. It needs no network: remote scenarios use a local stub fetcher.

## Verification

Build (2026-10-25): `swift build -c release` in `Packages/OpenKit` —
zero warnings, zero errors (Swift 6.4, strict concurrency).

### suggest-check

47/47 passed (2026-11-02, commandbar-completion Step 5, load average 10–12 on 18 cores). The table is the real output shape. Rows 34–46 are the plan's scenarios 32–43 and 44 (§5.1).

| # | Result | Scenario |
|---|---|---|
| 1 | PASS | "gith" → GitHub history is the top hit |
| 2 | PASS | "localhost:3000" → navigate |
| 3 | PASS | "2+2*3" → calculator 8 |
| 4 | PASS | "split" → Split View action is the top hit |
| 5 | PASS | exact tab title → Switch to Tab (with Space) |
| 6 | PASS | "youtube.com/watch" → navigate |
| 7 | PASS | open tab + history (http/www/#/slash variants) → one Switch to Tab row |
| 8 | PASS | empty query → no crash, no top hit, recent tabs + top history |
| 9 | PASS | whitespace query in search-tabs mode → tabs by recency, no top hit |
| 10 | PASS | what-you-typed table (20 inputs: schemes, hosts, PSL, IPs, ports, paths, searches) |
| 11 | PASS | calculator table (15 inputs: precedence, unicode ops, percent, modulo, errors) |
| 12 | PASS | "github.com" → navigate, merged with its history row |
| 13 | PASS | search URL encodes + & and spaces |
| 14 | PASS | engine choice: DuckDuckGo search URL |
| 15 | PASS | typed search equal to an open tab's search page → that tab is the top hit (no duplicate) |
| 16 | PASS | case- and diacritic-insensitive ("cafe menu", "CAFÉ" → Café Menu) |
| 17 | PASS | tabs of another Profile never appear |
| 18 | PASS | search-tabs mode → only tab rows, best tab on top |
| 19 | PASS | edit mode: current URL → navigate it; the current tab is not offered |
| 20 | PASS | actions hide when they do not apply (Pin vs Unpin) |
| 21 | PASS | Search alias "clear today" → Clear Unpinned Tabs |
| 22 | PASS | "personal" → Focus on Personal (dynamic Space action) |
| 23 | PASS | Site Search: "yt cats" row, "you" Tab hint, scoped query, Tab target |
| 24 | PASS | tab index: cached between keystrokes; title/URL change patches 1 tab; new tab rebuilds, re-folding only it |
| 25 | PASS | tidy Gmail matches raw title, displays Inbox, and patches raw/custom title changes |
| 26 | PASS | remote: suggestions merge in a later snapshot; top hit stays the typed search |
| 27 | PASS | remote: repeated query is served from cache in snapshot 0 (no request) |
| 28 | PASS | remote: next keystroke carries over still-matching rows in snapshot 0 |
| 29 | PASS | remote: local test servers use distinct ephemeral ports |
| 30 | PASS | remote: 300 ms timeout (server takes 800 ms) → stream ends without remote rows |
| 31 | PASS | remote: real-time slow-server stream ends within 600 ms (debounce 80 + timeout 300) |
| 32 | PASS | remote: each keystroke cancels the previous request (debounce) |
| 33 | PASS | remote: nothing sent when off, for URLs, for the current URL, for arithmetic |
| 34 | PASS | 32: "googl" + tab on google.com → T3a, completion "google.com" (typed 5), row 1 |
| 35 | PASS | 33: "googl" with completion off → no completion, top hit by T7 |
| 36 | PASS | 34: "Google" = tab title → T5, completion "google.com" in lower case (typed 6) |
| 37 | PASS | 35: "google.co" → T3a "google.com" (typed 9); completion off → T3 typed URL, none |
| 38 | PASS | 36: whole host "google.com" → T3, no completion (F0061) |
| 39 | PASS | 37: path → full URL, host-only otherwise, whole host none, port kept, scheme and www. kept as typed |
| 40 | PASS | 38: no completion for arithmetic, whitespace, scopes, search tabs, non-web URLs, typed URL or search rows; field text ≤ 2,048 (at the cap yes, one over no) |
| 41 | PASS | 39: current tab offered in new-tab mode (also for an empty query), absent in edit mode |
| 42 | PASS | 40: "gi" → "git": snapshot 0 carries the history row over and already completes "github.com" |
| 43 | PASS | 41: split → one row (either pane matches, targets it); exact pane title → T5; pane history folds in; empty query → focused pane; edit mode leaves out the current split |
| 44 | PASS | 42: Actions scope: empty → available actions in seed order, no top hit; "side" → Show/Hide Sidebar (T2a); requirements still hide; only action rows |
| 45 | PASS | 43: scope keywords: "actions"/"action"/"commands" and "tabs"/"tab" give scope hints; "act" and "tab vs" do not; a site keyword keeps its hint |
| 46 | PASS | 44: first snapshot with inline completion p95 < 5 ms CPU (5,000 tabs incl. 500 two-pane splits); completion check p95 ≤ 0.05 ms |
| 47 | PASS | first snapshot p95 < 5 ms main-thread CPU (1,000 random queries, 5,000 tabs, 100k history) |

Rows 26–33 use a local stub fetcher, so no network runs in the check.

### Real Arc snapshot

Files were copied to a temp folder first, because Arc may be running.
Only `StorableSidebar.json`, `StorableWindows.json`, and
`StorableLinkRouting.json` were copied. The importer never writes to the Arc folder.

```text
openkit import-arc --arc-dir <temp copy> --out <tmp>
import report:
  totalItems=46 accounted=37 spaces=4
  pinnedTabs=27 todayTabs=0 favorites=6
  folders=1 splits=1 routingRules=1
  containers(structural)=9 check imported+skipped+containers=46 total=46
```

Redacted `openkit suggest` runs against that snapshot (`--offline --redact-hosts`).
Titles and paths are `•••`. Hosts are `host-N`.

```text
# Two queries for site names that match pinned tabs in the real data
# (omitted: they would reveal which sites the user pins). Both returned
# one "Switch to Tab" top hit (rules T5 exact tab and T7 best eligible)
# in under 0.2 ms, plus a Site Search hint and a Google search row.

query "localhost:3000" mode=newTab remote=false
snapshot 0  0.11 ms  final=yes  input=url(localhost)  top=T3-typed-url
   1* navigate  100.0  http://localhost:3000/  → http://localhost:3000/

query "2+2*3" mode=newTab remote=false
snapshot 0  0.12 ms  final=yes  input=text  top=T4-calculator
   1* calculator  100.0  8 — 2+2*3 =  → -
```

Online run (remote on, no history database in the snapshot folder):

```text
query "swift language" mode=newTab remote=true
snapshot 0  0.13 ms  final=no  top=T8-typed-search pending=[remote]
   1* search   50.0  swift language — Search Google
snapshot 1  178.09 ms  final=yes  top=T8-typed-search
   1* search   50.0  swift language — Search Google
   2  searchSuggestion   45.0  swift language tutorial — Search Google
   3  searchSuggestion   44.5  swift language training academy — Search Google
```

The remote rows arrive in a later snapshot and never take the top hit.
No `--show-titles` output is in this file.

## Open questions

1. Split caption: closed. One row per Split View (`Suggestion.split`); the UI shows "Switch to Split View"
   (commandbar-completion Steps 3–4).
2. History per Profile: the engine takes one resolver, `(ProfileID?) -> HistoryStore?`.
   The app must give it the Profile's database. The CLI gives one database for all Profiles.
3. Kagi suggest may need an account key. A failed fetch gives no rows, by design.
   A key store is an app concern.
4. Favicon cache: icon hints give the origin `/favicon.ico` URL.
   The app looks up its own favicon cache first and falls back to that URL.
5. `suggest-check` remote scenarios use a local stub. A live-engine smoke test
   (the `swift language` run above) is manual, not part of the check,
   because it needs the network.
