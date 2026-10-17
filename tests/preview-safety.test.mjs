import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
const source=readFileSync(new URL('../dist/werkruimte.js',import.meta.url),'utf8');
function setup(){
 const nodes={},callbacks=[],calls=[];
 function frame(){return {dataset:{},style:{},remove(){},setAttribute(){},cloneNode(){return frame()},removeAttribute(){},addEventListener(_,fn){this.loaded=fn},replaceWith(next){nodes.websiteFrame=next}}}
 nodes.websiteFrame=frame();nodes.previewIdentity={};
 const context={current:{id:'a',website_url:'https://a.example'},previewReady:false,previewTimer:null,nextPreview:null,prefetchTimer:null,navigator:{},items:[],mode:'review',busy:false,$:id=>nodes[id]??={disabled:false},document:{querySelectorAll(){return[]}},resetSwipe(){},clearTimeout(){},setTimeout(){},requestAnimationFrame:fn=>callbacks.push(fn),URL,closeMenu(){calls.push('closed')},db:{rpc(){calls.push('sent');return new Promise(()=>{})}},setBusy(v){context.busy=v},setStatus(){}};
 vm.createContext(context);
 vm.runInContext(source.slice(source.indexOf('function safeUrl'),source.indexOf('function syncDecisionButtons')),context);
 vm.runInContext(source.slice(source.indexOf('function syncDecisionButtons'),source.indexOf('function showMode')),context);
 vm.runInContext(source.slice(source.indexOf('function clearNextPreview'),source.indexOf('// Recovery uses')),context);
 return {context,nodes,calls,flush(){while(callbacks.length)callbacks.shift()()}};
}
test('loading website and wrong frame identity cannot write a review',async()=>{const f=setup();await f.context.openDecision('approved');assert.deepEqual(f.calls,[]);f.context.previewReady=true;f.nodes.websiteFrame.dataset.prospectId='other';await f.context.openDecision('rejected');assert.deepEqual(f.calls,[])});
test('late load of previous website never unlocks the current company',()=>{const f=setup();f.context.mountPreview({id:'a',company_name:'A'},'https://a.example');const old=f.nodes.websiteFrame;f.context.current={id:'b',website_url:'https://b.example'};f.context.mountPreview({id:'b',company_name:'B'},'https://b.example');old.loaded();f.flush();assert.equal(f.context.previewReady,false);assert.equal(f.nodes.websiteFrame.style.visibility,'');f.nodes.websiteFrame.loaded();f.flush();assert.equal(f.context.previewReady,true);assert.equal(f.nodes.previewIdentity.textContent,'B · b.example');assert.equal(f.nodes.approve.disabled,false)});
test('company change between load event and paint remains locked',()=>{const f=setup();f.context.mountPreview({id:'a',company_name:'A'},'https://a.example');f.nodes.websiteFrame.loaded();f.context.current={id:'b',website_url:'https://b.example'};f.flush();assert.equal(f.context.previewReady,false)});
test('only matching loaded company can start one save, double click is ignored',()=>{const f=setup();f.context.previewReady=true;f.nodes.websiteFrame.dataset.prospectId='a';f.context.openDecision('approved');f.context.openDecision('rejected');assert.equal(f.calls.filter(v=>v==='sent').length,1);assert.equal(f.context.busy,true)});

test('no website allows reject or later, but never approval',async()=>{const f=setup();f.context.current={id:'a',website_url:null};f.context.mountPreview({id:'a',company_name:'A'},null);assert.equal(f.nodes.approve.disabled,true);assert.equal(f.nodes.reject.disabled,false);assert.equal(f.nodes.later.disabled,false);await f.context.openDecision('approved');assert.deepEqual(f.calls,[]);f.context.openDecision('rejected');assert.equal(f.calls.filter(v=>v==='sent').length,1)});
test('saving disables navigation until completion',()=>{const f=setup(),nav=[{},{}];f.context.document.querySelectorAll=()=>nav;f.context.setBusy(true);assert.ok(nav.every(n=>n.disabled));f.context.setBusy(false);assert.ok(nav.every(n=>!n.disabled));});

test('prospect fetch excludes archived records and clears selection before awaiting database',async()=>{
 const calls=[],nodes={},$=id=>nodes[id]??={dataset:{},querySelector(){return{}}};
 for(const id of ['queue','sector','subsector'])$(id).value=id==='queue'?'needs_review':'all';$('withWebsite').checked=false;
 const query={};for(const method of ['select','eq','is','order','limit'])query[method]=(...args)=>{calls.push([method,...args]);return query};let finish;query.then=resolve=>{finish=resolve};
 const c={user:true,request:0,current:{id:'old'},items:[],setBusy(){},clearNextPreview(){},invalidatePreview(){},setStatus(){},$,db:{from(){return query}},fmt:String,showProspect(p){c.current=p}};vm.createContext(c);
 vm.runInContext(source.slice(source.indexOf('async function loadItems'),source.indexOf('function showProspect')),c);
 const loading=c.loadItems();assert.equal(c.current,null);await Promise.resolve();assert.ok(calls.some(([method,column,value])=>method==='is'&&column==='archived_at'&&value===null));finish({data:[],count:0,error:null});await loading;assert.equal(c.current,null);
});

test('prepared website is promoted in place without assigning src again',()=>{const f=setup(),frame=f.nodes.websiteFrame.cloneNode(false),p={id:'b',company_name:'B',website_url:'https://b.example'};let navigations=0;Object.defineProperty(frame,'id',{set(value){if(value==='websiteFrame')f.nodes.websiteFrame=frame}});Object.defineProperty(frame,'src',{set(){navigations++}});f.context.nextPreview={id:'b',url:p.website_url,frame,loaded:true};f.context.current=p;f.context.mountPreview(p,p.website_url);f.flush();assert.equal(f.nodes.websiteFrame,frame);assert.equal(navigations,0);assert.equal(f.context.previewReady,true);assert.equal(f.context.nextPreview,null)});
test('prepared website from another selection is removed and never reused',()=>{const f=setup();let removed=false;f.context.nextPreview={id:'other',url:'https://other.example',frame:{remove(){removed=true}}};f.context.mountPreview({id:'a',company_name:'A'},'https://a.example');assert.equal(removed,true);assert.equal(f.nodes.websiteFrame.dataset.prospectId,'a');assert.equal(f.context.previewReady,false)});
test('data saver and slow connection do not preload websites',()=>{for(const connection of [{saveData:true},{effectiveType:'2g'},{effectiveType:'slow-2g'}]){const f=setup();f.context.navigator.connection=connection;f.context.items=[f.context.current,{id:'b',website_url:'https://b.example'}];let scheduled=false;f.context.setTimeout=()=>{scheduled=true};f.context.warmNextPreview();assert.equal(scheduled,false)}});

test('new website is visible progressively before full load but approval stays locked',()=>{const f=setup();f.context.mountPreview({id:'a',company_name:'A'},'https://a.example');assert.equal(f.nodes.websiteFrame.style.visibility,'');assert.equal(f.context.previewReady,false);f.context.syncDecisionButtons();assert.equal(f.nodes.approve.disabled,true);assert.equal(f.nodes.previewLoading.hidden,false);});
