#!/usr/bin/env python3
"""Pin the approved illustrated pack and its retained ambient/rollback art."""
import hashlib,json,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);pack=root/'Resources/BundledCharacters/jedi-miles-windu'
state=pack/'illustrated-v1-1-state-map.json'
assert hashlib.sha256(state.read_bytes()).hexdigest() == "028ab2db6232c90764b1af6062fe820a717872c7b9ec703d2cca54ab9ebebb8b"
approved=json.loads(state.read_text())['poses'];rows=json.loads((pack/'session-pet-states.json').read_text())['poses'];old=json.loads((root/'Resources/DefaultPet/session-pet-states.json').read_text())['poses']
for pose in set(old)-{'working','duel','trio','swarm'}: assert approved[pose]==old[pose],pose
for pose in set(rows)-{'idle','patrol','waiting'}: assert rows[pose]==approved[pose],pose
spec={'working':(184,4,145),'duel':(148,3,109),'trio':(172,3,121),'swarm':(256,3,217)}
for pose,(frames,casts,handoff) in spec.items():
 row=rows[pose];r=row['rotation'];assert row['frames']==frames and row['interval']==.02 and r['handoffFrame']==handoff
 assert len(r['variants'])==casts and r['version']==1
 for v in r['variants']:
  for k in ['file','bodyFile','entryFile']:
   f=v[k];assert pathlib.Path(f).name==f
   data=(pack/f).read_bytes();w,h,depth,color=struct.unpack('>IIBB',data[16:26]);assert h==256 and w%frames==0 and color==6
pins=json.loads((root/'Tests/illustrated-pack-sha256.json').read_text());assert len(pins)==204
for f,digest in pins.items(): assert hashlib.sha256((pack/f).read_bytes()).hexdigest()==digest,f
assert hashlib.sha256((root/'Resources/DefaultPet/session-pet-states.json').read_bytes()).hexdigest()=='af4fc61df77344d955633563cef7b0c55fd7dc39a02753c443d26d9f16f4d134'
ambient=json.loads((root/'Tests/ambient-pack-sha256.json').read_text());assert len(ambient)==6
for f,digest in ambient.items(): assert hashlib.sha256((pack/f).read_bytes()).hexdigest()==digest,f
assert hashlib.sha256((pack/'session-pet-states.json').read_bytes()).hexdigest()=='2e020116b0c78da9346f07091c5514c92936c1f3b84af52a6a397fb2ef306500'
for pose,(count,interval,width) in {'idle':(82,.04,128),'waiting':(76,.04,160),'patrol':(8,.14,160)}.items():
 row=rows[pose];assert row['frames']==count and row['interval']==interval and row['renderScale']==1
 for filename,scale in [(row['file'],1),(row['retina']['file'][0],2)]:
  assert filename in ambient
  w,h,depth,color=struct.unpack('>IIBB',(pack/filename).read_bytes()[16:26])
  assert (w,h,depth,color)==(count*width*scale,256*scale,8,6)
  assert w<=32760 and w*h<=16777216
print('PASS: 204 preserved illustrated PNGs, 6 new ambient PNGs, 13 unchanged casts, V15 and 348 rollback, exact ambient cadence/RGBA')
