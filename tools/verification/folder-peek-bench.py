#!/usr/bin/env python3
"""Build a timing-only instrumented pinned parent and run FP10. Run through heavy.sh."""
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
REF = '2d51f14a1207c00157edb90f51459d97b7b1096b'
DEST = ROOT / '.re/s6/fp10-parent'
PROBE = ROOT / 'Packages/OpenKit/Sources/sidebar-render/FolderToggleProbe.swift'
fingerprint = hashlib.sha256(PROBE.read_bytes() + Path(__file__).read_bytes()).hexdigest()
manifest = DEST / 'fp10-manifest.json'
binary = DEST / 'Packages/OpenKit/.build/release/sidebar-render'
valid = manifest.exists() and json.loads(manifest.read_text()).get('fingerprint') == fingerprint and binary.exists()
if not valid:
    if DEST.exists(): shutil.rmtree(DEST)
    DEST.mkdir(parents=True, mode=0o700)
    archive = subprocess.Popen(['git', 'archive', REF], cwd=ROOT, stdout=subprocess.PIPE)
    subprocess.run(['tar', '-xf', '-', '-C', str(DEST)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait(): raise SystemExit('parent git archive failed')
    sources = DEST / 'Packages/OpenKit/Sources'
    shutil.copyfile(PROBE, sources / 'sidebar-render/FolderToggleProbe.swift')
    p = sources / 'sidebar-render/RenderCLI.swift'
    p.write_text(p.read_text().replace('case "bench": try Bench.run(rest)', 'case "bench": try Bench.run(rest)\n        case "plain-toggle-probe": try FolderToggleProbe.serve(rest)', 1))
    p = sources / 'OpenSidebar/SidebarView.swift'
    p.write_text(p.read_text().replace('public enum SidebarDiagnostics {', 'public enum SidebarDiagnostics {\n    public static var measuresFolderTransitions = false\n    public static var folderReconcileSeconds: Double = 0\n    public static var folderReconcileCount = 0', 1))
    p = sources / 'OpenSidebar/SpacePageView.swift'; s = p.read_text()
    a = s.index('    func syncExpansion(animated: Bool) {'); b = s.index('    // MARK: Row states', a)
    body = s[a:b].replace('''        syncingExpansion = true''', '''        syncingExpansion = true
        let measuring = SidebarDiagnostics.measuresFolderTransitions
        let started = measuring ? CACurrentMediaTime() : 0
        defer {
            if measuring {
                SidebarDiagnostics.folderReconcileSeconds += CACurrentMediaTime() - started
                SidebarDiagnostics.folderReconcileCount += 1
            }
        }''', 1)
    body = body.replace('''        pruneSelection()
    }''', '''        pruneSelection()
        if measuring { layoutSubtreeIfNeeded(); window?.displayIfNeeded(); CATransaction.flush() }
    }''', 1)
    p.write_text(s[:a] + body + s[b:])
    subprocess.run(['swift', 'build', '--package-path', str(DEST / 'Packages/OpenKit'), '-c', 'release', '-j', '6', '--product', 'sidebar-render', '-Xswiftc', '-DFP10_PARENT'], cwd=ROOT, check=True)
    manifest.write_text(json.dumps({'parent': REF, 'fingerprint': fingerprint, 'patch': 'measurement-only timer + identical portable plain probe'}, indent=2))
print('FP10 pinned parent ' + REF, flush=True)
if '--prepare-only' in sys.argv:
    print(binary)
    raise SystemExit(0)
subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'Packages/OpenKit'), '-c', 'release', '-j', '6', '--product', 'sidebar-render'], cwd=ROOT, check=True)
args = [x for x in sys.argv[1:] if x != '--prepare-only']
os.execv(str(ROOT / 'Packages/OpenKit/.build/release/sidebar-render'), ['sidebar-render', 'bench', '--rows', '1000', '--scale', '2', '--folder-peek', '50', '--parent-renderer', str(binary)] + args)
