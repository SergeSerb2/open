#!/usr/bin/env bash
# Shared Linux CI checks for SergeSerb2/open.
# Runs identically on GitHub-hosted ubuntu-latest and on local mesh-ci Linux VMs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "==> 1. SyncServer TypeScript check/build (pinned tsrs) and end-to-end server test"
(
  cd "$ROOT/SyncServer"
  npm ci --no-audit --no-fund
  npx --yes tsrs@7.1.0-beta.tsrs5 -p tsconfig.json
  node scripts/e2e-server-test.mjs
)

echo "==> 2. Shell script syntax checks"
bash -n \
  tools/build.sh \
  tools/release.sh \
  tools/fetch-cef.sh \
  tools/fetch-engine.sh \
  tools/fetch-adblock-lists.sh \
  tools/embed-cef.sh \
  tools/embed-adblock.sh \
  tools/verify-all.sh \
  tools/machine/heavy.sh \
  tools/machine/queue.sh \
  tools/ci/run-linux-checks.sh \
  tools/ci/install-m5-release-daemon.sh

echo "==> 3. Python syntax checks (CI & release tooling)"
python3 -B -c '
import ast, pathlib, sys
for p in sys.argv[1:]:
    ast.parse(pathlib.Path(p).read_text(encoding="utf-8"), filename=p)
' \
  tools/ci/check-release-relevant.py \
  tools/ci/plan-release.py \
  tools/ci/release-orchestrator.py \
  tools/ci/release-daemon.py \
  tools/generate-acknowledgements.py \
  tools/verification/gate.py

echo "==> 4. Release metadata & static prerequisite integrity"
python3 -B - "$ROOT" <<'PY'
import json
import plistlib
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
project_yml = (root / "project.yml").read_text(encoding="utf-8")

def get_setting(key: str) -> str:
    m = re.search(rf'^\s+{key}:\s*"?([\w.]+)"?\s*$', project_yml, re.M)
    if not m:
        raise SystemExit(f"missing {key} in project.yml")
    return m.group(1)

marketing = get_setting("MARKETING_VERSION")
build = get_setting("CURRENT_PROJECT_VERSION")
assert re.fullmatch(r"\d+\.\d+\.\d+", marketing), f"invalid MARKETING_VERSION: {marketing}"
assert re.fullmatch(r"[1-9]\d*", build), f"invalid CURRENT_PROJECT_VERSION: {build}"
assert "PRODUCT_BUNDLE_IDENTIFIER: io.github.sergeserb2.open" in project_yml
assert "app.open.browser" not in project_yml

info = plistlib.loads((root / "App/Info.plist").read_bytes())
for key in ("OpenChromiumVersion", "OpenCEFCommit", "OpenEngineStamp", "SUFeedURL", "SUPublicEDKey"):
    assert info.get(key), f"App/Info.plist missing {key}"

ent = plistlib.loads((root / "App/Open.entitlements").read_bytes())
assert not any(k.startswith("com.apple.security.cs.") for k in ent), "unexpected CS exception in App entitlements"
assert not ent.get("com.apple.security.get-task-allow"), "get-task-allow must not be in App entitlements"

for p in sorted((root / "Helper/Entitlements").glob("*.entitlements")):
    d = plistlib.loads(p.read_bytes())
    if p.name != "helper.plugin.entitlements":
        assert "com.apple.security.cs.disable-library-validation" not in d, f"unexpected DLV in {p}"

distrib = json.loads((root / "Engine/fork/official-distrib.json").read_text(encoding="utf-8"))
assert len(distrib.get("framework_sha256", "")) == 64

locales = [
    line.split("#", 1)[0].strip()
    for line in (root / "tools/release-locales.txt").read_text(encoding="utf-8").splitlines()
    if line.split("#", 1)[0].strip()
]
assert locales, "tools/release-locales.txt must list at least one locale"
print(f"Metadata OK: version={marketing} ({build}), locales={len(locales)}, engine={info['OpenEngineStamp']}")
PY

echo "==> 5. End-to-end check of CI release-relevance & version planner scripts"
python3 -B - "$ROOT" <<'PY'
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])

def run_json(*cmd: str) -> dict:
    out = subprocess.check_output(cmd, text=True)
    return json.loads(out)

# Non-release paths must be ignored
non_rel = run_json(
    sys.executable,
    str(root / "tools/ci/check-release-relevant.py"),
    "--files",
    "docs/ci-and-releases.md",
    ".github/workflows/ci.yml",
    "SyncServer/src/index.ts",
    "README.md",
)
assert non_rel["relevant"] is False, f"expected non-release, got {non_rel}"

# App / project / license changes must trigger release
for sample in ("App/AppDelegate.swift", "project.yml", "Packages/OpenKit/Package.swift", "docs/release/licenses.md"):
    rel = run_json(
        sys.executable,
        str(root / "tools/ci/check-release-relevant.py"),
        "--files",
        "docs/ci-and-releases.md",
        sample,
    )
    assert rel["relevant"] is True and sample in rel["relevant_files"], f"expected relevant for {sample}: {rel}"

# Moving a file out of App/ into docs/ must still be detected (--no-renames)
with tempfile.TemporaryDirectory(prefix="open-ci-rename-") as tmp:
    r = Path(tmp)
    subprocess.run(["git", "-C", str(r), "init", "-q", "-b", "main"], check=True)
    subprocess.run(["git", "-C", str(r), "config", "user.name", "CI"], check=True)
    subprocess.run(["git", "-C", str(r), "config", "user.email", "ci@example.com"], check=True)
    (r / "App").mkdir()
    (r / "App/Moved.swift").write_text("let moved = 1\n" * 20)
    subprocess.run(["git", "-C", str(r), "add", "."], check=True)
    subprocess.run(["git", "-C", str(r), "commit", "-q", "-m", "init"], check=True)
    (r / "docs").mkdir()
    subprocess.run(["git", "-C", str(r), "mv", "App/Moved.swift", "docs/Moved.swift"], check=True)
    subprocess.run(["git", "-C", str(r), "commit", "-q", "-m", "move"], check=True)
    moved_res = run_json(
        sys.executable,
        str(root / "tools/ci/check-release-relevant.py"),
        "--repo",
        str(r),
        "--range",
        "HEAD~1..HEAD",
    )
    assert moved_res["relevant"] is True and "App/Moved.swift" in moved_res["relevant_files"], f"rename missed: {moved_res}"

# Version planner against a synthetic appcast fixture (offline, no network needed)
with tempfile.TemporaryDirectory(prefix="open-ci-plan-") as tmp:
    feed = Path(tmp) / "appcast.xml"
    feed.write_text(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
        "<channel><item>"
        "<sparkle:version>99</sparkle:version>"
        "<sparkle:shortVersionString>0.9.9</sparkle:shortVersionString>"
        "</item></channel></rss>\n",
        encoding="utf-8",
    )
    planned = run_json(
        sys.executable,
        str(root / "tools/ci/plan-release.py"),
        "--repo",
        str(root),
        "--feed-file",
        str(feed),
        "--releases-remote-url",
        "",
        "--origin-remote-url",
        "",
    )
    assert planned["next_version"] == "0.9.10", f"unexpected next_version: {planned}"
    assert planned["next_build"] == 100, f"unexpected next_build: {planned}"
    assert planned["latest_feed_version"] == "0.9.9", f"unexpected latest_feed_version: {planned}"
    assert planned["latest_feed_build"] == 99, f"unexpected latest_feed_build: {planned}"
    assert planned["notes_bytes"] > 0

print("CI release helper end-to-end checks PASSED")
PY

echo "==> All Linux CI checks PASSED"
