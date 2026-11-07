# Synthetic Arc Boosts import cache

`generate.py ROOT` writes an entirely synthetic Arc import source and Firestore
LevelDB cache. It calls the existing first-run fixture for the sidebar. It uses
only example.com, synthetic titles, own CSS/JS, and synthetic IDs. No Arc file,
asset, program code, account data, or cache bytes are copied.

Confirmed by Arc binary evidence: `StorableBoostsData` coding keys, Boost ID
`value`, Firestore document dictionary fields (`data` is a JSON string), inner
component coding keys, and collection names. See `docs/re/boosts-store.md`.

Format evidence: the real local remote-document key prefix and one
`MaybeDocument.no_document` were decoded from a private copy. Standard LevelDB
and Firestore protobuf wire layouts are reproduced by this own writer.

Still inferred without a live content sample: the complete populated document,
Storable version 1/set array encoding, and account-to-Default Profile assignment.
The fixture uses reflected text-transform case names (string JSON encoding is
inferred) and proven string `isActive` and `lastModified` fields. It does not
invent a `StorableBoostsData.boosts` payload array.

Cases: enabled CSS/JS/font/case/Zap; disabled Boost; malformed content; unknown
field; deletion and unknown-document markers; another collection; obsolete
manifest table; WAL deletion; torn WAL tail; Snappy literal/copy forms and key
prefix compression. Color and integer zoom inputs are counted as dropped until
an evidence-backed conversion to Open's different model exists.

Run the public CLI flow after building `openkit`:

```sh
python3 tools/e2e/import_boosts_cli.py \
  --cli Packages/OpenKit/.build/release/openkit \
  --report /tmp/open-boosts-cli-flows.json
```

For old-code negative proofs, also pass `--negative-cli` with the unchanged
parent's release binary in its original resource directory. Every positive row
then records `negativeProof: FAIL`: initial mapping/count rows fail on the old
CLI; later predicates fail with the required state removed, then pass after it
is restored. The privacy negative uses `--show-titles` on synthetic data only.
No raw command output enters the JSON receipt. `firstrun_boosts.py` is the
separate real-App block in the `firstrun` suite; it proves source counts, the
report-only seam and refusal of an App-held data root. App runtime/Undo rows
remain explicitly BLOCKED until Section 12 AppBoosts merges.
