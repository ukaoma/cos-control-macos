// Exercise startup and late owner resolution without a browser or live data.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const root = path.join(__dirname, '../Resources/memories');
const page = fs.readFileSync(path.join(root, 'memories-app.js'), 'utf8');
const source = fs.readFileSync(path.join(root, 'memory-workspace.js'), 'utf8');
const focusFunction = page.slice(page.indexOf('  function chooseDefaultFocus()'), page.indexOf('  // While the ingest lock'));
const initialFocus = vm.runInNewContext(page.match(/graphFocus: ([^,]+), graphFocusChosen:/)[1]);
const flush = () => new Promise(resolve => setImmediate(resolve));

function element() {
  return {textContent:'', value:'', roles:{}, listeners:{}, children:[], dataset:{},
    setAttribute(){}, removeAttribute(){}, querySelectorAll(){return [];},
    addEventListener(name, fn){(this.listeners[name] ||= []).push(fn);},
    appendChild(child){this.children.push(child);return child;},
    replaceChildren(...children){this.children=children;},
    querySelector(selector){const key=selector.match(/data-role="([^"]+)/)[1];return this.roles[key] ||= element();}
  };
}
function fixture({statusFails=false, missing=false, onUserIntent,overview=false}={}) {
  const calls=[], toasts=[], elements=[];
  const context={window:{},crypto,document:{createElement(){const el=element();elements.push(el);return el;}},
    COSGraphExplorer:{mount(_host,opts){let data=opts.data;return {snapshot:()=>data,replaceData(d){data=d;}};}}};
  vm.runInNewContext(source,context);
  const workspace=context.window.COSMemoryWorkspace.create({onUserIntent,toast:m=>toasts.push(m),call:async(route,args)=>{
    calls.push({route,...args});
    if(route==='graph.entity')return {found:true,id:args.id,neighbors:[],edges:[]};
    if(args.action==='status'){if(statusFails)throw new Error('old server');return {protocol:1,capabilities:overview?['graph_overview']:[]};}
    if(args.action==='graph_overview')return {protocol:1,nodes:[{id:'Real indexed point'}],links:[],generation:'fixture'};
    if(missing)return {protocol:1,error:{code:'entity_not_found'}};
    return {protocol:1,nodes:[{id:args.id}],links:[],generation:'fixture',next_offset:null};
  }});
  return {workspace,calls,toasts,el:elements[0]};
}
async function main(){
  assert.equal(initialFocus,null,'First visit must not invent an entity');
  let f=fixture();f.workspace.attach(element(),initialFocus);await flush();
  assert.deepEqual(f.calls.map(c=>c.action),['status']);
  assert.match(f.el.roles['overview-status'].textContent,/Update the server/);
  f.workspace.attach(element(),'Chosen point');await flush();
  assert.deepEqual(f.calls.map(c=>c.action),['status','graph_expand']);
  assert.equal(f.workspace.snapshot().nodes[0].id,'Chosen point');
  const beforePaths=f.calls.length;
  const pathButton={dataset:{action:'paths'}};
  f.el.contains=()=>true;
  f.el.listeners.click[1]({target:{closest:()=>pathButton}});await flush();
  assert.equal(f.calls.length,beforePaths,'Incomplete anchors must not reach the server');
  assert.equal(f.toasts.at(-1),'Choose different start and target points first.');

  f=fixture({missing:true});f.workspace.attach(element(),'Missing');await flush();
  assert.equal(f.calls.some(c=>c.route==='graph.entity'),false,'A missing entity is not a protocol failure');
  assert.deepEqual(f.toasts,['entity_not_found']);
  f=fixture({statusFails:true});f.workspace.attach(element(),'Existing');await flush();
  assert.equal(f.calls[1].route,'graph.entity','Older server retains legacy browsing');
  assert.equal(f.workspace.snapshot().nodes[0].id,'Existing');
  f=fixture({statusFails:true});f.workspace.attach(element(),null);await flush();
  f.workspace.attach(element(),'Chosen later');await flush();
  assert.equal(f.calls.at(-1).route,'graph.entity','Ownerless old server must honor its Find points guidance');
  assert.equal(f.workspace.snapshot().nodes[0].id,'Chosen later');

  for(const action of ['new','open']){
    const state={status:{ownerName:'Owner'},graphFocus:initialFocus,graphFocusChosen:false,view:'knowledge',knowledgeTab:'graph'};
    let resolve;
    vm.runInNewContext(focusFunction+';chooseDefaultFocus();',{state,call:()=>new Promise(r=>resolve=r),render(){}});
    // The actual capture listener must fence any explicit toolbar action.
    f=fixture({onUserIntent(){state.graphFocusChosen=true;}});
    const button={dataset:{action}};
    f.el.listeners.click[0]({target:{closest:()=>button}});
    resolve({items:[{id:'Owner',type:'person'}]});await flush();
    assert.equal(state.graphFocus,null,action+' must win over delayed owner lookup');
  }
  const state={status:{ownerName:'Owner'},graphFocus:initialFocus,graphFocusChosen:false,view:'knowledge',knowledgeTab:'graph'};
  vm.runInNewContext(focusFunction+';chooseDefaultFocus();',{state,call:async()=>({items:[{id:'Owner',type:'person'}]}),render(){}});
  await flush();assert.equal(state.graphFocus,'Owner','Owner default remains available before user interaction');
  f=fixture({overview:true});f.workspace.attach(element(),null);await flush();
  assert.equal(f.workspace.snapshot().nodes[0].id,'Real indexed point','Ownerless first visit loads actual index data');
  assert.equal(f.calls.filter(c=>c.action==='graph_overview').length,1);
  f.workspace.attach(element(),null);await flush();assert.equal(f.calls.filter(c=>c.action==='graph_overview').length,1,'Rerenders reuse overview');
  const token=f.workspace.questionToken();
  const plan={nodes:[{id:'Answer point'}],links:[],anchors:['Answer point'],generation:'fixture',filters:{hops:3,direction:'undirected',avoid:[]}};
  assert.equal(f.workspace.applyQuestion(plan,token),true);
  assert.equal(f.workspace.snapshot().anchors[0],'Answer point');
  assert.equal(f.workspace.applyQuestion(plan,token),false,'A stale question cannot overwrite newer canvas state');
  const intentToken=f.workspace.questionToken();f.el.listeners.input[0]({});
  assert.equal(f.workspace.applyQuestion(plan,intentToken),false,'Manual input fences delayed graph answers');
  console.log('Memory workspace startup, protocol fallback and late-owner intent tests passed');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
