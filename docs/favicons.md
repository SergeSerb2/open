# Persistent favicons

`OpenStore` stores normalized icons for unloaded tabs, favorites, and imported tabs.
The App feeds engine favicon reports into `StoredFaviconCache`, which writes them to
`FaviconStore`. Sidebar rows and Favorites read its bounded decoded cache when no live
image is available. The Library already reads the same store for archived rows.

## API

```swift
let store = try FaviconStore(databaseURL: databaseURL)
try await store.ingest(imageData: bytes, iconURL: iconURL,
                       for: pageURL, pageSpecific: false)
let image = await store.icon(for: pageURL)
let needsFetch = await store.needsFetch(pageURL)
let fetched = await FaviconFetcher(store: store).fetchOne(pageURL)
```

`FaviconStore` is an actor. Its methods serialize SQLite access, decoding, and drawing
on the actor executor. Its synchronous initializer records the database URL only.
The first actor operation opens SQLite off the main actor.

- `icon(for:) -> FaviconImage?` returns an exact path match first, then the origin icon.
  It skips negative/error rows. Successful expired images remain available until replaced
  or purged, so a refresh does not blank a tab. `FaviconImage` is Sendable and contains
  `png32: Data`, `png64: Data?`, and `iconURL: URL?`.
- `ingest(imageData:iconURL:for:pageSpecific:) throws` decodes with ImageIO. It supports
  PNG, ICO, JPEG, GIF, WebP, and BMP. ICO uses the frame closest to 64 pixels by maximum
  dimension. Other raster formats use the first frame. Decoding downsamples to 64 pixels.
  Input is limited to 512 KiB even for direct engine ingestion. Before thumbnailing,
  ImageIO must report both dimensions in 1...1024 and depth in 1...8 bits
  (the selected ICO frame); at most 32 frames are allowed. Vector images are refused
  before AppKit rasterization. Invalid images throw
  `FaviconStoreError.invalidImage`; invalid page URLs and failed writes also throw.
- Rendering uses a high-interpolation sRGB CGContext with transparency. It fits the image
  inside a 32×32 or 64×64 square without changing its aspect ratio, then encodes PNGs.
  A successful write expires after seven days.
- `markMissing(for:)` writes an origin-level negative entry for 24 hours.
- `needsFetch(_:now:)` and internal status readback inspect only the origin row
  (`page_key = ''`), including negative/error rows. A page-specific image never suppresses
  origin prefetch. `icon(for:)` still prefers a page-specific image. Queries and fragments
  do not distinguish pages.
- `purge(olderThan:) -> Int` deletes rows with `fetched_at` strictly before the date and
  returns the number deleted. `count() -> Int` returns all rows, including negatives/errors.
- `statistics()` returns counts by status and the sum of both PNG payload lengths.

`FaviconFetcher` is an actor. Its initializer accepts a store, URLSession (default `.shared`),
`maxConcurrent` (default 6, minimum 1), and a per-request timeout (default and maximum 5 seconds).
Its in-flight registry is keyed by origin and shared by `prefetch` and `fetchOne`. Concurrent
calls on the same fetcher await one task, including its cache check. The first page supplied
for that origin wins. Cancellation of a waiter does not cancel the work shared by other callers.
`prefetch(_:)` returns a Sendable `FetchReport`: `requested`, `alreadyCached`, `fetched`,
`missing`, `failed`, `durationMs`, plus redacted per-origin results. `requested` counts
unique eligible origins; the other counts partition that number. Cached negative/error
rows count as `alreadyCached`, not as new missing/failed requests. `fetchOne(_:)` returns
true for a successful fresh origin row or a successful fetch, and false otherwise.

## Schema and keys

SQLiteDB enables NORMAL synchronous mode. This cache selects a truncated rollback
journal, with a 16 MiB database page cap and a 34 MiB combined transient disk cap
(see App integration below). The store sets a three-second
busy timeout and retains prepared statements for lookup, freshness, upsert, purge, count,
and statistics. Statements are reset and cleared after each use and finalized at teardown.

```sql
CREATE TABLE IF NOT EXISTS favicons(
  origin TEXT NOT NULL,
  page_key TEXT NOT NULL,
  icon_url TEXT,
  png32 BLOB,
  png64 BLOB,
  fetched_at REAL NOT NULL,
  expires_at REAL NOT NULL,
  status INTEGER NOT NULL,
  PRIMARY KEY(origin, page_key)
);
```

`origin` is the lowercase HTTP(S) scheme and host, with a port only when it is non-default.
Credentials, paths, queries, and fragments are excluded from this key. IPv6 brackets are
preserved through URLComponents. `page_key` is `""` for an origin icon, or the percent-encoded
URL path for a page icon; an empty page path becomes `/`. Dates are Unix seconds.
`status` is 0 for a successful icon, 1 for missing, and 2 for an error. Missing/error rows
have NULL image payloads. Network/server errors receive a 24-hour error cache. This avoids
repeatedly contacting an unreachable origin during bulk prefetch. Only `ingest` throws on
write failure; the nonthrowing maintenance methods return their documented empty result
on database failure. Fetching checks that its negative/error cache write actually landed.

## Fetch rules

1. Keep the first supplied page per canonical origin. Skip non-HTTP(S) URLs and fresh origin
   caches. A sliding TaskGroup window limits each prefetch call to six origins by default.
   Each origin has one eight-second monotonic deadline, starting before DNS classification,
   across the page, icon attempts, redirects, and fallback. Each request uses the smaller of
   five seconds (or its configured timeout) and the remaining budget.
2. GET the page with `Accept: text/html`, a Safari-like User-Agent, and cookie handling off.
   Consume at most 256 KiB, then cancel the underlying data task. Each request has both
   URLRequest's timeout and a wall-clock timeout race, including streamed bodies.
3. Scan the head with a case-insensitive byte scanner. Handle quoted/unquoted attributes,
   comments (including the HTML5 empty forms `<!-->` and `<!--->`), and
   script/style/title/textarea raw text. Stop at `</head>` or `<body>`. Decode attribute
   values with the response charset, or a `<meta charset>` / `http-equiv=content-type`
   declaration in the first 1024 bytes. Fall back to UTF-8, then Latin-1. Encode remaining
   non-ASCII URL characters as percent-encoded UTF-8 bytes.
   Accept `icon` (including `shortcut icon`), `apple-touch-icon`, and
   `apple-touch-icon-precomposed`. Ignore `mask-icon`.
4. Resolve hrefs against the final response URL, including relative paths after redirects.
   Decode common named and numeric HTML entities in hrefs. Permit HTTP(S) images and small
   `data:image/png;base64` images only (32 KiB decoded, at most 44 KiB encoded URL).
5. Try the smallest declared square/rectangular size whose two dimensions are at least 64,
   then the remaining sizes in ascending order. Next try Apple touch icons, then other
   icons, preserving document order for ties. Deduplicate after ranking and cap at 16.
   Reserve the final slot for `/favicon.ico`, so there are at most 15 declared candidates
   plus the fallback, and at most 16 total icon attempts.
6. Try `<original-origin>/favicon.ico` last. Downloads are limited to 512 KiB, including
   responses without Content-Length. A 404, invalid image, unsupported SVG, or oversized
   image advances to the next candidate. Store the first success as an origin-level icon.
7. Check the initial page, every network icon, and every redirect hop before connecting.
   A private destination is allowed only if the original page itself is private and the
   destination has the same canonical scheme, host, and port. `localhost`, `*.localhost`,
   IPv4 127/8, 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, 0/8, IPv6 ::1,
   fc00::/7, fe80::/10, and IPv4-mapped private IPv6 are private. Hostnames are resolved with
   `getaddrinfo` on a utility queue; any private result makes the host private. A resolver
   deadline discards late results. The per-task `URLSessionTaskDelegate` checks every
   redirect and cancels denied hops. Denial stops the origin fetch as `failed`, with the
   internal reason `blocked-private`; reports and logs contain no destination or reason.
8. If all candidates are missing/invalid, cache `missing`. If a transport error, timeout,
   or other HTTP error occurred and no icon succeeded, cache `failed`. Cancellation does
   not create a negative/error cache entry.

The limits apply to bytes consumed by the application; URLSession can buffer transport data.
Concurrency is bounded per prefetch invocation. Calls on one fetcher share in-flight
origins; distinct fetcher instances have independent registries.

## CLI

```sh
openkit favicons fetch --snapshot DIR --db PATH [--limit N]
openkit favicons get URL --db PATH --out FILE.png [--size 32|64]
openkit favicons stats --db PATH
openkit favicons bench --db PATH
```

`fetch` loads the real BrowserModel through SnapshotStore. It visits profile favorites,
pinned/today tabs, nested folders, split panes, and saved pinned URLs. `--limit` limits
unique HTTP(S) origins after deduplication, and accepts zero. It reports only `origin-N`,
status, and milliseconds. Status lines keep stable input order; cached lines show zero
request time. Network failures are report values; a completed fetch command exits zero.

`get` defaults to 32 pixels and exits 1 when absent. `stats` reports PNG payload bytes,
not SQLite file/WAL allocation. `bench` ingests 1,000 synthetic 64×64 images under a unique
`.invalid` origin, warms lookups, then measures 10,000 actor calls with a monotonic clock.
It does not contact the network. Use a scratch database for this command.
Malformed CLI arguments exit 2. Other command failures exit 1 with redacted error text.

### Hidden development diagnostics

These routes are for debugging with scratch databases and local fixtures. They are absent
from normal CLI help. Debug builds enable them. Release builds require the explicit
`OPENKIT_FAVICON_DEBUG=1` environment variable, including the store SPI override, so they
can be verified on the same optimized executable. Normal release use cannot enable the
override with a flag alone; the application does not enable this debugging mode.

```sh
OPENKIT_FAVICON_DEBUG=1 openkit favicons fetch --snapshot DIR --db PATH --treat-as-public 127.0.0.1
OPENKIT_FAVICON_DEBUG=1 openkit favicons fetch --snapshot DIR --db PATH --diagnostic-concurrent 2
OPENKIT_FAVICON_DEBUG=1 openkit favicons ingest http://localhost:18941/ --file IMAGE --db PATH [--page-specific true]
```

`--treat-as-public HOST` is a diagnostic override through `FaviconDiagnostics` SPI. For a
page with that host, only the original page origin and its same-origin requests are treated
as public. All other origins retain real classification, including a different port on
that same host. Thus the override can test a public-like `127.0.0.1:18941` page targeting
private `127.0.0.1:18942`; it cannot mark all loopback destinations public.
`--diagnostic-concurrent N` (2...16) starts N concurrent `prefetch` calls and one concurrent
`fetchOne` on the same fetcher, checks their outcomes, and prints one redacted report.
`ingest` passes bytes through the real engine-facing store API; invalid input exits 1 and
writes no row. `--page-specific` defaults to false and accepts true or false.

## Privacy

No third-party favicon service is used. Prefetch contacts the selected page origins and
allowed icon hosts declared by those pages (including allowed redirects). The snapshot is not sent
to a search/favicon provider. The CLI uses an ephemeral URLSession without cookie storage,
credential storage, or URL cache. An injected session follows its caller's configuration.

The database contains origin keys, optional page paths, and final icon URLs. Treat it as
private browsing data. The CLI does not print them, titles, paths from errors, or hosts.
Inline PNGs store no icon URL, to avoid copying the base64 payload into metadata.
The verification Arc JSON copies, imported snapshots, SQLite databases, source images,
and raw importer output stayed in a private temporary directory outside this repository.
No Arc bundle content was copied, Arc was not launched, and no desktop input was driven.
Only redacted counts and outputs appear below. No unit tests or mocks were added.

## Original verification — 2026-10-25 (America/Vancouver)

This section records the pre-review implementation. The review-fix verification below
records the current limits and policy; the older timings and outputs remain historical.

Host compiler: Apple Swift 6.4, arm64 macOS. Package deployment target: macOS 26+.
All flows used the real release `openkit` executable. Local HTTP fixtures and temporary
verification drivers were outside the repository and were stopped after use.

| Flow | Result | Evidence |
| --- | --- | --- |
| Release build | PASS | Final build exit 0; zero warnings/errors; 7.35 s |
| Real Arc JSON import | PASS | 15 JSON files copied read-only; 46 items, 4 spaces, 27 pinned tabs, 6 favorites, 1 folder, 1 split |
| Real snapshot prefetch | Completed | 27 origins: 23 fetched, 2 missing, 2 failed; failures remain explicit |
| Second process, same database | PASS | All 27 alreadyCached; prefetch 1.201 ms; process 21.334 ms (<50 ms) |
| Apple fetch and get | PASS | 64×64 PNG, 2,922 bytes; image viewer showed the Apple mark |
| Unreachable `.invalid` host | PASS | Expected failed=1, fetched=0; cached as status 2 |
| Local page with no icon | PASS | Expected missing=1; get prints absent and exits 1 |
| Local declared icon 404, valid favicon.ico | PASS | Expected fetched=1; fallback serves a real PNG-backed ICO |
| 1,000 ingests / 10,000 lookups | PASS | p50 0.016125 ms; p95 0.025917 ms (<0.2 ms) |
| Codec and scanner flows | PASS | PNG/ICO/JPEG/GIF/WebP/BMP/SVG; ranking, entities, redirect, inline, limits, invalid decode |
| All tab locations and concurrency | PASS | 10 distinct local origins; peak six active requests; limit 3 and empty limit 0 passed |
| SQLite / image output | PASS | integrity_check=ok; WAL; 604800/86400 s TTLs; 32×32 and 64×64 outputs; transparent synthetic corners |

### Build

The initial build completed in 41.01 s. After a small follow-up fix, the final source build
used the required low-priority command in Packages/OpenKit, in its own process session:

```text
$ nice -n 10 swift build -c release -j 6
Building for production...
[Using on-disk description]
[2 / 5] OpenStore
[3 / 6] OpenStore
[10 / 11] openkit-product
[11 / 11] openkit-product
Build complete! (7.35 secs.)
exit=0
```

### Real import and two prefetch processes (redacted)

Copied only `~/Library/Application Support/Arc/*.json` into a private temporary directory.
The source files were read only. Importer's full tree output was kept private because it
contains hosts. The commands used temporary paths:

```sh
openkit import-arc --arc-dir <temporary-arc-copy> --out <temporary-snapshot>
openkit favicons fetch --snapshot <temporary-snapshot> --db <temporary-db>
openkit favicons fetch --snapshot <temporary-snapshot> --db <temporary-db>
openkit favicons stats --db <temporary-db>
```

```text
import exit=0 processMs=136.620
  totalItems=46 accounted=37 spaces=4
  pinnedTabs=27 todayTabs=0 favorites=6
  folders=1 splits=1 routingRules=1
  skipped easels=0 notes=0 welcome=2 unknown=0
  orphans=0 skippedRoutingRules=0
  containers(structural)=9 check imported+skipped+containers=46 total=46

first fetch:
requested=27 alreadyCached=0 fetched=23 missing=2 failed=2 durationMs=10450.759
origin-1  missing  363.494 ms
origin-2  ok  423.361 ms
origin-3  ok  346.379 ms
origin-4  ok  931.925 ms
origin-5  ok  436.382 ms
origin-6  ok  184.261 ms
origin-7  missing  263.034 ms
origin-8  ok  474.972 ms
origin-9  ok  269.075 ms
origin-10  failed  144.546 ms
origin-11  failed  10013.494 ms
origin-12  ok  283.774 ms
origin-13  ok  121.700 ms
origin-14  ok  119.242 ms
origin-15  ok  208.660 ms
origin-16  ok  558.800 ms
origin-17  ok  1257.395 ms
origin-18  ok  353.430 ms
origin-19  ok  300.544 ms
origin-20  ok  626.518 ms
origin-21  ok  525.408 ms
origin-22  ok  712.600 ms
origin-23  ok  2246.702 ms
origin-24  ok  496.653 ms
origin-25  ok  385.145 ms
origin-26  ok  200.805 ms
origin-27  ok  438.248 ms
processMs=10486.966
exit=0

second fetch (new process):
requested=27 alreadyCached=27 fetched=0 missing=0 failed=0 durationMs=1.201
origin-1  missing  0.000 ms
origin-2  ok  0.000 ms
origin-3  ok  0.000 ms
origin-4  ok  0.000 ms
origin-5  ok  0.000 ms
origin-6  ok  0.000 ms
origin-7  missing  0.000 ms
origin-8  ok  0.000 ms
origin-9  ok  0.000 ms
origin-10  failed  0.000 ms
origin-11  failed  0.000 ms
origin-12  ok  0.000 ms
origin-13  ok  0.000 ms
origin-14  ok  0.000 ms
origin-15  ok  0.000 ms
origin-16  ok  0.000 ms
origin-17  ok  0.000 ms
origin-18  ok  0.000 ms
origin-19  ok  0.000 ms
origin-20  ok  0.000 ms
origin-21  ok  0.000 ms
origin-22  ok  0.000 ms
origin-23  ok  0.000 ms
origin-24  ok  0.000 ms
origin-25  ok  0.000 ms
origin-26  ok  0.000 ms
origin-27  ok  0.000 ms
processMs=21.334
exit=0

stats:
ok=23 missing=2 failed=2 count=27 totalBytes=124242
```

The imported split contained two panes. The live snapshot had zero Today tabs; the separate
local snapshot below verified Today tabs, Today folders, and Today splits. The two failed
external origins were preserved as errors, with no hostname disclosure or success claim.

### Public icon and failure cases

A one-tab synthetic snapshot fetched the user-requested public Apple URL. Then:

```sh
openkit favicons get https://www.apple.com --db <temporary-apple-db> --out /tmp/a.png --size 64
```

The image viewer showed a real Apple favicon (Apple mark in a circular light background).
The PNG was not committed.

```text
apple fetch:
requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=146.156
origin-1  ok  145.939 ms
processMs=170.425
exit=0
apple get:
ok bytes=2922
exit=0

unreachable host:
requested=1 alreadyCached=0 fetched=0 missing=0 failed=1 durationMs=20.851
origin-1  failed  20.628 ms
processMs=39.272
exit=0

local page with no icon:
requested=1 alreadyCached=0 fetched=0 missing=1 failed=0 durationMs=13.908
origin-1  missing  13.697 ms
exit=0
get: absent
get exit=1
repeat: requested=1 alreadyCached=1 fetched=0 missing=0 failed=0 durationMs=0.219
origin-1  missing  0.000 ms

local declared icon 404 with working /favicon.ico:
requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=22.527
origin-1  ok  22.050 ms
exit=0
origin lookup on another path: ok bytes=207
origin lookup exit=0
repeat: requested=1 alreadyCached=1 fetched=0 missing=0 failed=0 durationMs=0.188
origin-1  ok  0.000 ms
```

Both local required cases used `python3 -m http.server` bound to loopback from separate
temporary directories. The first directory contained only an `index.html` with no icon.
The second declared `/absent.png` (404) and contained a generated `/favicon.ico`.
Both servers were stopped. The unreachable request used `https://does-not-exist.invalid`.

### Performance

```text
$ openkit favicons bench --db <temporary-benchmark-db>
ingested=1000 lookups=10000 ingestMs=937.076 p50Ms=0.016125 p95Ms=0.025917 count=1000
exit=0
$ openkit favicons stats --db <temporary-benchmark-db>
ok=1000 missing=0 failed=0 count=1000 totalBytes=653048
```

The 1,000 source PNGs were generated at 64×64. Timings include actor hops and real prepared
SQLite reads, plus Data copying, and exclude image decoding by a UI consumer. The initial
warm-up was not included in percentiles. The machine was also running the engine build.

### Additional full CLI fixtures

A real loopback HTTP server supplied these fixtures to separate CLI processes/databases.
The request paths below are synthetic fixture names, not browsing data. The multi-frame
ICO had red 32 px, green 64 px, and blue 128 px frames; the retrieved PNG's center pixel
was green, which confirmed selection of the 64 px frame. All six raster formats and SVG
were decoded directly; none of those codec cases used the fallback icon.

```text
scanner: ok requests=['/scanner', '/pick.png?a=1&b=2'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=20.128
ranking: ok requests=['/ranking', '/absent', '/apple.png'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=18.890
redirect: ok requests=['/redirect', '/redirected/page.html', '/redirected/icon.png'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=25.186
inline: ok requests=['/inline'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=18.753
oversize: ok requests=['/oversize', '/huge', '/favicon.ico'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=20.896
streamoversize: ok requests=['/streamoversize', '/stream-huge', '/favicon.ico'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=26.161
headlimit: ok requests=['/headlimit', '/favicon.ico'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=28.236
decode: ok requests=['/decode', '/notimage', '/favicon.ico'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=21.820
format-png: ok requests=['/format/png', '/icon.png'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=17.384
format-jpeg: ok requests=['/format/jpeg', '/icon.jpeg'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=21.616
format-gif: ok requests=['/format/gif', '/icon.gif'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=22.250
format-webp: ok requests=['/format/webp', '/icon.webp'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=22.023
format-bmp: ok requests=['/format/bmp', '/icon.bmp'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=16.925
format-ico: ok requests=['/format/ico', '/icon.ico'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=22.026
format-svg: ok requests=['/format/svg', '/icon.svg'] | requested=1 alreadyCached=0 fetched=1 missing=0 failed=0 durationMs=102.040

all: peakConcurrentRequests=6 requests=20 | requested=10 alreadyCached=0 fetched=10 missing=0 failed=0 durationMs=238.743
limited: peakConcurrentRequests=3 requests=6 | requested=3 alreadyCached=0 fetched=3 missing=0 failed=0 durationMs=121.321
empty: peakConcurrentRequests=0 requests=0 | requested=0 alreadyCached=0 fetched=0 missing=0 failed=0 durationMs=0.035
```

The traversal snapshot included a favorite plus saved pinned URL, direct pinned/today tabs,
nested pinned/today folders, pinned/today split panes, and a duplicate favorite URL. Ten
loopback servers provided distinct origins. With delayed responses, the observed peak
was six simultaneous requests. The empty limit made no HTTP requests.

SQLite `PRAGMA integrity_check` returned `ok` for the real-import, Apple, unreachable,
missing, fallback, and benchmark databases. Their journal mode was `wal`; successful
TTLs were exactly 604800 seconds and negative/error TTLs exactly 86400 seconds.
All 1,000 benchmark rows and both retrieved fixture/public icons had the expected output
sizes; the synthetic 64 px output retained fully transparent corner pixels.

## Review-fix verification — 2026-10-25 (America/Vancouver)

The final source was built only with `nice -n 10 swift build -c release -j 6` in
`Packages/OpenKit`, with the build child in its own process session. Final build: exit 0,
9.77 s, no warnings/errors. All checks below used that real release `openkit`. No unit tests,
mocks, Arc launch, desktop input, or Chromium build/sync were used. Only the three favicon
Swift files and this document changed.

Two temporary Python `ThreadingHTTPServer` instances bound to 127.0.0.1:18941 and
127.0.0.1:18942. The second served a synthetic PNG at `/secret.png` and counted requests.
Each fixture used a real one-favorite BrowserModel snapshot, a fresh database (except the
explicit cache checks), and recorded the servers' actual request paths. Synthetic PNGs,
ICO files, snapshots, scripts, databases, and logs stayed in a private temporary directory.
Both servers were stopped after verification.

| Finding / flow | Result | Final CLI / server evidence |
| --- | --- | --- |
| Public-like page → private icon | PASS | `--treat-as-public 127.0.0.1`; page declared port 18942 `/secret.png`; `failed=1`; only port 18941 `/` was requested; second server received zero requests |
| Every icon redirect hop | PASS | Allowed `/hop` → same-origin `/jump` → private port 18942; `failed=1`; requests were only `/`, `/hop`, `/jump`; second server received zero requests |
| Initial page redirect | PASS | `/page-redirect` → private port 18942; `failed=1`; only `/page-redirect` was requested |
| Private page, same origin | PASS | `http://localhost:18941/`, without override; `/a.png` fetched; `fetched=1`, origin status 0 |
| Private page, different origin | PASS | A localhost page declared the private second server; `failed=1`; no second-server request |
| Private ranges / DNS | PASS | 14 declared targets covered localhost, child.localhost, all seven IPv4 ranges, ::1, fc00::1, fe80::1, mapped loopback, and integer-form loopback; all returned `failed`; no target fixture request. An independently resolved `127.0.0.1.nip.io` target also returned `failed` with zero second-server requests |
| 5,000 candidates / cap | PASS | Fast 404 endpoints: 15 declared icon requests, then `/favicon.ico`, exactly 16 total icon attempts; `missing=1`, 110.199 ms fetch time |
| Cap after ranking | PASS | The 5,000th link declared 64×64; only the page and that `/a.png` were requested; `fetched=1` |
| One overall deadline | PASS | 5,000 endpoints each delayed 5.5 s: exactly two icon requests, no fallback request; `failed=1`; 8010.716 ms reported, 8.044 s whole-process wall time |
| Origin-only freshness and status | PASS | CLI ingested a fresh page-specific `/` row; prefetch still requested the page and fallback, then reported `missing=1`. Rows were `('', 1)` and `('/', 0)`. The second process printed cached `missing`, with zero server requests |
| PNG dimensions before decoding | PASS | A 1×1 compressed pixel stream with a 20000×20000 IHDR exited 1 through `ingest`, wrote zero rows, and used 17,367,040 bytes peak RSS; normal 1×1 ingest used 18,644,992 bytes. Fetch also rejected that PNG and tried fallback |
| Byte limit in ingest and fetch | PASS | A valid PNG padded to 600 KiB exited 1 through `ingest`, wrote zero rows, and used 8,617,984 bytes peak RSS. Fetch rejected it and tried fallback |
| ICO / SVG dimensions | PASS | ICO with only a 20000×20000 frame and SVG with 20000×20000 intrinsic size exited 1, wrote zero rows. ICO containing that large frame plus a valid small frame succeeded by selecting the small frame |
| Shared single flight | PASS | `--diagnostic-concurrent 2` started two prefetch calls and one `fetchOne`; `concurrentPrefetches=2 fetchOne=ok`; server received one page request and one `/a.png` request |
| Empty HTML comments | PASS | Both `<!--><link rel=icon href=/a.png>` and `<!---><link rel=icon href=/a.png>` requested `/a.png`; each reported `fetched=1` |
| Shift_JIS href | PASS | Response charset, `<meta charset>`, and `<meta http-equiv=content-type>` variants each requested `/%E6%97%A5%E6%9C%AC.png` for the synthetic Japanese filename; all reported `fetched=1` |
| Debug-only override | PASS | Release command with the hidden flag but without `OPENKIT_FAVICON_DEBUG=1` exited 2 and made zero requests |
| Persistent readback | PASS | Another page on the fetched origin returned a 64×64 PNG (293 bytes); the page-specific `/` row still returned a 32×32 PNG (206 bytes) despite a missing origin row; an uncovered path printed `absent`, exit 1 |
| SQLite | PASS | Every local fixture database passed `PRAGMA integrity_check` |

Representative commands (paths are temporary placeholders):

```sh
# For the public-like local page; page-origin override, not a global loopback exemption.
OPENKIT_FAVICON_DEBUG=1 openkit favicons fetch --snapshot <fixture> --db <db> --treat-as-public 127.0.0.1
# Two prefetch callers and fetchOne share the same fetcher and actual HTTP requests.
OPENKIT_FAVICON_DEBUG=1 openkit favicons fetch --snapshot <fixture> --db <db> --diagnostic-concurrent 2
# Exercise engine ingestion without substituting a decoder or store.
OPENKIT_FAVICON_DEBUG=1 /usr/bin/time -l openkit favicons ingest http://localhost:18941/ --file <image> --db <db>
OPENKIT_FAVICON_DEBUG=1 openkit favicons ingest http://localhost:18941/ --file <valid-png> --db <db> --page-specific true
openkit favicons get http://localhost:18941/ --db <db> --out <png> --size 32
```

### Real Arc import rerun (redacted)

Copied the 15 `~/Library/Application Support/Arc/*.json` files read-only to a new private
temporary directory before importing. The importer operated on those copies. Its full
output stayed private. No hostnames, titles, or user JSON are committed. Commands:

```sh
openkit import-arc --arc-dir <temporary-arc-copy> --out <temporary-snapshot>
openkit favicons fetch --snapshot <temporary-snapshot> --db <temporary-db>
openkit favicons fetch --snapshot <temporary-snapshot> --db <temporary-db>
openkit favicons stats --db <temporary-db>
```

Final executable output, with only counts and stable per-origin failure identifiers:

```text
import exit=0 processMs=145.639 copiedJSONFiles=15
  totalItems=46 accounted=37 spaces=4
  pinnedTabs=27 todayTabs=0 favorites=6
  folders=1 splits=1 routingRules=1
  skipped easels=0 notes=0 welcome=2 unknown=0
  orphans=0 skippedRoutingRules=0
  containers(structural)=9 check imported+skipped+containers=46 total=46

first fetch exit=0 processMs=8482.432
requested=27 alreadyCached=0 fetched=23 missing=2 failed=2 durationMs=8405.704
origin-10  failed  1.823 ms
origin-11  failed  8001.429 ms

second fetch (new process) exit=0 processMs=28.471
requested=27 alreadyCached=27 fetched=0 missing=0 failed=0 durationMs=0.734

stats exit=0
ok=23 missing=2 failed=2 count=27 totalBytes=124242
integrity_check=ok journal_mode=wal
```

The first run's two failures and two missing origins remain explicit. The second run
cached all statuses, including those failures; it does not turn them into successful
icons. Bulk duration can exceed eight seconds because each origin gets its own deadline
and the six-origin window admits work in stages.

## Framework references

The implementation uses Apple's [URLSession byte stream API](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:))
to stop consuming large responses, and ImageIO's
[thumbnail pixel-size option](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)
to bound raster decoding before final CGContext rendering.

## App integration

`EngineWebContentHost` receives `OpenEngine` favicon events, normalizes each image
to 64 pixels, updates the live row, and queues a page-specific report through
`StoredFaviconCache`. The existing canonical origin plus path key excludes query,
fragment and credentials. A new report replaces that page's stored icon. Quit drains accepted reports after
closing engine hosts. The shared
`FaviconView` observes one cache entry, so reads and replacements redraw reused rows
without a full sidebar reload. Custom icons retain priority. A live image wins while the tab has a live host;
unloaded rows ignore a retained stale live PNG and use storage.
Unloaded pins, slept rows, Favorites and the Space Manager use the cache. The Library
already reads this store for archived rows. A missing icon keeps the existing placeholder;
cache misses do not start network requests or disk access on the main thread.

Limits:

- 512 KiB encoded image input; 1024 pixels per source edge; 8 bits per component;
  at most 32 frames. Raster decoding selects one frame. Vector images are refused.
- 8192 bytes per page/icon URL. The store retains at most 4096 records and 8 MiB
  of accounted storage: PNG bytes, URL bytes, origin/path bytes twice for the
  primary-key index, and 512 bytes per row for metadata/index overhead. Oldest
  reports are evicted before insertion, reserving the new row's accounted cost.
- 4096 SQLite pages of 4096 bytes: 16 MiB database, below 34 MiB with the transient
  rollback journal. The journal truncates after commit. An existing database above 16 MiB
  is refused before SQLite opens it; no compaction scratch file is created.
- 1024 decoded cache entries, including misses: at most 16 MiB of 64×64 RGBA pixels.
  The live cache holds 128 thumbnails (2 MiB decoded). Explicit thumbnail allocation
  is 16 KiB; maximum accepted 8-bit RGBA source bitmap is 4 MiB.
- One worker, at most 1024 queued reads and 32 pending reports (16 MiB encoded data),
  with repeated pending reports for the same page coalesced. Oversized/excess reports
  are refused. A failed report keeps the previous stored image.

Arc import supplies URLs, with no favicon payload or proved mapping from its hash-named
PNG caches (`docs/re/data-model.md` §2). URL-only imported rows therefore use an existing
Open icon for that canonical page, or the placeholder until Open visits it. No Arc
icon files or personal data are copied.

`features-render check` FV1–FV10 covers report ingestion; cold unloaded, slept and
Favorite row pixels; replacement and live priority; input refusal; canonical keys;
cache/queue/disk bounds; and the 8.33 ms p95 scroll budget at 1000 stored-icon rows.
CLI `favicons` FV11 accepts 512 KiB and refuses one byte more; FV12 refuses an
existing SQLite database over 16 MiB without writes or sidecars.
Real-App `sidebar-completion` FV1–FV6 serves a local PNG and compares the actual row's
pixel hash after report, replacement, pin unload, cold relaunch, URL-only insertion,
and a move to Favorites. Verification results are recorded in `docs/app-shell.md`.

### PR #131 corrections

Committed page URL changes also report the current favicon, even when OpenEngine
suppresses an unchanged-icon-URL event. Each host caches the image-to-PNG result
and last canonical key/data pair. The store keeps one bounded normalization memo
and one bounded decoded-image memo; identical bytes reuse codec work.

Cache entries expose observable residency. FIFO eviction marks the old entry as
not resident and clears its image, including the nil-image case, so visible rows
redraw and bind to a replacement entry. The cache remains bounded at 1024 entries.

Storage accounting counts primary-key origin/path bytes twice and includes
512 bytes of per-row/index overhead. Writes reserve space before the upsert.
If the upsert still returns `SQLITE_FULL`, its transaction is rolled back, the
oldest quarter of records is evicted in a separate committed transaction, and the
write is retried once. The 16 MiB physical database cap remains unchanged.

FV13 ingests 1200 distinct 8 KiB URLs through the real store and checks oldest
record eviction, newest-record readback, zero rejected writes and database size.
FV15 displays a real unloaded row, evicts its entry with 1025 keys, reports a new
image, and checks the row's next draw without forcing a reload. Real-App FV14
navigates `/a` to `/b` with one declared favicon URL, unloads the tab, and requires
stored-source pixels for `/b`.
