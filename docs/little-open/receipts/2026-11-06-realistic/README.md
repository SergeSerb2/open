# Little Open realistic timing receipts

These are measurements, with no performance verdict. See [the report](../../deferred-browser.md#realistic-timing).

- `typed.json`, `external.json`, `immediate.json`: complete 20-pair aggregates, all samples, attempt index, and nearest-rank median/p95 summaries.
- Each matching `.attempts/` directory contains the original pair receipts and logs. All 60 final attempts complete. No final pair is discarded.
- `provenance.json`: main, benchmark and product SHAs, engine hash, App executable hashes, display, and the post-run hash check.

Absolute checkout paths and fresh generated Profile IDs are replaced with placeholders. URLs refer only to the local synthetic fixture server. Private raw receipts remain in `.re/surface-hook/realistic-*-20*`.

Build both controls with `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main OPEN_AUTOMATION=1 ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release`. Check the engine with `python3 tools/e2e/engine_e2e.py --config Release --engine-fingerprint-only --engine-sha256 3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738` in each checkout.

Run each scenario (`typed`, `external`, `immediate`) in one outer quiet-lock session, sequentially. The existing series tool acquires persistent on-screen locks per pair and honors other jobs’ priority flags:

```sh
/usr/bin/lockf -k /tmp/open-m5-quiet.lock python3 tools/e2e/littleopen_bench_series.py \
  --main-bundle <main-bundle> --branch-bundle <branch-bundle> \
  --config Release --samples 20 --scenario typed --report-only --output <new-receipt.json>
```

The default `immediate` scenario and original performance gate remain available without `--report-only`. No product code, baseline, threshold, or comparator changes in this measurement task. No new acceptance gate is added, so a new negative proof is not applicable.
