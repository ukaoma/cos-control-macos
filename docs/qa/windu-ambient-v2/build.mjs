import fs from 'node:fs/promises';import{createRequire}from'node:module';import crypto from'node:crypto';
const req=createRequire('/Users/ukaoma/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/package.json'),sharp=req('sharp'),{createCanvas,loadImage}=req('@napi-rs/canvas');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');const receipt={version:'ambient-illustrated-v2',status:'review-only',states:{},files:[]},rows={};
for(const[state,height,w]of[['idle',310,256],['waiting',222,320]]){
 const im=await loadImage(`references/${state}-increments-v2.png`),cells=[],bounds=[];
 for(let i=0;i<8;i++){
  const cw=im.width/4,ch=im.height/2,c=createCanvas(cw,ch),g=c.getContext('2d');g.drawImage(im,i%4*cw,Math.floor(i/4)*ch,cw,ch,0,0,cw,ch);const raw=g.getImageData(0,0,cw,ch).data;
  let top=ch,bottom=0,left=cw,right=0;for(let y=0;y<ch;y++)for(let x=0;x<cw;x++)if(raw[(y*cw+x)*4+3]>220){top=Math.min(top,y);bottom=Math.max(bottom,y);left=Math.min(left,x);right=Math.max(right,x)}
  let lo=cw,hi=0;for(let y=Math.floor(top+(bottom-top)*(state==='idle'?.83:.7));y<=bottom;y++)for(let x=0;x<cw;x++)if(raw[(y*cw+x)*4+3]>220){lo=Math.min(lo,x);hi=Math.max(hi,x)}
  bounds.push({top,bottom,left,right,lo,hi});cells.push(c);
 }
 const baseScale=height/(bounds[0].bottom-bounds[0].top+1),baseWidth=(bounds[0].hi-bounds[0].lo+1)*baseScale,keys=[];
 for(let i=0;i<8;i++){
  const b=bounds[i],s=height/(b.bottom-b.top+1),c=createCanvas(w,512),g=c.getContext('2d');g.drawImage(cells[i],w/2-(b.lo+b.hi+1)/2*s,462-(b.bottom+1)*s,cells[i].width*s,cells[i].height*s);const png=c.toBuffer('image/png');await fs.writeFile(`assets/${state}-key-${i}.png`,png);keys.push(await sharp(png).raw().toBuffer());bounds[i].scale=s;
 }
 if(state==='idle'){
  const im=await loadImage('references/idle-early-turn.png'),c=createCanvas(im.width,im.height),g=c.getContext('2d');g.drawImage(im,0,0);const p=g.getImageData(0,0,c.width,c.height).data;let top=c.height,bottom=0,lo=c.width,hi=0;
  for(let y=0;y<c.height;y++)for(let x=0;x<c.width;x++)if(p[(y*c.width+x)*4+3]>220){top=Math.min(top,y);bottom=Math.max(bottom,y)}
  for(let y=Math.floor(top+(bottom-top)*.83);y<=bottom;y++)for(let x=0;x<c.width;x++)if(p[(y*c.width+x)*4+3]>220){lo=Math.min(lo,x);hi=Math.max(hi,x)}
  const scale=height/(bottom-top+1),out=createCanvas(w,512);out.getContext('2d').drawImage(im,w/2-(lo+hi+1)/2*scale,462-(bottom+1)*scale,im.width*scale,im.height*scale);const png=out.toBuffer('image/png');await fs.writeFile('assets/idle-key-8.png',png);keys.push(await sharp(png).raw().toBuffer());
 }
 // Authored pose holds, never blended double silhouettes. Return reuses the
 // reverse gesture (not reverse locomotion); the feet remain grounded.
 const seq=[...Array(state==='idle'?24:20).fill(0)];if(state==='idle')seq.push(8,8,8);for(let i=1;i<7;i++)seq.push(...Array(3).fill(i));seq.push(...Array(state==='idle'?16:20).fill(7));for(let i=6;i>0;i--)seq.push(...Array(3).fill(i));if(state==='idle')seq.push(8,8,8);
 await fs.mkdir(`frames/${state}`,{recursive:true});const frames=[];
 const aura=state==='waiting'?await loadImage('references/aura-v2.png'):null;
 for(let f=0;f<seq.length;f++){
  if(!aura){frames.push(keys[seq[f]]);continue;}
  const c=createCanvas(w,512),g=c.getContext('2d'),phase=f/seq.length,pulse=(1-Math.cos(phase*Math.PI*2))/2,idx=Math.floor(f/3)%8,cw=aura.width/4,ch=aura.height/2;
  const aw=206+18*pulse,ah=274+28*pulse;g.globalAlpha=.28+.32*pulse;
  g.drawImage(aura,idx%4*cw,Math.floor(idx/4)*ch,cw,ch,(w-aw)/2,458-ah,aw,ah);g.globalAlpha=1;g.drawImage(await loadImage('assets/'+state+'-key-'+seq[f]+'.png'),0,0);
  const png=c.toBuffer('image/png');frames.push(await sharp(png).raw().toBuffer());if(f%12===0)await fs.writeFile('frames/'+state+'/'+String(f).padStart(3,'0')+'.png',png);
 }

 for(const [factor,label]of[[1,'2x'],[.5,'1x']]){
  const fw=w*factor,fh=512*factor,strips=[];
  for(const raw of frames)strips.push(factor===1?raw:await sharp(raw,{raw:{width:w,height:512,channels:4}}).resize(fw,fh).raw().toBuffer());
  const packed=Buffer.alloc(fw*frames.length*fh*4);strips.forEach((raw,f)=>{for(let y=0;y<fh;y++)raw.copy(packed,(y*fw*frames.length+f*fw)*4,y*fw*4,(y+1)*fw*4)});
  const name=`windu-ambient-illustrated-v2-${state}-${label}.png`,png=await sharp(packed,{raw:{width:fw*frames.length,height:fh,channels:4}}).png().toBuffer();await fs.writeFile('pack/'+name,png);if(!(await sharp(png).raw().toBuffer()).equals(packed))throw Error('Packing changed pixels');receipt.files.push({name,sha256:sha(png),width:fw*frames.length,height:fh,frames:frames.length,bytes:png.length});
 }
 rows[state]={file:`windu-ambient-illustrated-v2-${state}-1x.png`,frames:frames.length,interval:.04,renderScale:1,retina:{scale:2,file:[`windu-ambient-illustrated-v2-${state}-2x.png`]}};
 const sheet=createCanvas(w*4,512*2),g=sheet.getContext('2d');g.fillStyle='#141d26';g.fillRect(0,0,sheet.width,sheet.height);for(let i=0;i<8;i++)g.drawImage(await loadImage(`assets/${state}-key-${i}.png`),i%4*w,Math.floor(i/4)*512);await fs.writeFile(`evidence/${state}-keys-dark.png`,sheet.toBuffer('image/png'));
 let changed=0;for(let p=0;p<w*512;p++){const at=p*4;if(keys[0].subarray(at,at+4).some((v,c)=>Math.abs(v-keys[7][at+c])>24))changed++}receipt.states[state]={distinctDrawings:keys.length,frames:seq.length,interval:.04,duration:seq.length*.04,poseSequence:seq,registration:bounds,changedPixelsBetweenExtremes:changed};
}
const prior=JSON.parse(await fs.readFile('../ambient-illustrated-v1/pack/ambient-rows.json','utf8'));rows.patrol=prior.patrol;for(const name of [prior.patrol.file,...prior.patrol.retina.file]){const b=await fs.readFile('../ambient-illustrated-v1/pack/'+name);await fs.writeFile('pack/'+name,b);receipt.files.push({name,sha256:sha(b),preservedFrom:'V1'})}receipt.states.patrol={distinctDrawings:8,frames:8,interval:.14,preserved:true};
await fs.mkdir('baseline',{recursive:true});await fs.writeFile('baseline/ambient-rows.json',JSON.stringify(prior,null,2));for(const row of Object.values(prior))for(const name of [row.file,...row.retina.file])await fs.copyFile('../ambient-illustrated-v1/pack/'+name,'baseline/'+name);
await fs.writeFile('pack/ambient-rows.json',JSON.stringify(rows,null,2));await fs.writeFile('evidence/export-receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify({states:receipt.states,files:receipt.files},null,2));
