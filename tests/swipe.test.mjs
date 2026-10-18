import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
const source=readFileSync(new URL('../dist/werkruimte.js',import.meta.url),'utf8');
const handlers=source.slice(source.indexOf("$('swipe').addEventListener('pointerdown'"),source.indexOf('\ntry{const {data:{session}'));
function setup(busy=false){
 const nodes={},events={},decisions=[],actions=[];
 const $=id=>nodes[id]??={style:{setProperty(k,v){this[k]=v}},dataset:{},classList:{toggle(){return false},remove(){}},setAttribute(){},setPointerCapture(){},click(){actions.push(id)},addEventListener(name,fn){events[name]=fn}};
 const state={$,busy,current:{id:'fixture'},swipeStart:null,openDecision(value){decisions.push(value)},document:{addEventListener(){}},matchMedia(){return{matches:true}}};
 vm.createContext(state);vm.runInContext(handlers,state);
 function gesture(dx,dy){events.pointerdown({clientX:200,clientY:200,pointerId:1});events.pointermove({clientX:200+dx,clientY:200+dy,pointerId:1});events.pointerup({clientX:200+dx,clientY:200+dy,pointerId:1});}
 return{nodes,events,decisions,actions,state,gesture};
}
test('full-card horizontal drag shows decision colors and records one decision on release',()=>{
 for(const [x,expected,direction] of [[130,'approved','yes'],[-130,'rejected','no']]){
  const f=setup();f.events.pointerdown({clientX:200,clientY:200,pointerId:1});f.events.pointermove({clientX:200+x,clientY:205,pointerId:1});
  assert.equal(f.nodes.websiteCard.dataset.direction,direction);assert.ok(Number(f.nodes.swipeFeedback.style.opacity)>0);assert.equal(f.decisions.length,0);
  f.events.pointerup({clientX:200+x,clientY:205,pointerId:1});f.events.pointerup({clientX:200+x,clientY:205,pointerId:1});
  assert.deepEqual(f.decisions,[expected]);assert.equal(f.nodes.websiteCard.style.transform,'');
 }
});
test('up opens website and down opens menu without recording a decision',()=>{
 for(const [dy,action] of [[-120,'toggleFrame'],[120,'more']]){const f=setup();f.gesture(8,dy);assert.deepEqual(f.actions,[action]);assert.equal(f.decisions.length,0)}
});
test('short, diagonal, cancelled, non-primary and stale gestures never save',()=>{
 for(const [x,y] of [[30,0],[90,90]]){const f=setup();f.gesture(x,y);assert.equal(f.decisions.length,0);assert.equal(f.actions.length,0)}
 for(const cancel of ['pointercancel','lostpointercapture']){const f=setup();f.events.pointerdown({clientX:0,clientY:0,pointerId:1});f.events[cancel]();f.events.pointerup({clientX:150,clientY:0,pointerId:1});assert.equal(f.decisions.length,0)}
 const f=setup();f.events.pointerdown({clientX:0,clientY:0,pointerId:1});f.state.current={id:'different'};f.events.pointerup({clientX:150,clientY:0,pointerId:1});assert.equal(f.decisions.length,0);
 const n=setup();n.events.pointerdown({clientX:0,clientY:0,pointerId:2,isPrimary:false});n.events.pointerup({clientX:150,clientY:0,pointerId:2});assert.equal(n.decisions.length,0);
});
test('axis locking and pointer identity prevent accidental direction changes',()=>{
 const f=setup();f.events.pointerdown({clientX:0,clientY:0,pointerId:1});f.events.pointermove({clientX:0,clientY:30,pointerId:1});f.events.pointerup({clientX:150,clientY:30,pointerId:1});assert.equal(f.decisions.length,0);
 const g=setup();g.events.pointerdown({clientX:0,clientY:0,pointerId:1});g.events.pointerup({clientX:150,clientY:0,pointerId:2});assert.equal(g.decisions.length,0);
});
test('busy state rejects gestures; four keyboard arrows preserve navigation',()=>{
 const f=setup(true);f.gesture(150,0);assert.equal(f.decisions.length,0);
 const k=setup();for(const key of ['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'])k.events.keydown({key,preventDefault(){}});
 assert.deepEqual(k.decisions,['rejected','approved']);assert.deepEqual(k.actions,['toggleFrame','more']);
 k.events.keydown({key:'ArrowRight',repeat:true});assert.equal(k.decisions.length,2);
});
test('full surface covers iframe and controls remain separate with unique IDs',()=>{
 const html=readFileSync(new URL('../dist/werkruimte.html',import.meta.url),'utf8');assert.equal(html,readFileSync(new URL('../dist/index.html',import.meta.url),'utf8'));
 const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);assert.equal(new Set(ids).size,ids.length);
 assert.match(html,/<div id="swipe" role="region"/);assert.ok(html.indexOf('id="swipe"')<html.indexOf('class="decisions"'));
});
