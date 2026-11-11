"""Stage the same capture runner on the M1 through the lead's m1.sh transport."""
import datetime
import io
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import uuid


HERE = Path(__file__).resolve().parent
TRANSPORT = Path.home() / 'Library/Caches/OpenRE/scripts/m1.sh'


def remote(argv, **kwargs):
    # SSH invokes a shell. Quote each argument once; never interpolate script
    # text, private paths or data into shell syntax.
    kwargs.setdefault('check', True)
    return subprocess.run([str(TRANSPORT), shlex.join([str(v) for v in argv])], **kwargs)


def remote_session(args):
    rulings = args.rulings.read_text()
    ready = re.search(r'(?m)^## LEAD [^\n]*M1 capture ready[^\n]*$|^M1 capture ready[.!]?$', rulings)
    holds = list(re.finditer(r'(?m)^## LEAD [^\n]*M1 screen HOLD[^\n]*$', rulings))
    clears = list(re.finditer(r'(?m)^## LEAD [^\n]*M1 clear[^\n]*$', rulings))
    if holds and (not clears or holds[-1].start() > clears[-1].start()):
        raise SystemExit('M1 not launched: lead screen HOLD remains active until M1 clear')
    if not args.prepare_only and not ready:
        raise SystemExit('M1 not launched: waiting for an explicit LEAD M1 capture ready ruling')
    if args.lock_timeout < 0:
        raise SystemExit('--lock-timeout must be nonnegative')
    home = remote(['python3', '-c', 'from pathlib import Path; print(Path.home())'], capture_output=True, text=True).stdout.strip()
    root = Path(args.remote_root) if args.remote_root else Path(home) / '.re/open-c-capture'
    if not root.is_absolute():
        raise SystemExit('--remote-root must be an absolute M1 path')
    stamp = datetime.datetime.now().astimezone().strftime('%Y%m%dT%H%M%S') + '-' + uuid.uuid4().hex[:8]
    stage = root / 'staging' / stamp
    output = root / 'runs' / stamp
    remote(['mkdir', '-p', stage, output])
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w') as bundle:
        for name in ('session.py', 'host.py', 'native.swift', 'burst.swift', 'pixels.sh', 'decode.py', 'fixture.py'):
            bundle.add(HERE / name, arcname=name, recursive=False)
        for name, data in [('script.json', args.script.read_bytes()), ('lead-rulings.txt', rulings.encode())]:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o600
            bundle.addfile(member, io.BytesIO(data))
    remote(['/usr/bin/tar', '-xf', '-', '-C', stage], input=archive.getvalue())
    heavy = Path(home) / 'Library/Caches/OpenRE/scripts/heavy.sh'
    helpers = {}
    def needs_stream(value):
        if isinstance(value, dict):
            return value.get('op') == 'burst' or any(needs_stream(v) for v in value.values())
        return isinstance(value,list) and any(needs_stream(v) for v in value)
    names = ('native','burst') if needs_stream(json.loads(args.script.read_text())) else ('native',)
    for name in names:
        digest = hashlib.sha256((HERE / (name + '.swift')).read_bytes() + b'Swift6-O').hexdigest()
        binary = root / 'helpers' / digest / name
        # Reuse only an identical source compiled by an earlier owned stage.
        # This keeps Python-only changes out of the shared build queue.
        prepare = '''import sys, pathlib, shutil
root,stage,binary,name=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),pathlib.Path(sys.argv[3]),sys.argv[4]
binary.parent.mkdir(parents=True,exist_ok=True)
if not binary.exists():
 for previous in (root/'staging').glob('*'):
  source=previous/(name+'.swift'); candidate=previous/name
  if candidate.is_file() and source.is_file() and source.read_bytes()==(stage/(name+'.swift')).read_bytes():
   shutil.copy2(candidate,binary); break
print('ready' if binary.exists() else 'compile')
'''
        status = remote(['python3', '-c', prepare, root, stage, binary, name], capture_output=True, text=True).stdout.strip()
        if status != 'ready':
            flags = ['-parse-as-library'] if name == 'burst' else []
            remote([heavy, 'xcrun', 'swiftc', '-O', '-swift-version', '6', *flags, stage / (name + '.swift'), '-o', binary])
        helpers[name] = binary
    native, burst = helpers['native'], helpers.get('burst',root/'helpers/unused-burst')
    state = json.loads(remote([native, 'state'], capture_output=True, text=True).stdout)
    launcher = args.pixel_launcher or Path(home) / 'Applications/OpenCapture.app'
    probe = stage / 'pixel-permission.log'
    launched_probe = remote(['/usr/bin/open', '-n', '-W', launcher, '--args', stage / 'pixels.sh', probe, native, 'screen-permission'], check=False)
    pixel_code = remote(['cat', str(probe)+'.rc'], capture_output=True, text=True).stdout.strip()
    pixels = json.loads(remote(['cat', probe], capture_output=True, text=True).stdout) if pixel_code == '0' else {'screenRecording': False}
    args.out.mkdir(parents=True, exist_ok=True)
    receipt = {'host': 'm1', 'stage': str(stage), 'output': str(output), 'prepare_only': args.prepare_only,
               'state': state, 'helpers':{k:str(v) for k,v in helpers.items()}, 'pixel_context': str(launcher), 'pixel_permission': pixels,
               'pixel_probe_open_exit': launched_probe.returncode, 'pixel_probe_receipt_exit': pixel_code, 'ready_ruling_found': bool(ready)}
    (args.out / 'host-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps({'host': 'm1', 'prepared': True, 'trusted': state['trusted'],
                      'screenRecording': pixels['screenRecording'], 'directScreenRecording': state['screenRecording'], 'launched': False}), flush=True)
    if args.prepare_only:
        return 0
    if not state['trusted'] or not pixels['screenRecording']:
        raise SystemExit('M1 not launched: Accessibility or Screen Recording preflight is false')
    command = ['/usr/bin/lockf', '-k', '-t', str(args.lock_timeout), '/tmp/open-onscreen-e2e.lock',
               'python3', stage / 'session.py', stage / 'script.json', '--backend', args.backend,
               '--out', output, '--native', native, '--burst-tool', burst, '--rulings', stage / 'lead-rulings.txt', '--pixel-launcher', launcher]
    # Retain failed captures and cleanup receipts too. Waiting for the lock does
    # not count toward the short block, whose clock starts in the remote runner.
    result = subprocess.run([str(TRANSPORT), shlex.join([str(v) for v in command])])
    # The screen block has ended. Movie decoding waits for the build slot and
    # never holds the on-screen lock or uses a screen/AX API.
    movies = remote(['python3', '-c', 'import pathlib,sys; print(any(pathlib.Path(sys.argv[1]).rglob("capture.mov")))', output], capture_output=True, text=True).stdout.strip()
    decode_code = 0
    if movies == 'True':
        decoded = subprocess.run([str(TRANSPORT), shlex.join(map(str,[heavy,'python3',stage/'decode.py',output]))])
        decode_code = decoded.returncode
    with subprocess.Popen([str(TRANSPORT), shlex.join(['/usr/bin/tar', '-cf', '-', '-C', str(output), '.'])], stdout=subprocess.PIPE) as source:
        extracted = subprocess.run(['/usr/bin/tar', '-xf', '-', '-C', str(args.out)], stdin=source.stdout)
        source.stdout.close()
        transfer_code = source.wait()
    if transfer_code or extracted.returncode:
        raise SystemExit('M1 evidence transfer failed; remote originals are preserved at ' + str(output))
    return result.returncode or decode_code
