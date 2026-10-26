import sys
from scipy import ndimage as nd
from PIL import Image,ImageDraw
import numpy as np,json
from pathlib import Path
root=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
pack=root/'Resources/BundledCharacters/jedi-miles-windu';rows=json.loads((pack/'session-pet-states.json').read_text())['poses']
allresults={}
for pose in ['working','duel','trio','swarm']:
 r=rows[pose];strip=Image.open(pack/r['file']);w=strip.width//r['frames'];results=[];samples=[]
 for f in range(r['frames']):
  im=strip.crop((f*w,0,(f+1)*w,256));a=np.array(im)[:,:,3];clear=a<=25
  outside=nd.binary_propagation(clear,mask=a<=235)
  fringe=outside & nd.maximum_filter(clear,size=7)
  hole=(a>25)&(a<205)&(~fringe)
  hole[1:-1,1:-1]&=(a[:-2,1:-1]>25)&(a[2:,1:-1]>25)&(a[1:-1,:-2]>25)&(a[1:-1,2:]>25)
  hole[[0,-1],:]=False;hole[:,[0,-1]]=False
  total=int(hole.sum());gated=hole.copy();labels,n=nd.label((a>25)&(a<205))
  for l in range(1,n+1):
   hm=hole&(labels==l);v=a[hm]
   if len(v)<100:continue
   counts=np.bincount(v,minlength=256);mode=int(counts.argmax());near=np.abs(v.astype(int)-mode)<=2
   if near.sum()>=len(v)*.8:gated[hm]=False
  opaque=int((a>235).sum());ys,xs=np.where(a>40);margin=int(min(xs.min(),w-1-xs.max(),ys.min(),255-ys.max()))
  ys,xs=np.where(gated);bounds=[int(xs.min()),int(ys.min()),int(xs.max()),int(ys.max())] if len(xs) else None
  result={'frame':f+1,'gated':int(gated.sum()),'opaque':opaque,'holes':total,'margin':margin,'bounds':bounds,'edge22holes':int((gated[:,:22]).sum()+(gated[:,-22:]).sum())};results.append(result)
  samples.append((im,gated))
 ranked=sorted(range(len(results)),key=lambda i:results[i]['gated'],reverse=True)[:12]
 canvas=Image.new('RGB',(w*4,286*3),(20,28,36));draw=ImageDraw.Draw(canvas)
 for k,i in enumerate(ranked):
  im,mask=samples[i];base=Image.new('RGBA',im.size,(20,28,36,255));base.alpha_composite(im);pix=np.array(base);pix[mask,:3]=[255,0,80];tile=Image.fromarray(pix)
  x=k%4*w;y=k//4*286;canvas.paste(tile,(x,y));draw.text((x+3,y+258),f"{pose} F{i+1}: {results[i]['gated']} holes",fill='white')
 canvas.save(out/f'{pose}-holes.png')
 edges=[i for i,r in enumerate(results) if r['margin']<6];canvas=Image.new('RGB',(w*6,286*((len(edges)+5)//6)),(20,28,36));draw=ImageDraw.Draw(canvas)
 for k,i in enumerate(edges):
  im,_=samples[i];base=Image.new('RGBA',im.size,(20,28,36,255));base.alpha_composite(im);x=k%6*w;y=k//6*286;canvas.paste(base,(x,y));draw.text((x+3,y+258),f'{pose} F{i+1}',fill='white')
 if edges:canvas.save(out/f'{pose}-edges.png')
 allresults[pose]=results
 print(pose,'gated',100*sum(r['gated'] for r in results)/sum(r['opaque'] for r in results),'after edge22',100*sum(r['gated']-r['edge22holes'] for r in results)/sum(r['opaque'] for r in results),'top',[(results[i]['frame'],results[i]['gated']) for i in ranked[:4]])
(out/'measurements.json').write_text(json.dumps(allresults,indent=2))
