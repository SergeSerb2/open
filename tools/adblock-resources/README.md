# Redirect-resource assembler

Run `tools/fetch-adblock-lists.sh` from the checkout. It verifies
`Engine/fork/adblock/resources-pins.txt` and `resources-inputs.sha256`, copies
this driver to a temporary `/tmp/open-adblock-resources-*` directory, fetches
the checksum-locked crates, then invokes:

```sh
cargo run --quiet --offline --locked --manifest-path "$work/driver/Cargo.toml" -- \
  "$work/src/web_accessible_resources" \
  "$work/src/js/redirect-resources.js" \
  "$work/resources.json"
```

Here `work` is the temporary directory created by the staging script.
The source archive comes from the official uBO repository at the fixed commit
in the pins file. The driver calls only `assemble_web_accessible_resources`
from crates.io `adblock =0.8.11`, with the fork's features. It filters by
`ResourceType::supports_redirect()`, sorts by name, prints counts per crate
kind, and serializes the crate's `Vec<Resource>` directly with serde_json.
The driver never calls a scriptlet assembler. Cargo.lock pins rmp to 0.8.11,
as in the vendor patch; rmp 0.8.15 removed APIs that rmp-serde 0.15 needs.

The parent script verifies the output pin before publication. The generated
JSON and source data stay ignored. Original UTF-8 redirect-source files and
LICENSE.txt are bundled for acknowledgements; binary stub bodies are already
encoded in the crate output. See plan §9.3 and the release license inventory.

For a pin refresh, update the fixed uBO archive URL/hash and per-input hashes,
run this driver in `/tmp`, inspect its kind counts, then update the output
hash in both the engine pins file and its SwiftPM mirror. Never hand-convert
resources, accept a mismatching output, or change the runtime download path.

## Machines without Cargo

`tools/fetch-adblock-resources.py` first looks for a pinned output in the
machine-wide cache `~/Library/Caches/OpenRE/adblock-resources/<output sha256>/resources.json`
(and in `Vendor/adblock/`). Every successful run writes that cache, so fresh
worktrees on the same machine never need Cargo. A machine without Cargo (the
M1) needs the cache seeded once: copy the file from a machine that built it;
the output pin verifies it, and a mismatching file is ignored and rebuilt or
refused. Seeded on the M1 on 2026-11-08 (Section 13 lead).
