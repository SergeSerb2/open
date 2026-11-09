# Swift ad-block lists and settings

`OpenAdBlock` is an engine-independent OpenKit library. It depends only on
`OpenModel`, `OpenRouting`, and Apple frameworks. The real `openkit adblock` CLI exercises its
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

Redirect resources are app-bound, separate from the 46-list catalog and
`enabledBlockLists`. Stage them with `tools/fetch-adblock-lists.sh` before
standalone SwiftPM builds. The script verifies the pinned uBO archive, runs
the locked `adblock =0.8.11` driver offline under `/tmp`, and verifies the
output SHA-256. A matching `Vendor/adblock/resources.json` is reused without
Rust. The build also caches the hash-verified `ubo.tar.gz` for license-source
staging, so both caches together avoid the network; stale bytes trigger a rebuild, and any pin mismatch exits 1
before publication. Cargo is available on M5 (`~/.cargo/bin`), absent on M1
as checked 2026-11-08; copy the verified output and archive caches to M1 before building.
The generated SwiftPM payload is ignored. Its pins receipt is a checked
mirror of `Engine/fork/adblock/resources-pins.txt`. See plan §9.3 for the
source commit, hashes, driver and `ResourceType` counts.

The App embeds `AdBlock/resources.json`. Each new generation copies it and
records `{file: "resources.json", listID: "_resources", sourceRevision:
[<output pin>], bytes, sha256, generation}` in `manifest.json`. Verification
checks the 4 MiB cap, size, hash and receipt. Legacy generations without it
gain it on the next publish (including open, update and reset); an app pin
change republishes on open. Debug info reports the first 12 hash digits.
`openkit adblock reset` exercises the store's real reset transaction.
`openkit adblock bundle` also copies or repairs resources from the verified
app payload, so its output remains a complete offline seed directory.
No resource download occurs at runtime. Engine N-19 is a separate gate.

The store's `root` is the Open application-data directory. The CLI requires an
explicit root so it cannot change a user's app settings by default. Its default
Profile UUID is `00000000-0000-0000-0000-000000000001`; `--profile UUID` selects
another Profile.

**Lead decision — 2026-10-25: generations replace the former list directory.**
The normative engine directory contract is [plan §9.2](plans/adblock-fork.md#92-per-profile-storage-and-directory-contract).

```text
<root>/
  .adblock-lock
  adblock-settings.json
  Profiles/<dataDirectoryName>/AdBlock/
    catalog-state.json
    exclusions.json                   canonical Unicode sites; unbracketed IPs
    lists/                            engine directory
      downloads/<listID>/<index>.body  hash-checked source cache, never inputs
      current.json                    live + previous {generation, manifestSHA256}
      generations/<n>/
        <listID>.txt                  complete enabled set, one file per list
        manifest.json                 inventory, hashes, generation, state snapshot
        engine.dat                    optional browser-owned, generation-bound
        engine-inputs.json            browser DAT receipt, deferred integration
      quarantine/<n>-<unique>/         rejected generation
```

`openProfile(_:directory:)` takes the canonical `AdBlock` directory from its
caller. `listDirectory(for:)` and engine configure/reload events pass **AdBlock/lists**. The engine must resolve `current.json`, verify its manifest hash, and
verify every manifest file's size and SHA-256 before loading. It reads only that
inventory. Extra `.txt` files, legacy loose list directories, and unreferenced
generations cannot become engine inputs. A cached DAT is valid only within the
same generation with recorded input hashes equal to the manifest. The plan
also specifies the DAT's own hash/size receipt. Swift never writes DAT.

Each manifest entry records `file`, `bytes`, `sha256`, `listID`, `sourceRevision`
(ordered upstream SHA-256 revisions, or bundled pin), and `generation`.
The manifest repeats the generation and includes its immutable enabled-list
state and source receipts. Source receipts hold ETag, Last-Modified, hash, size;
list receipts also hold last-check time. Dates use Foundation reference seconds.

Enable, disable, and successful updates (including all-304) publish a new,
complete generation. All files, the manifest, and their directories are fsynced;
state is persisted **before** the temporary `current.json` is fsynced and renamed.
The parent is then fsynced. Cleanup retains the live and previous generations.
A failed batch leaves the live pointer unchanged. A crash before the rename
leaves the old complete generation usable; the next open reconciles persisted
state from its manifest and removes unreferenced generations.

Every open hashes every live list before `configure`. A mismatch quarantines
the generation and restores the previous one after verifying it. If none is
valid, the store reseeds pinned defaults or refetches defaults. `lastError` reports
the integrity failure and recovery. Legacy enabled settings and exclusions can
migrate from `AdBlock/`; its list files are never trusted as engine inputs.
The engine must repeat verification at load to cover changes after Swift opens.

## Pins, downloads, and offline use

The release seed pins live in
[`list-pins.txt`](../Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt).
Both defaults come from the official [easylist/easylist repository](https://github.com/easylist/easylist),
using immutable `raw.githubusercontent.com` URLs at one pinned `gh-pages`
commit. The three columns are local name, seed URL, and SHA-256.

```sh
# From the repo root. Downloads only from official HTTPS upstreams.
tools/fetch-adblock-lists.sh
# Deliberate pin changes, reviewed with the code change:
tools/fetch-adblock-lists.sh --update-pins
```

The script stages under ignored `Vendor/adblock/`. It verifies list headers and
SHA-256 before replacement. List text is never committed. Normal fetching uses
exactly the pinned URLs and can reuse verified local files offline; it refuses
a tampered cache. `--update-pins` resolves the current official `gh-pages`
commit once, rewrites both URLs and hashes, and prints old → new values.
This seed policy changed on 2026-11-07 because the live EasyList URL changes
many times per day. App packaging copies verified files into Resources/AdBlock.

Supply that bundle directory to `AdBlockStore` before opening a Profile. It
verifies the fixed pins and seeds missing enabled defaults, without a network
request. A damaged bundle fails its pin check. The real `adblock bundle --dir`
command repairs a damaged staged default by downloading its pinned seed URL,
then verifies the same fixed pin before replacing it. Its result prints
`seed_url` for each download. Seed fetches permit only their source host,
`raw.githubusercontent.com`; they do not add that host to runtime redirect
allow-lists. A wrong pin fails with expected and actual hashes and preserves
the existing file.

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
publication. Redirects must stay on HTTPS and the original source host, unless that exact
destination host is in the list's optional catalog `redirect_hosts` array.
Cross-host rejection is non-retryable and names the CDN-allowlist policy. URLSession cache and cookies are off.
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
try await store.openProfile(profileID, directory: directories.adBlockDirectory(dataDirectoryName: profile.dataDirectoryName))
try store.setEnabled(false)
try store.setExcluded("news.example.co.uk", excluded: true, profile: profileID)
try await store.setListEnabled("fi", true, profile: profileID)
try await store.updateListsNow(profile: profileID)
let snapshot = store.siteSnapshot(for: profileID)
let allowed = try snapshot.isAllowlisted(host: "cdn.example.co.uk")
try store.closeProfile(profileID)
// Permanent deletion: await the IO barrier before ProfileTeardown removes any folder.
await store.retireProfile(profileID)
```

`isEnabled` is readable; `setEnabled` is the throwing persistence setter.
`enabledListIDs(for:)`, `excludedDomains(for:)`, `listDirectory(for:)`, and
`debugInfo(profile:)` provide the plan's read contract. Mutation methods throw so
the caller can show a failure. `setListEnabled` is async because a new optional
list must download before becoming an engine input. OpenEngine needs no CEF type
in this contract. It binds the value-only `AdBlockEngineEvent` callback:

- `configure` provides Profile ID, list directory, master state, and exclusions
  after live-generation integrity verification/recovery. Attach the callback before opening Profiles.
- `enabled` applies the master state to all open Profile controllers.
- `exclusions` changes a Profile's in-memory exclusion set without rebuilding.
- `reload` occurs once after a changed batch or list toggle, never for all-304.
- `closed` lets the adapter release the engine before temporary files disappear.

Profile operations cannot overlap. Scheduled updates start after 60 s and repeat
at 24 h. Busy or failed scheduled updates retry after 1 min, 5 min, 30 min,
then 24 h. A successful attempt resets the ladder. `onScheduledUpdate` reports
the outcome and the next nominal delay. Closing a Profile cancels its schedule; store destruction cancels remaining
schedules. A failed update keeps old inputs and saves its error for Settings.

Allowlist mutations accept hosts only, with optional `*.`. They share
`OpenRouting.HostNormalizer.canonicalHostName`: percent-decoded UTF-8, Unicode
NFC, Punycode decode, lowercase, trailing-dot removal, and unbracketed IPv6.
This exposes the existing routing implementation; it does not copy or change
routing-specific `www.` matching. PSL rules use the same Unicode form.
Store the registrable domain using the full PSL including private registries.
Subdomains match at label boundaries; IPs match exactly. Bare suffixes, paths,
ports, empty labels, and invalid characters fail. The CLI `allowlist check`
also accepts a URL, extracts `URL.host()`, and uses the same normalization.

Cache the immutable site snapshot for navigation. The fast
`isAllowlisted(normalizedHost:)` expects that shared canonical form and does no
file IO or PSL traversal. `isAllowlisted(host:)` normalizes caller input.

`incognito: true` requires bundled defaults, uses a fresh temporary root, does
not read the supplied persistent root, and keeps settings in memory. Only the
engine's temporary list/cache files and lease use that root. Close removes the
Profile directory; session end removes the temporary root. No persistent JSON
preferences or user Profile directories are written.

## Original CLI acceptance, 2026-10-25 (before review fixes)

This historical pass used the former layout and timing boundary. The PR #31
review-fix results below supersede its warm-open and directory claims.

Host: Apple M5 Pro, macOS 27.2. Build from `Packages/OpenKit` only:
`nice -n 10 swift build -c release -j 6`. Final verification ran after merging `origin/main` through `f4f87da` and retained
all OpenKit targets and import CLI commands. No unit tests, app/desktop automation,
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
| Unreachable network | `adblock update --dir "$ROOT" --proxy http://127.0.0.1:9 --timeout 2` | Exit 1; `EasyList: network error (310); attempts=3`; 3.34 s; both old list hashes unchanged; error persisted |
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
| Performance | `adblock perf --dir <tmp>` | 10 groups × 1,000 lookups, 5,000 matches; combined saved-model load + 1,000 lookups p95 **0.8130 ms**, below 1 ms |
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
| EasyList | 2,250,219 | `a0d4febfde2357c05860a2f9d8ab8cd933fb4162c6da51785e428d864eb6ebca` | `W/"6adea500-2255eb"` | 80.09 / 49.44 ms |
| EasyPrivacy | 1,511,221 | `909ce5a652f8929c3eda1da4a86f363b840f2932ff4139c0ee59f8fdef0da23c` | `W/"6adea5f5-170f35"` | 43.05 / 55.76 ms |

Final reviewed bundled seeds (separate from the runtime receipt above):

| File | Bytes | Lines | SHA-256 |
|---|---:|---:|---|
| easylist.txt | 2,250,326 | 86,359 | `f167f3d1a0f5f0db5fcea739a51addc841c6abcd237a036963216b285403c13f` |
| easyprivacy.txt | 1,511,221 | 57,181 | `909ce5a652f8929c3eda1da4a86f363b840f2932ff4139c0ee59f8fdef0da23c` |

The final merged-tree run first encountered a new EasyList revision while repairing
an older pinned seed. Repair exited 1 with `downloaded bundle SHA-256 pin mismatch`
and did not overwrite the damaged file with unpinned bytes. After an explicit
reviewed `--update-pins` refresh and the same bounded release build, the final pin
check rejected the tampered seed and the repair fetched 2,250,326 bytes from the
official host in 76.98 ms, verified the new pin, and replaced it. Offline seeding,
incognito cleanup, and the performance budget then passed on that final build.
The ordinary build-time fetch also passed with the reviewed pins. All other
adblock flows and the five required existing CLIs passed on the merged sources.

## PR #31 review fixes — 2026-10-25

The Lead's generation decision above supersedes the old layout. Verification
uses the real release CLI in isolated temporary roots. The build command stays
`nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`, in a separate
process session. No unit tests, subagents, desktop automation, Arc launch,
engine build/sync, or shared Chromium-tree changes ran.

Diagnostic controls are opt-in environment variables on that same real CLI:

- `OPEN_ADBLOCK_DEBUG_KILL_BEFORE_CURRENT=1`: SIGKILL after durable generation
  and state writes, before the current-pointer rename. The process cannot fall
  through while signal delivery is pending.
- `OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE=0.002`: scale only timer sleeps; reports
  retain their nominal seconds. `OPEN_ADBLOCK_DEBUG_UPDATE_DELAY_SECONDS=0.18`
  holds the real manual operation's busy gate for the collision check.
- `OPEN_ADBLOCK_DEBUG_SOURCE_ROOT=http://127.0.0.1:<port>`: direct source paths
  to a real loopback HTTP fixture server. Only explicit loopback HTTP roots
  with ports are accepted. Normal downloads and redirects require HTTPS.
  The same URLSession delegate and per-list host policy run in both cases.

`openkit adblock schedule --dir ROOT --seconds N` keeps the real store open
with its scheduler and starts a competing manual update. Retry receipts come
from `onScheduledUpdate`; success resets the retry ladder.

| Finding | Fix | Real CLI result |
|---|---|---|
| 1 · P1: tampered lists load on warm open | Verify manifest hash and every listed size/SHA-256 before configure; quarantine and recover | **PASS**: flipped byte 500 in live EasyList; next `status` quarantined it and restored the verified previous generation with the proxy unreachable. Tampering the sole remaining generation reseeded pinned defaults offline. Manifest tampering also fell back. Failed recovery emitted no configure. |
| 2 · P1: IPv6 / IDN canonical form | Share routing's canonical host-name function; store unbracketed IPv6 and Unicode NFC; canonicalize PSL rules | **PASS**: `allowlist add '[::1]'`, checks for `::1`, `[::1]`, and `http://[::1]:8080/x`; `::2` stayed blocked. Unicode, Punycode, NFD, percent encoding, case/trailing dots, private suffixes, exact IPs and domain boundaries passed across separate processes. |
| 3: incomplete directory contract | Complete immutable generations; current pointer binds manifest; engine reads only listed inputs; DAT must bind the same generation/input hashes | **PASS (Swift contract)**: enable/disable and both 200/304 updates each published a complete new generation. Unlisted text, legacy lists, ahead-of-pointer settings, and unreferenced generations were ignored. The documented engine/DAT runtime implementation remains deferred. |
| 4: publication/state ordering | Fsync generation, save state, then atomic current-pointer replacement; reconcile state from committed manifest | **PASS**: diagnostic SIGKILL exited **-9** after staging a disable and saving state. `current.json` and all old list bytes stayed intact. The next offline open kept both lists, restored old state, and removed the unreferenced generation. Corrupt catalog-state also recovered from the manifest. Only live + previous numeric generations remained. |
| 5 · P2: redirects | Require same source host or exact per-list catalog `redirect_hosts`; retain the clear rejection reason | **PASS**: real loopback HTTP server's same-host redirect loaded. A redirect from `127.0.0.1` to `localhost` failed once with `cross-host redirect rejected`; the destination received no request. Production requires HTTPS. |
| 6 · P3: scheduled collision/failure | Retry at 60 / 300 / 1,800 seconds, then 86,400; reset on success | **PASS**: real manual/scheduled collision reported `busy`, then retry delay **60**, then success. Real redirect failures reported **60, 300, 1800, 86400**. Timer scale 0.002 made the first minute 0.12 seconds. |
| Earlier list/settings acceptance | Re-run catalog, official downloads/ETags, full-batch failures, multi-source concatenation, profile/global settings, allowlist, offline seed, and incognito cleanup | **PASS**: 46 entries with categories 3/2/5/35/1; two real 200s then two 304s with no body/reload; proxy and size failures preserved the live pointer/hashes; `fi` concatenation and 304/304 passed; profile isolation, toggles, invalid inputs and incognito cleanup passed. |
| Earlier bundled repair acceptance | Preserve immutable release pins and reject moved upstream bytes | **PIN DRIFT / SAFE REJECTION**: official EasyList had moved; repair exited 1 with `downloaded bundle SHA-256 pin mismatch` and kept the damaged seed unmodified. A real loopback server serving the original official pinned bytes repaired it successfully. No pins were changed. |
| Earlier 1 ms performance gate | Keep required warm-open verification and the unchanged benchmark/budget | **FAILED**: warm open + 1,000 lookups p95 **4.0620 ms**, budget 1 ms; 5,000/10,000 matches correct. Largest lookup-only group **0.2155 ms**. The old metric now includes integrity scanning of the default lists; no gate or timing boundary was relaxed. |
| Required existing CLI regressions | Re-run final release commands and routing cases | **PASS**: `import-arc`, `roundtrip`, `commands-demo` **66/66**, `suggest-check` **31/31**, `commands-dump`, and route **A1–A17**; all exited 0. |

Final release build completed with zero warnings and errors (7.80 seconds).
The main adblock receipts are under
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-pr31-review-ansf6q0r`;
regression receipts are under
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-pr31-regressions-2x7v09ng`.
Temporary drivers and raw receipts are not committed.

The engine adapter and its DAT loader remain deferred. Manifest verification
before configure and the on-disk engine contract are covered here; this CLI
pass does not claim CEF/DAT runtime acceptance.

## Scope deviations and remaining integration

- Catalog and list pins live in the OpenKit target. Resource pins live in
  `Engine/fork/adblock`, with a byte-checked package mirror. The fetch script
  reads both receipts. The later engine work can consume these resources.
- BCNYBlocklists is an unavailable catalog entry because the reference manifest
  supplies no public upstream source. The `dk` ID and 18 Korean sources follow
  the actual manifest rather than the plan's summaries.
- `AdBlockStore` supplies throwing setters, an async list-enable operation, and
  value-only engine events. An OpenEngine adapter still needs to bind those events.
- Engine steps and actual page blocking remain separate. Redirect resource
  assembly, bundling and Swift generations are implemented (plan §9.3).
  CLI reload-event counts prove the Swift contract only.

### Performance budgets (lead decision, 2026-10-25)

The single "load + 1,000 lookups < 1 ms" gate mixed two different costs once warm-open integrity verification became mandatory. `openkit adblock perf` now checks two budgets:

| Metric | Budget | Measured (lead run, Chromium build running) |
|---|---|---|
| 1,000 allowlist lookups (what page loads pay) | p95 < 1 ms | 0.444 ms |
| Profile open incl. SHA-256 scan of the live generation (once per profile, off the main thread) | p95 < 10 ms | 6.555 ms |

**Lead decision — 2026-11-09:** profile-open timing now takes **40 samples**
and reports both nearest-rank p95 (sorted sample 38 of 40) and max. The
**10 ms p95 limit is unchanged**. With the former ten samples, nearest-rank
p95 was the maximum; one slow sample therefore made a maximum-time gate
out of the intended percentile. All 40 samples construct a fresh Store,
open the same persisted Profile, and verify every live-generation file's
size and SHA-256. A private root is seeded once before timing; no sample
skips verification or trusts a persisted verified flag. The ten groups of
1,000 lookups and their 5,000-match requirement stay unchanged. `check.py`
requires the 40-sample receipt; `budgets.py` records p95 with `samples=40`
and retains max as information, without a separate maximum budget.

Three quiet Release runs of `tools/budgets.sh --only adblock` on 2026-11-09
passed both unchanged limits. Each used 40 opens and ten lookup groups
(5,000 matches in 10,000 lookups), under the quiet lock with load1 below 12:

| Run | Profile-open p95 | Profile-open max (info) | 1,000-lookups p95 | Load1 start → end |
|---|---|---|---|---|
| 1 | 3.0811 ms | 20.8206 ms | 0.1360 ms | 9.37 → 9.34 |
| 2 | 2.6520 ms | 2.7639 ms | 0.1517 ms | 9.34 → 9.34 |
| 3 | 2.5167 ms | 2.9143 ms | 0.3190 ms | 9.34 → 9.72 |

Run 1 retains its slow sample in max and in the full sample list; no sample
is discarded before computing p95. Verification and timed boundaries are
unchanged. The correction changes the sample count, not the 10 ms limit.
