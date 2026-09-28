// Cross-layer canary: node --import <server>/node_modules/tsx/dist/esm/index.mjs Tests/WorkBoardBridgeCanary.mjs <server-root> <MU-operations/scripts>
// All task, profile, data and lock writes are contained in a newly-created disposable root.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
const serverRoot=process.argv[2], scripts=process.argv[3];
if (!serverRoot || !scripts) throw new Error("Pass server root and canonical Python scripts directory");
const root=mkdtempSync(join(tmpdir(),'cos-work-board-canary-'));
const ops=join(root,'operations');mkdirSync(join(ops,'personal','meetings','2026-09'),{recursive:true});
const taskFile=join(ops,'personal','tasks.md');writeFileSync(taskFile,'## INBOX\n- [ ] Synthetic mobile layout check — **Source:** Synthetic review — **Done when:** Preview and checks ready\n');
Object.assign(process.env,{COS_SCRIPTS_DIR:scripts,COS_OPERATIONS_DIR:ops,COS_TASK_ROOT:ops,COS_TASK_LOCK_STORE:join(root,'locks.json'),COS_DATA_DIR:join(root,'data'),COS_PROFILE_PATH:join(root,'profile.json')});
writeFileSync(process.env.COS_PROFILE_PATH,JSON.stringify({domains:['personal']}));
const {default:express}=await import(pathToFileURL(join(serverRoot,'node_modules/express/index.js')));
const {createWorkBoardRouter}=await import(pathToFileURL(join(serverRoot,'server/routes/work-board.ts')));
let listener;
const ref={recordId:'canary:meeting:one',domain:'personal',month:'2026-09',filename:'2026-09-27_Canary.md',title:'Synthetic review'};
async function start(){const app=express();app.use(express.json({limit:'16kb'}));app.use('/api',createWorkBoardRouter({resolveMeeting:async d=>({...d,recordId:d.recordId==='wrong'?'different':ref.recordId,title:ref.title})}));listener=app.listen(0,'127.0.0.1');await new Promise(r=>listener.once('listening',r));return `http://127.0.0.1:${listener.address().port}/api/work-board`;}
let url=await start();let checks=0;
async function board(){const r=await fetch(url);assert.equal(r.status,200);const b=await r.json();assert.equal(b.tasks.length,1);assert.deepEqual(b.capabilities,{version:1,writable:true});return b.tasks[0];}
async function post(action,row,extra,status=200){const r=await fetch(url+'/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({domain:row.domain,id:row.id,expectedText:row.text,expectedRevision:row.workRevision,...extra})});const b=await r.json();assert.equal(r.status,status,JSON.stringify(b));checks++;return b;}
try {
 let row=await board();const original=row.id;
 for(const phase of ['mentioned','planned','draft','built','qa','complete']){await post('stage',row,{workStage:phase});row=await board();assert.equal(row.workStage,phase);assert.equal(row.id,original);assert.equal(row.checked,phase==='complete');}
 const stale=row;await post('stage',row,{workStage:'built'});row=await board();assert.equal(row.checked,false);
 await post('stage',stale,{workStage:'qa'},409);
 await post('meeting',row,{meeting:ref});row=await board();assert.equal(row.meetingRefs[0].recordId,ref.recordId);
 const before=readFileSync(taskFile,'utf8');await post('meeting',row,{meeting:{...ref,recordId:'wrong'}},409);assert.equal(readFileSync(taskFile,'utf8'),before);
 const out=execFileSync(join(scripts,'venv/bin/python3'),[join(scripts,'cos_api_bridge.py'),'task-set-text','personal',row.id],{env:process.env,input:'Renamed synthetic task',encoding:'utf8'});assert.equal(JSON.parse(out).ok,true);row=await board();assert.notEqual(row.id,original);assert.equal(row.workIdentity,original);assert.equal(row.meetingRefs[0].recordId,ref.recordId);checks++;
 await new Promise(r=>listener.close(r));url=await start();row=await board();assert.equal(row.workStage,'built');assert.equal(row.workIdentity,original);checks++;
 console.log(JSON.stringify({passed:true,checks,canonicalWriter:true,networkRoute:true,stages:6,legacyIdPreserved:true,staleWriteRefused:true,wrongMeetingRefused:true,renameHistoryPreserved:true,restartDurability:true,productionWrites:0}));
} finally {await new Promise(r=>listener.close(r));rmSync(root,{recursive:true,force:true});}
