# Persistent favicons

`OpenStore` stores normalized icons for unloaded tabs, favorites, and imported tabs.
The engine can call `ingest` when a loaded page supplies an icon. This change exposes
that API; it does not change the engine or sidebar consumers.

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
on the actor executor. It has no main-actor methods. Its synchronous throwing initializer
opens the database, so create it from a background caller in the UI integration.

- `icon(for:) -> FaviconImage?` returns an exact path match first, then the origin icon.
  It skips negative/error rows. Successful expired images remain available until replaced
  or purged, so a refresh does not blank a tab. `FaviconImage` is Sendable and contains
  `png32: Data`, `png64: Data?`, and `iconURL: URL?`.
- `ingest(imageData:iconURL:for:pageSpecific:) throws` decodes with ImageIO. It supports
  PNG, ICO, JPEG, GIF, WebP, and BMP. ICO uses the frame closest to 64 pixels by maximum
  dimension. Other raster formats use the first frame. Decoding downsamples to 64 pixels.
  SVG is accepted when AppKit's `NSImage(data:)` can produce a CGImage. Invalid images throw
  `FaviconStoreError.invalidImage`; invalid page URLs and failed writes also throw.
- Rendering uses a high-interpolation sRGB CGContext with transparency. It fits the image
  inside a 32×32 or 64×64 square without changing its aspect ratio, then encodes PNGs.
  A successful write expires after seven days.
- `markMissing(for:)` writes an origin-level negative entry for 24 hours.
- `needsFetch(_:now:)` is false when an unexpired page-specific or origin-level row covers
  the URL, including a negative/error row. Queries and fragments do not distinguish pages.
- `purge(olderThan:) -> Int` deletes rows with `fetched_at` strictly before the date and
  returns the number deleted. `count() -> Int` returns all rows, including negatives/errors.
- `statistics()` returns counts by status and the sum of both PNG payload lengths.

`FaviconFetcher` is Sendable. Its initializer accepts a store, URLSession (default `.shared`),
`maxConcurrent` (default 6, minimum 1), and a per-request timeout (default 5 seconds).
`prefetch(_:)` returns a Sendable `FetchReport`: `requested`, `alreadyCached`, `fetched`,
`missing`, `failed`, `durationMs`, plus redacted per-origin results. `requested` counts
unique eligible origins; the other counts partition that number. Cached negative/error
rows count as `alreadyCached`, not as new missing/failed requests. `fetchOne(_:)` returns
true for an available successful cached icon or a successful fetch, and false otherwise.

## Schema and keys

SQLiteDB enables WAL mode and NORMAL synchronous mode. The store sets a three-second
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

1. Keep the first supplied page per canonical origin. Skip non-HTTP(S) URLs and fresh caches.
   A sliding TaskGroup window limits each prefetch call to six origins by default.
2. GET the page with `Accept: text/html`, a Safari-like User-Agent, and cookie handling off.
   Consume at most 256 KiB, then cancel the underlying data task. Each request has both
   URLRequest's timeout and a wall-clock timeout race, including streamed bodies.
3. Scan the head with a case-insensitive byte scanner. Handle quoted/unquoted attributes,
   comments, and script/style/title/textarea raw text. Stop at `</head>` or `<body>`.
   Accept `icon` (including `shortcut icon`), `apple-touch-icon`, and
   `apple-touch-icon-precomposed`. Ignore `mask-icon`.
4. Resolve hrefs against the final response URL, including relative paths after redirects.
   Decode common named and numeric HTML entities in hrefs. Permit HTTP(S) images and small
   `data:image/png;base64` images only (32 KiB decoded, at most 44 KiB encoded URL).
5. Try the smallest declared square/rectangular size whose two dimensions are at least 64,
   then the remaining sizes in ascending order. Next try Apple touch icons, then other
   icons, preserving document order for ties. Deduplicate candidate URLs.
6. Try `<original-origin>/favicon.ico` last. Downloads are limited to 512 KiB, including
   responses without Content-Length. A 404, invalid image, unsupported SVG, or oversized
   image advances to the next candidate. Store the first success as an origin-level icon.
7. If all candidates are missing/invalid, cache `missing`. If a transport error, timeout,
   or other HTTP error occurred and no icon succeeded, cache `failed`. Cancellation does
   not create a negative/error cache entry.

The limits apply to bytes consumed by the application; URLSession can buffer transport data.
Concurrency is bounded per prefetch invocation, not across independent fetcher calls.

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

## Privacy

No third-party favicon service is used. Prefetch contacts the selected page origins and
icon hosts declared by those pages (including their redirects). The snapshot is not sent
to a search/favicon provider. The CLI uses an ephemeral URLSession without cookie storage,
credential storage, or URL cache. An injected session follows its caller's configuration.

The database contains origin keys, optional page paths, and final icon URLs. Treat it as
private browsing data. The CLI does not print them, titles, paths from errors, or hosts.
Inline PNGs store no icon URL, to avoid copying the base64 payload into metadata.
The verification Arc JSON copies, imported snapshots, SQLite databases, source images,
and raw importer output stayed in a private temporary directory outside this repository.
No Arc bundle content was copied, Arc was not launched, and no desktop input was driven.
Only redacted counts and outputs appear below. No unit tests or mocks were added.

## Verification — 2026-10-25 (America/Vancouver)

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

## Framework references

The implementation uses Apple's [URLSession byte stream API](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:))
to stop consuming large responses, and ImageIO's
[thumbnail pixel-size option](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)
to bound raster decoding before final CGContext rendering.
