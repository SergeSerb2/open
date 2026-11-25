# Open Unified Browser (Chromium Views + Preact WebUI)

Cross-platform unified version of Open targeting **Windows x64**, **Linux x64**, and **macOS arm64** from a single Chromium `156.0.8078.48` fork (zero CEF).

See [PLAN.md](PLAN.md) for the full architecture, module contracts, and milestones.

## Quick start

```bash
# 1. Build the Preact + Vite WebUI bundles
cd Unified/webui && pnpm install && pnpm run check && pnpm run build

# 2. Bootstrap Chromium 156.0.8078.48 (on a machine with >= 180 GB free, e.g. serge-pc WSL)
Unified/scripts/unified-bootstrap --root ~/open-unified-chromium

# 3. Apply Open patches, overlay src/open_unified + Rust ad-block, and copy WebUI bundles
Unified/scripts/unified-apply --root ~/open-unified-chromium

# 4. Build Linux x64 or Windows x64 (optionally using boat.dev Siso + NativeLink farm)
Unified/scripts/unified-build --root ~/open-unified-chromium --target linux-x64
Unified/scripts/unified-build --root ~/open-unified-chromium --target win-x64
Unified/scripts/unified-build --root ~/open-unified-chromium --target mac-arm64
```
