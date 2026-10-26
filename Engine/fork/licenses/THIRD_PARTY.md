# Third-party dependencies in the engine fork

Every new dependency needs a row here in the same PR that introduces it
(repo rule: minimal dependencies, each with a written reason).

| Crate / library | Version | License | Used by | Reason | Source offer / notes |
|---|---|---|---|---|---|
| adblock (Brave adblock-rust) | 0.8.11 | MPL-2.0 | //open/adblock (browser process) | Network + cosmetic matching at uBlock quality; see docs/adblock-design.md | Planned only in Phase A. Step 8 adds vendored sources in patches/rust/, the full dependency closure, and licenses/MPL-2.0.txt copied from the crate. Modified MPL files stay under MPL-2.0. License review before public release. |

The lead approved MPL-2.0 and a vendor patch of about 20 MB. No crate is
vendored or built in Steps 1–6. Add an `rmp` row only if Step 8 needs the
fallback pin from `VERSIONS`. Filter lists are data owned by the feature plan.
