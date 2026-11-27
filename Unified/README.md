# Open Unified Browser (Chromium Views + Preact WebUI)

Cross-platform unified version of Open targeting **Windows x64**, **Linux x64**, and **macOS arm64** from a single Chromium `156.0.8078.48` fork (zero CEF).

See [PLAN.md](PLAN.md) for the full architecture, module contracts, and milestones.

## Quick start

```bash
# 1. Build the Preact + Vite WebUI bundles
cd Unified/webui && pnpm install && pnpm run check && pnpm run build

# 2. Check out Chromium 156.0.8078.48 into ~/open-unified-chromium/src via depot_tools
#    (on a machine with >= 180 GB free, e.g. serge-pc WSL):
#    mkdir -p ~/open-unified-chromium && cd ~/open-unified-chromium && fetch --nohooks chromium
#    cd src && git checkout tags/156.0.8078.48 && gclient sync -D --with_branch_heads --with_tags

# 3. Apply Open patches, overlay src/open_unified + Rust ad-block, and copy WebUI bundles
Unified/scripts/unified-apply --root ~/open-unified-chromium

# 4. Build Linux x64, Windows x64, or macOS arm64 (optionally using Unified/scripts/boat-farm.sh for remote Siso builds)
Unified/scripts/unified-build --root ~/open-unified-chromium --target linux-x64
Unified/scripts/unified-build --root ~/open-unified-chromium --target win-x64
Unified/scripts/unified-build --root ~/open-unified-chromium --target mac-arm64
```

## Packaging a macOS arm64 DMG

Use [`Unified/scripts/package-mac-dmg.sh`](scripts/package-mac-dmg.sh) on macOS arm64 to rebrand the built Chromium `.app` to `Open.app`, install Open's doorway-and-sun icon, sign inside-out with Hardened Runtime entitlements, build a compressed `UDZO` `.dmg`, notarize/staple it, and optionally publish a GitHub Pre-Release (never `--latest`, leaving the `v0.1.x` Swift/CEF release and Sparkle appcast untouched).

```bash
# Validate inputs, signing inventory, and entitlements without modifying or uploading
Unified/scripts/package-mac-dmg.sh --app ~/open-unified-chromium/src/out/OpenMacArm64/Open.app --dry-run

# Local dev/testing DMG (ad-hoc signed, skips notarization, suffixed -adhoc)
Unified/scripts/package-mac-dmg.sh --adhoc

# Developer ID signed + Apple notarized & stapled DMG
Unified/scripts/package-mac-dmg.sh \
  --version 0.2.0-unified.1 \
  --notary-profile open-notary

# Package and publish as a GitHub Pre-Release
Unified/scripts/package-mac-dmg.sh \
  --version 0.2.0-unified.1 \
  --publish-repo SergeSerb2/open-releases
```
