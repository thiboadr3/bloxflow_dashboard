import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
const source=readFileSync(new URL('../dist/werkruimte.js',import.meta.url),'utf8');
const handler=source.slice(source.indexOf('async function saveSectorCorrection('),source.indexOf("$('sectorForm').onsubmit=saveSectorCorrection;"));
function fixture({confirmed=true,readError=null}={}){
 const original={id:'a',sector_id:'hvac',company_name:'Schrijnwerker',updated_at:'old'};
 const updated={...original,sector_id:'wood',updated_at:'new',review_status:'needs_review',send_blocker:'not_approved'};
 const nodes=new Map(),calls=[];let closed=false;
 const context={busy:false,current:original,items:[original,{id:'b'}],previewReady:true,sectors:[{id:'wood',name:'SCHRIJNWERK'}],$:id=>{if(!nodes.has(id))nodes.set(id,{value:id==='correctSector'?'wood':'',close(){closed=true}});return nodes.get(id)},setBusy(value){context.busy=value},setStatus(value){context.status=value},clearNextPreview(){},db:{async rpc(name,args){calls.push(args);return{data:{saved:confirmed}}},from(){return{select(){return this},eq(){return this},async single(){return{data:updated,error:readError}}}}}};
 vm.createContext(context);vm.runInContext(handler,context);return{context,original,updated,calls,get closed(){return closed}};
}
test('sector correction keeps the same prospect and refreshes its decision version without reloading the website or queue',async()=>{const f=fixture();await f.context.saveSectorCorrection({preventDefault(){}});assert.equal(f.context.current,f.updated);assert.equal(f.context.items[0],f.updated);assert.equal(f.context.items[1].id,'b');assert.equal(f.context.current.updated_at,'new');assert.equal(f.context.previewReady,true);assert.equal(f.calls[0].p_id,'a');assert.equal(f.calls[0].p_expected_updated_at,'old');assert.equal(f.closed,true);assert.match(f.context.status,/Schrijnwerker blijft open/)});
test('unconfirmed sector write keeps original prospect',async()=>{const f=fixture({confirmed:false});await f.context.saveSectorCorrection({preventDefault(){}});assert.equal(f.context.current,f.original);assert.equal(f.closed,false);assert.equal(f.context.busy,false)});
test('failed refresh after sector write blocks stale approval',async()=>{const f=fixture({readError:Error('offline')});await f.context.saveSectorCorrection({preventDefault(){}});assert.equal(f.context.current,f.original);assert.equal(f.context.previewReady,false);assert.equal(f.closed,false);assert.equal(f.context.busy,false)});
