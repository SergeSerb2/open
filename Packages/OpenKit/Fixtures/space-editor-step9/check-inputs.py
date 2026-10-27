#!/usr/bin/env python3
"""End-to-end boundary cases through space-editor-render, with no mocks."""
from pathlib import Path
import subprocess,tempfile,struct,zlib,json,sys,argparse,uuid,shutil
root=Path(__file__).resolve().parents[4]
parser=argparse.ArgumentParser(description='Exercise the real session2-pad CLI input limits with synthetic PNGs; no Arc data.')
parser.add_argument('--binary',type=Path,default=root/'Packages/OpenKit/.build/release/space-editor-render')
parser.add_argument('--out',type=Path,default=root/'.re/step9/input-limits'/str(uuid.uuid4()))
args=parser.parse_args();exe=args.binary;args.out.mkdir(parents=True,exist_ok=True)
work=Path(tempfile.mkdtemp(prefix='open-step9-limits-')); frames=work/'captures';frames.mkdir()
frame=frames/'0027-synthetic';frame.mkdir()
for i in range(511):(frames/f'entry-{i:04}').mkdir()
path=frame/'win-70352.png';raw_limit=64*1024*1024

def chunk(kind,payload):
 return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
def png(width=4096,height=4096,depth=16,chunks=4096,size=raw_limit):
 row=b'\x00'+b'\xff'*(width*4*(depth//8 if depth in (8,16) else 2));c=zlib.compressobj(1);parts=[]
 for _ in range(height):parts.append(c.compress(row))
 parts.append(c.flush());compressed=b''.join(parts)
 start=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,depth,6,0,0,0))+chunk(b'IDAT',compressed)
 end=chunk(b'IEND',b'');anc=chunks-3
 if size is None:return start+end
 empty=chunk(b'opEn',b'');pad=size-len(start)-len(end)-anc*12
 if pad<0:raise ValueError('padding below zero')
 return start+chunk(b'opEn',b'\x00'*pad)+empty*(anc-1)+end

base=png();path.write_bytes(base)
rows=[]
def run(name,expected,extra=()):
 out=args.out/name
 r=subprocess.run([str(exe),'compare','--spec','session2-pad','--capture-root',str(frames),'--out',str(out),*extra],text=True,capture_output=True)
 log=r.stdout+r.stderr;(args.out/(name+'.log')).write_text(log)
 good=expected in log and r.returncode!=0
 if name=='at-all-limits':good=good and 'white component is not a primary knob ring' in log
 rows.append({'case':name,'passed':good,'expected':expected})
 print(('PASS' if good else 'FAIL'),name,expected,flush=True)
 if not good:print(log[-1500:],flush=True)

run('at-all-limits','Input F0027 accepted: 4096x4096, decoded')
extra=frames/'extra-limit';extra.mkdir();run('entry-limit-plus-one','capture root exceeds 512 entries');extra.rmdir()
path.write_bytes(png(size=raw_limit+1));run('byte-limit-plus-one','capture PNG exceeds 67108864 bytes')
path.write_bytes(png(width=4097));run('width-limit-plus-one','capture PNG dimensions outside')
path.write_bytes(png(height=4097));run('height-limit-plus-one','capture PNG dimensions outside')
path.write_bytes(png(width=610,height=1020,depth=8,size=None));run('minimum-dimensions','Input F0027 accepted: 610x1020, decoded')
path.write_bytes(png(width=609,height=1020,depth=8,size=None));run('width-limit-minus-one','capture PNG dimensions outside')
path.write_bytes(png(width=610,height=1019,depth=8,size=None));run('height-limit-minus-one','capture PNG dimensions outside')
path.write_bytes(png(chunks=4097));run('chunk-limit-plus-one','capture PNG exceeds 4096 chunks')
path.write_bytes(png(depth=17,size=None));run('unsupported-depth','capture PNG must be 8-bit or 16-bit')
path.write_bytes(png(size=None)+b'X');run('trailing-byte','capture PNG has trailing data after IEND')
path.write_bytes(base);run('unknown-arguments','session2-pad requires exactly',('--unknown','1'))
path.write_bytes(b'');run('empty-image','capture PNG is empty')
saved=frames;frames=work/'empty-captures';frames.mkdir();run('empty-root','missing session-2 gate frame 27');frames=saved
(frames/'entry-0510').rmdir();dupe=frames/'0027-duplicate';dupe.mkdir();run('duplicate-frame','duplicate capture frame number')
(args.out/'results.json').write_text(json.dumps(rows,indent=2));print('BOUNDARY_RESULTS',args.out,flush=True)
shutil.rmtree(work) # Only this run's synthetic inputs, created with mkdtemp above.
sys.exit(0 if all(x['passed'] for x in rows) else 1)
