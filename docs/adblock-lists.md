# Swift ad-block lists and settings

`OpenAdBlock` is an engine-independent OpenKit library. It depends only on
`OpenModel` and Apple frameworks. The real `openkit adblock` CLI exercises its
public store. This implements the Swift slice authorized by the Lead decisions
appendix in [adblock-fork.md](plans/adblock-fork.md), not the engine milestones.
No engine build, CEF integration, app UI, or blocking behavior is claimed here.

## Catalog

The committed source is
[`catalog.json`](../Packages/OpenKit/Sources/OpenAdBlock/Resources/catalog.json).
It contains all 46 reference IDs, display names, categories, information URLs,
bundle flags, and default-enable flags. Official download URLs replace mirror
prefixes. Multiple source URLs retain their original order.

| Category | Entries | Enabled by default |
|---|---:|---|
| generic | 3 | EasyList |
| cookies | 2 | none |
| privacy | 5 | EasyPrivacy |
| regional | 35 | none |
| bcny | 1 | none |

Evidence for reference metadata: `docs/re/features-advanced.md` AD-3/AD-4 and
`.re/features-advanced/blocklist-manifest.json` in the project root. The local
manifest SHA-256 was
`091cedcbf786604486148f2ffe6827d2842e26a26258e48a3915078dc861156d`.
The transform used each `known_block_lists` entry, retained its `id`,
`display_name`, and `info_url`, renamed `type` to `category`, and replaced the
mirror prefix in `urls`. Counting these fields with Python gave 46 entries and
3/2/5/35/1 category counts. No list text or browser assets were copied.

Three source facts differ from the plan prose: the Dutch ID is `dk`, not `ndk`;
`kr` has 18 URLs, not 17; and BCNYBlocklists has only two mirror-relative
`bcny_lists/list_*.txt` paths. Those paths contain no public upstream host.
BCNYBlocklists stays in the catalog with empty `urls` and an explicit
`unavailable_reason`. Enabling it fails cleanly. No mirror dependency or
invented URL replaces it. Availability of every optional upstream is not claimed;
45 entries have upstream URL metadata, and the defaults plus `fi` were downloaded.

## Files and ownership

The store's `root` is the Open application-data directory. The CLI requires an
explicit root so it cannot change a user's app settings by default. Its default
Profile UUID is `00000000-0000-0000-0000-000000000001`; `--profile UUID` selects
another Profile.

```text
<root>/
  .adblock-lock                        process lease; concurrent writers fail
  adblock-settings.json               { "nativeAdBlockEnabled": true }
  Profiles/<UUID>/AdBlock/
    catalog-state.json                catalogVersion, enabledBlockLists,
                                      lists[id] receipts, lastError
    exclusions.json                   sorted ASCII registrable-domain array
    downloads/<listID>/<index>.body    verified source cache, outside engine input
    lists/
      <listID>.txt                     enabled lists only; atomic replacements
      resources.txt                   reserved for the later resources stage
      engine.dat                      browser-owned; Swift never writes it
```

OpenEngine receives **`<root>/Profiles/<UUID>/AdBlock/lists/`**, not its parent.
This follows the normative paragraph after the contradictory §9.2 diagram in
the plan. The browser owns `lists/engine.dat`. Disabling a list removes its `.txt`
file before the reload event. Swift does not create `resources.txt`; the assembler
and its inputs belong to the deferred engine work.

A list receipt holds its SHA-256, byte size, last-check time, and an ordered
source-receipt array. Source receipts hold ETag, Last-Modified, SHA-256, and size.
Dates use Foundation Codable's seconds since 2001 reference date. Catalog and
pins are immutable package resources, not a remotely fetched manifest.
The `enabledBlockLists` key is per Profile; `blockListsPerProfile` is represented
by the Profile directory map rather than a second duplicate preferences file.

Settings write before in-memory changes are published. JSON and list writes use
a temporary file and rename in the destination directory. A complete update
batch stages outside `lists/`; network or validation failure discards the batch.
Publication replaces each changed list atomically, then saves receipts and emits
one reload event. A filesystem publication failure attempts to restore the old
files and reports failure. A sudden process crash can interrupt a batch between
individual file renames; every individual list remains complete, and hashes
invalidate stale cache receipts on the next update. This is not a cross-file
filesystem transaction.

## Pins, downloads, and offline use

The release seed pins live in
[`list-pins.txt`](../Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt).
The [official EasyList site](https://easylist.to/) supplies both defaults.

```sh
# From the repo root. Downloads only from official HTTPS upstreams.
tools/fetch-adblock-lists.sh
# Deliberate pin changes, reviewed with the code change:
tools/fetch-adblock-lists.sh --update-pins
```

The script stages under ignored `Vendor/adblock/`. It verifies list headers and
SHA-256 before replacement. List text is never committed. Mutable upstream URLs
can change during development; an ordinary fetch must then fail its old pin.
Only explicit `--update-pins` changes committed pins. This occurred during this
implementation and confirmed that ordinary fetching does not silently repin.
The app packaging step must copy the verified files into Resources/AdBlock.
That app packaging and uBO resources remain deferred.

Supply that bundle directory to `AdBlockStore` before opening a Profile. It
verifies the fixed pins and seeds missing enabled defaults, without a network
request. A damaged bundle fails its pin check. The real `adblock bundle --dir`
command repairs a damaged staged default by an unconditional official download,
then verifies the same fixed pin before replacing it. If upstream changed, repair
fails safely until a reviewed pin update supplies a new seed snapshot.

Runtime updates use live upstream revisions. They validate the header and save
a new SHA-256 receipt, rather than requiring live revisions to equal the fixed
release seed. Before sending `If-None-Match` (or `If-Modified-Since` if no ETag),
the updater verifies both the final list and cached source against their receipts.
Tampering or a missing cache causes an unconditional fetch. `304` keeps the
verified source bytes and changes only the check time. Multi-URL lists concatenate
all verified sources with a newline separator in catalog order.

The default policy caps a source at 16 MiB and a combined list at 64 MiB. The
URLSession delegate enforces the cap during streaming and checks advertised size.
The request idle timeout is 30 s; the resource timeout is 90 s. Network failures,
HTTP 408/429, and HTTP 5xx get three attempts with 1 s then 2 s backoff. Header,
size, and other HTTP failures do not retry. Cancellation stops work before
publication. Redirects must stay on HTTPS. URLSession cache and cookies are off.
Errors saved in `lastError` contain the list ID and operation/code, not page URLs,
list contents, or paths. Copyable `debugInfo` also omits exclusions and Profile paths.

## Store contract

`AdBlockStore` is `@MainActor`. Small settings load synchronously; large list IO,
seeding, hashing, and downloads run through its IO actor. The catalog and full
PSL load once. The copied PSL retains its upstream MPL notice and includes
private registries, as required by the engine's exclusion semantics. Keeping the
snapshot in this target avoids depending on the suggestion and SQLite stacks.

```swift
let store = try AdBlockStore(
    root: applicationDataDirectory,
    bundledDefaultsDirectory: bundledAdBlockDirectory
)
store.onEngineEvent = { event in
    // The OpenEngine adapter handles configure/enabled/exclusions/reload/closed.
}
try await store.openProfile(profileID)
try store.setEnabled(false)
try store.setExcluded("news.example.co.uk", excluded: true, profile: profileID)
try await store.setListEnabled("fi", true, profile: profileID)
try await store.updateListsNow(profile: profileID)
let snapshot = store.siteSnapshot(for: profileID)
let allowed = try snapshot.isAllowlisted(host: "cdn.example.co.uk")
try store.closeProfile(profileID)
```

`isEnabled` is readable; `setEnabled` is the throwing persistence setter.
`enabledListIDs(for:)`, `excludedDomains(for:)`, `listDirectory(for:)`, and
`debugInfo(profile:)` provide the plan's read contract. Mutation methods throw so
the caller can show a failure. `setListEnabled` is async because a new optional
list must download before becoming an engine input. OpenEngine needs no CEF type
in this contract. It binds the value-only `AdBlockEngineEvent` callback:

- `configure` provides Profile ID, list directory, master state, and exclusions
  after seeding. Attach the callback before opening Profiles.
- `enabled` applies the master state to all open Profile controllers.
- `exclusions` changes a Profile's in-memory exclusion set without rebuilding.
- `reload` occurs once after a changed batch or list toggle, never for all-304.
- `closed` lets the adapter release the engine before temporary files disappear.

Profile operations cannot overlap. Scheduled updates start after 60 s and repeat
at 24 h. Closing a Profile cancels its schedule; store destruction cancels remaining
schedules. A failed update keeps old inputs and saves its error for Settings.

Allowlist input is a host, not a URL. Normalize case, strip one trailing dot and
optional `*.`, convert IDN to ASCII, then store the registrable domain using the
full PSL, including private registries. A site covers that domain and subdomains
at label boundaries. IP literals compare as hosts. Bare public suffixes, paths,
ports, empty labels, and invalid host characters fail. There is no preloaded
breakage allowlist. Exact-page session exceptions belong to the later UI contract.
For the hot path, keep the immutable snapshot and call
`isAllowlisted(normalizedHost:)` with an already normalized ASCII host. This does
no disk IO or PSL traversal. `isAllowlisted(host:)` performs input normalization.

`incognito: true` requires bundled defaults, uses a fresh temporary root, does
not read the supplied persistent root, and keeps settings in memory. Only the
engine's temporary list/cache files and lease use that root. Close removes the
Profile directory; session end removes the temporary root. No persistent JSON
preferences or user Profile directories are written.

## CLI acceptance, 2026-10-25

Host: Apple M5 Pro, macOS 27.2. Build from `Packages/OpenKit` only:
`nice -n 10 swift build -c release -j 6`. No unit tests, app/desktop automation,
engine build, or shared Chromium-tree operations ran.

Commands below use `CLI=Packages/OpenKit/.build/release/openkit` and a fresh
`ROOT=$(mktemp -d)` from the repo root. Evidence was captured through subprocesses
of this real CLI. No mocked transport or injected list response was used.

| Check | Real command/flow | Result |
|---|---|---|
| Catalog | `$CLI adblock catalog` | 46; categories 3/2/5/35/1; EasyList + EasyPrivacy default on |
| Download | `$CLI adblock update --dir "$ROOT"` | Both real 200; sizes/hashes/ETags below; one reload event |
| Conditional GET | Repeat update | Both 304; zero downloaded body bytes; zero reloads |
| Profile tamper | Flip byte 500 in `lists/EasyList.txt`, then update | Failed local integrity; unconditional 200; original good SHA restored; one reload |
| Bundle tamper | Flip byte 500 in staged `easylist.txt`; open with `--bundled-dir`; then `adblock bundle --dir <stage>` | Pin mismatch rejected the seed; repair fetched official bytes and restored the fixed pin |
| Unreachable network | `adblock update --dir "$ROOT" --proxy http://127.0.0.1:9 --timeout 2` | Exit 1; `EasyList: network error (310); attempts=3`; 3.15 s; both old list hashes unchanged; error persisted |
| Size cap | `adblock update --dir "$ROOT" --max-bytes 100` | Exit 1; source size limit; one attempt; both old list hashes unchanged |
| Allowlist persistence | Add/list/check/remove across separate CLI processes | Case/trailing-dot/wildcard normalization; subdomain true; adjacent-domain false; Unicode/punycode equivalent; removal persisted |
| Private suffix + IP | Add `news.alice.github.io` and `127.0.0.1` | `alice.github.io` stored; `bob.github.io` remained blocked; IP allowlisted |
| Invalid input | Add `co.uk` or `https://example.com/path` | Clean errors; no broadened exclusion |
| Profiles | Read exclusions in a second UUID | Independent empty set |
| Global toggle | `adblock toggle off/on --dir "$ROOT"`; read another Profile | Master state persisted across processes and applied globally |
| Per-list toggle | `adblock list EasyPrivacy off/on --dir "$ROOT"` | Disabled file removed; enabled file downloaded before reload; one reload per change |
| Invalid list | Enable `BCNYBlocklists` or `../../escape` | Clean error; no enabled-state change |
| Multi-URL | Enable `fi`, then update | Both official sources fetched; final bytes equal source 0 + newline + source 1; later `304,304` |
| Offline first open | `adblock status --bundled-dir <verified-stage> --proxy http://127.0.0.1:9 --dir <fresh>` | Both defaults seeded from pinned files with no download |
| Incognito | `adblock status --incognito --bundled-dir <stage> --dir <unused>` | Temporary seeded directory removed at exit; supplied persistent root never created |
| Performance | `adblock perf --dir <tmp>` | 10 groups × 1,000 lookups, 5,000 matches; combined saved-model load + 1,000 lookups p95 **0.7557 ms**, below 1 ms |
| Existing CLIs | Real `import-arc`, `roundtrip`, `commands-demo`, `suggest-check`, `commands-dump` | Import accounting OK; roundtrip OK; commands-demo 66/66; suggest-check 31/31; commands-dump OK |

The performance clock starts before each fresh `AdBlockStore` construction and
Profile settings load and stops after 1,000 lookups. It includes reopening and
decoding the saved model, process lease, snapshot creation, and lookups. It excludes
process launch, the one-time catalog/PSL load, network, and seed copying. The sample
model has the two default enabled IDs and two excluded sites. Ten groups give
10,000 lookups; nearest-rank p95 is the largest group. The check exits nonzero at
1 ms or on a wrong match count. During implementation the full load initially
failed the budget; caching immutable metadata, removing warm-open executor hops,
and reducing redundant file operations brought the unchanged check below budget.

Initial real-download receipt from this acceptance run (runtime revisions may
differ from bundled release pins):

| List | Bytes | SHA-256 | ETag | Download / 304 duration |
|---|---:|---|---|---|
| EasyList | 2,250,219 | `a0d4febfde2357c05860a2f9d8ab8cd933fb4162c6da51785e428d864eb6ebca` | `W/"6adea500-2255eb"` | 83.87 / 51.33 ms |
| EasyPrivacy | 1,511,221 | `909ce5a652f8929c3eda1da4a86f363b840f2932ff4139c0ee59f8fdef0da23c` | `W/"6adea5f5-170f35"` | 46.42 / 35.13 ms |

## Scope deviations and remaining integration

- Catalog and pins live in the new OpenKit target, with one canonical copy each,
  instead of the deferred `Engine/fork/adblock` directory. The fetch script reads
  those same pins. The later engine/package work can consume these resources.
- BCNYBlocklists is an unavailable catalog entry because the reference manifest
  supplies no public upstream source. The `dk` ID and 18 Korean sources follow
  the actual manifest rather than the plan's summaries.
- `AdBlockStore` supplies throwing setters, an async list-enable operation, and
  value-only engine events. An OpenEngine adapter still needs to bind those events.
- Engine steps, resources assembly, actual page blocking, and app packaging are
  deferred as requested. CLI reload-event counts prove the Swift contract only.
