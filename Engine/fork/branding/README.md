# Open engine branding (placeholder)

Status: placeholder. No final assets. Never copy reference-browser assets
(AGENTS.md rule 1).

- Product name (user-visible): Open.
- Framework name in v1: Chromium Embedded Framework (unchanged CEF name).
  Renaming the framework is a future patch; it changes signing, helper
  lookup, and update paths. Do not rename in the fork-infra milestone.
- App bundle ID: `io.github.sergeserb2.open` (lead decision).
- Helper bundle IDs: `io.github.sergeserb2.open.helper`,
  `io.github.sergeserb2.open.helper.gpu`,
  `io.github.sergeserb2.open.helper.renderer`,
  `io.github.sergeserb2.open.helper.plugin`,
  `io.github.sergeserb2.open.helper.alerts`.
- Icons: none. `branding/icons/` stays empty (`.gitkeep`) until the designer
  delivers Open-owned icons. The build must succeed with no icon override.
- Where branding lands later (for the engine-patches plan): CEF embedder
  product override and Chromium product strings, as small hook patches.
  No branding hunk is in scope for fork-infra.

Scripts do not need bundle IDs in this milestone. Future consumers must
read `OPEN_APP_BUNDLE_ID` and log the chosen value. New engine code lives
under `//open/`. These lead decisions override the earlier placeholders.
