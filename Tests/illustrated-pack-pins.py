#!/usr/bin/env python3
"""Pin the approved illustrated pack and its retained ambient/rollback art."""
import hashlib,json,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);pack=root/'Resources/BundledCharacters/jedi-miles-windu'
state=pack/'illustrated-v1-1-state-map.json'
assert hashlib.sha256(state.read_bytes()).hexdigest() == "028ab2db6232c90764b1af6062fe820a717872c7b9ec703d2cca54ab9ebebb8b"
approved=json.loads(state.read_text())['poses'];rows=json.loads((pack/'session-pet-states.json').read_text())['poses'];old=json.loads((root/'Resources/DefaultPet/session-pet-states.json').read_text())['poses']
for pose in set(old)-{'working','duel','trio','swarm'}: assert approved[pose]==old[pose],pose
for pose in set(rows)-{'idle','patrol','waiting','working','trio'}: assert rows[pose]==approved[pose],pose
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
assert hashlib.sha256((pack/'ambient-v2-state-map.json').read_bytes()).hexdigest()=='2e020116b0c78da9346f07091c5514c92936c1f3b84af52a6a397fb2ef306500'
motion=json.loads((root/'Tests/windu-motion-sha256.json').read_text());assert len(motion)==36
for f,digest in motion.items(): assert hashlib.sha256((pack/f).read_bytes()).hexdigest()==digest,f
# 0.5.371: Windu V25 Session 1 working (Miles 2026-11-05 "looks great lets install it"; handoff windu-motion-v25/native).
# Only the working row changed, to the pose patch's exactly; the whole map is byte-for-byte the verified local V25 map
# (0782aeae), because this source's previous map (2893c451, Motion V13) is the one V25 was built on.
assert hashlib.sha256((pack/'session-pet-states.json').read_bytes()).hexdigest()=='0782aeae343528789afd21b62dabcae2744407c2171b0541243aabc6c118d97a'
canon=lambda v:hashlib.sha256(json.dumps(v,sort_keys=True,separators=(',',':')).encode()).hexdigest()
assert canon(rows['working'])=='c4030032e5012f90f8b5db76a0240929ac0e65d7c518daff9106110c6947b4f3','working row is the V25 pose patch'
assert canon(rows['trio'])=='25488755229a0187979edb6377fc0e1d93ff4b3c4720279a9306c90507471c45','trio row'
def pngs(v): return set().union(*map(pngs,v.values())) if isinstance(v,dict) else set().union(*map(pngs,v)) if isinstance(v,list) else {v} if str(v).endswith('.png') else set()
v25=json.loads((root/'Tests/windu-v25-sha256.json').read_text());assert len(v25)==60
for f,digest in v25.items(): assert hashlib.sha256((pack/f).read_bytes()).hexdigest()==digest,f
assert pngs(rows['working'])==set(v25),'the V25 manifest (export-receipt: 20 new, 40 existing) is every file the working row references'
# 0.5.368 Motion V13.2 (files windu-motion-v13b-*) and the Session 3 V4 trio: V13 stays in the stock history so its installs
# move to V25, and every one of its files stays for rollback.
v13=json.loads((root/'Tests/windu-motion-v13-sha256.json').read_text());assert len(v13)==105
for f,digest in v13.items(): assert hashlib.sha256((pack/f).read_bytes()).hexdigest()==digest,f
v13map=[m for m in json.loads((pack/'stock-state-history.json').read_text())['maps'] if m['name']=='Windu Motion V13 \u00b7 Control 0.5.368']
assert len(v13map)==1 and v13map[0]['retainedSource']=='bundled-character' and canon(v13map[0]['state'])=='3c501206337d76052adf045ca91c89a48c25a8f25bd55ecbc8cc74dc7f3a8be3','the V13 map is in the stock history'
v13rows=v13map[0]['state']['poses']
assert canon(v13rows['working'])=='126b24408a99e530456a983182fd80c6961aeb915bc1e484c4e07149f155aa7f' and v13rows['trio']==rows['trio'],'the retained V13 rows'
assert pngs(v13rows['working'])|pngs(v13rows['trio'])==set(v13),'the V13 manifest is every file the two V13 rows reference'
for pose in set(rows)-{'working'}: assert rows[pose]==v13rows[pose],('V25 changes only working',pose)
# Motion V2 (0.5.360 to 0.5.367) stays recognized as stock so those installs move to V13; its files stay for rollback.
v2=[m for m in json.loads((pack/'stock-state-history.json').read_text())['maps'] if m['name']=='Windu Motion V2 \u00b7 Control 0.5.360']
assert len(v2)==1 and v2[0]['retainedSource']=='bundled-character' and canon(v2[0]['state'])=='b652308e6cc05a078d5e8709ffd2eed3e1880ec03e2feb731a7204ab7802fdef'
for f in pngs(v2[0]['state']): assert (pack/f).is_file(),f
prior=json.loads((pack/'ambient-v2-state-map.json').read_text())['poses']
for pose in set(rows)-{'working','trio'}: assert rows[pose]==prior[pose],pose
for pose,new,a in [('working','v13b',v13rows['working']),('trio','v4',rows['trio'])]:
 b=prior[pose]
 for key in set(a)-{'file','retina','rotation'}: assert a[key]==b[key],(pose,key)
 assert a['rotation']['handoffFrame']==b['rotation']['handoffFrame'] and a['rotation']['version']==b['rotation']['version']
 assert len(a['rotation']['variants'])==len(b['rotation']['variants']),(pose,'cast count')
 for x,y in zip(a['rotation']['variants'],b['rotation']['variants']):
  c=x['id'][-1];assert x['id']==y['id'] and x['entryFile']==y['entryFile'],(pose,'entry casts are unchanged')
  assert x['file']==f'windu-motion-{new}-{pose}-{c}-full-1x.png' and x['bodyFile']==f'windu-motion-{new}-{pose}-{c}-body-1x.png'
 assert len(a['retina']['variants'])==len(b['retina']['variants']),(pose,'retina cast count')
 for x,y in zip(a['retina']['variants'],b['retina']['variants']):
  c=x['id'][-1];assert x['id']==y['id'] and x['entryFile']==y['entryFile']
  if pose=='working':
   v=lambda kind:[f'windu-motion-v13b-working-{c}-{kind}-2x-s{i}.png' for i in range(1,5)]
   assert x['file']==v('full') and x['bodyFile']==v('body')
  else:
   # Session 3 V4 as approved: s1 full from motion V3, s3 full and body from motion V4, the rest the illustrated originals.
   assert x['file']==[f'windu-motion-v3-trio-{c}-full-2x-s1.png',y['file'][1],f'windu-motion-v4-trio-{c}-full-2x-s3.png',y['file'][3]]
   assert x['bodyFile']==[y['bodyFile'][0],y['bodyFile'][1],f'windu-motion-v4-trio-{c}-body-2x-s3.png',y['bodyFile'][3]]
 # Retina geometry: every segment is 2x the 1x cell, 512 px tall, and under the texture limits; frames stay within 256.
 cell=struct.unpack('>I',(pack/a['file']).read_bytes()[16:20])[0]//a['frames'];assert a['frames']<=256
 for x in a['retina']['variants']:
  total=0
  for f in x['file']+x['bodyFile']+x['entryFile']:
   w,h,depth,color=struct.unpack('>IIBB',(pack/f).read_bytes()[16:26]);assert h==512 and depth==8 and color==6 and w%(2*cell)==0 and w<=32760 and w*h<=16777216,f
  for kind in ['file','bodyFile','entryFile']: assert sum(struct.unpack('>I',(pack/f).read_bytes()[16:20])[0] for f in x[kind])==a['frames']*2*cell,(pose,x['id'],kind)
for pose,(count,interval,width) in {'idle':(82,.04,128),'waiting':(76,.04,160),'patrol':(8,.14,160)}.items():
 row=rows[pose];assert row['frames']==count and row['interval']==interval and row['renderScale']==1
 for filename,scale in [(row['file'],1),(row['retina']['file'][0],2)]:
  assert filename in ambient
  w,h,depth,color=struct.unpack('>IIBB',(pack/filename).read_bytes()[16:26])
  assert (w,h,depth,color)==(count*width*scale,256*scale,8,6)
  assert w<=32760 and w*h<=16777216
# Windu V25 retina geometry, as above: every 2x segment is 2x the 1x cell, 512 px tall, under the texture limits.
a=rows['working'];cell=struct.unpack('>I',(pack/a['file']).read_bytes()[16:20])[0]//a['frames']
for x in a['retina']['variants']:
 for f in x['file']+x['bodyFile']+x['entryFile']:
  w,h,depth,color=struct.unpack('>IIBB',(pack/f).read_bytes()[16:26]);assert h==512 and depth==8 and color==6 and w%(2*cell)==0 and w<=32760 and w*h<=16777216,f
 for kind in ['file','bodyFile','entryFile']: assert sum(struct.unpack('>I',(pack/f).read_bytes()[16:20])[0] for f in x[kind])==a['frames']*2*cell,('working',x['id'],kind)
print('PASS: 204 preserved illustrated PNGs, 6 preserved ambient PNGs, 36 retimed PNGs, 60 Windu V25 PNGs (20 new, 40 existing), 105 retained Motion V13/Session 3 V4 PNGs, 13 casts, V15/348/349/Motion V2/V13 rollback, exact ambient cadence/RGBA, retina geometry')
