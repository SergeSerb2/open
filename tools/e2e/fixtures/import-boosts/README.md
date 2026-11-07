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
The fixture uses binary-confirmed string enum cases and string `isActive` and
`lastModified`, not an invented `StorableBoostsData.boosts` payload array.

Cases: enabled CSS/JS/font/case/Zap; disabled Boost; malformed content; unknown
field; deletion and unknown-document markers; another collection; obsolete
manifest table; WAL deletion; torn WAL tail; Snappy literal/copy forms and key
prefix compression. Color and integer zoom inputs are counted as dropped until
an evidence-backed conversion to Open's different model exists.
