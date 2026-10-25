import {OWNER,mime,headers,bodyText} from './mail.js';
// Sends only to the verified mailbox owner, never to a prospect. Each test id is single use.
export async function selfTest(db,gmail,testId){
 if(!/^[0-9a-f-]{36}$/.test(testId))throw Error('invalid_test');
 const {data:claims,error}=await db.from('outreach_self_tests').update({status:'running'}).eq('id',testId).eq('status','reserved').select('id');
 if(error||claims?.length!==1)throw Error('test_not_reserved');
 try{let thread=null,parent=null,ids=[];
 for(let step=1;step<=3;step++){const messageId='<selftest-'+testId+'-'+step+'@outreach.bloxflow.be>';const raw=mime({to:OWNER,step,messageId,parentId:parent});const sent=await gmail.send(raw,thread);ids.push(sent.id);thread=sent.threadId;parent=messageId;const {error:e}=await db.from('outreach_self_tests').update({gmail_ids:ids,thread_id:thread}).eq('id',testId);if(e)throw Error('test_record_failed');}
 await verifySelfTest(db,gmail,testId);return {status:'self_test_passed',messages:3};
 }catch{await db.from('outreach_self_tests').update({status:'failed_or_uncertain'}).eq('id',testId);throw Error('self_test_failed');}
}

export async function verifySelfTest(db,gmail,testId){
const {data:t,error}=await db.from('outreach_self_tests').select('gmail_ids,thread_id').eq('id',testId).single();if(error||t.gmail_ids?.length!==3)throw Error('test_messages_missing');
let checks=[];for(const id of t.gmail_ids){const m=await gmail.message(id),h=headers(m);const body=bodyText(m.payload);checks.push({thread:m.threadId===t.thread_id,to:!!h.to?.toLowerCase().includes(OWNER),signature:body.includes('0497 32 74 64'),link:body.includes('https://web.bloxflow.be/')});}
const passed=checks.every(c=>c.thread&&c.to&&c.signature&&c.link);const {error:e}=await db.from('outreach_self_tests').update({status:passed?'passed':'verification_failed',completed_at:new Date().toISOString(),checks}).eq('id',testId);if(e)throw Error('test_record_failed');return {status:passed?'self_test_passed':'verification_failed',checks};
}
