import {OWNER,mime,headers,inbound} from './mail.js';
import {verifyAddress} from './email-check.js';
export class Gmail {
 constructor(token,fetcher=fetch){this.token=token;this.fetcher=fetcher;}
 async request(path,options={}){const response=await this.fetcher('https://gmail.googleapis.com/gmail/v1/users/me/'+path,{...options,headers:{Authorization:'Bearer '+this.token,'Content-Type':'application/json'},signal:AbortSignal.timeout(10000)});if(!response.ok){const error=Error('gmail_'+response.status);error.status=response.status;throw error;}return response.json();}
 async list(query,pageToken,max=25){return this.request('messages?'+new URLSearchParams({q:query,maxResults:String(max),includeSpamTrash:'true',...(pageToken?{pageToken}:{})}));}
 async message(id){return this.request('messages/'+encodeURIComponent(id)+'?format=full');}
 async thread(id){return this.request('threads/'+encodeURIComponent(id)+'?format=full');}
 async send(raw,threadId){return this.request('messages/send',{method:'POST',body:JSON.stringify({raw,...(threadId?{threadId}:{})})});}
}
export class Engine {
 constructor(db,gmail){this.db=db;this.gmail=gmail;this.token=null;this.started=Date.now();}
 async rpc(name,args={}){const {data,error}=await this.db.rpc(name,args);if(error)throw Error('database_'+name);return data;}
 async result(query){const {data,error}=await query;if(error)throw Error('database_write');return data;}
 async runtime(){const rows=await this.result(this.db.from('outreach_runtime').select('*').eq('id',true));return rows[0];}
 async updateRuntime(values){const rows=await this.result(this.db.from('outreach_runtime').update(values).eq('id',true).eq('lease_token',this.token).gt('lease_until',new Date().toISOString()).select('id'));if(rows.length!==1)throw Error('lease_expired');}
 budget(){if(Date.now()-this.started>45000)throw Error('tick_time_budget');}
 async ingest(message,jobId=null){const parsed=inbound(message);if(parsed)await this.rpc('bloxflow_ingest_reply',{p_message:parsed,p_job:jobId});return parsed;}
 async sync(runtime){
  if(!runtime.history_id){
   let anchor=runtime.bootstrap_history;
   if(!anchor){anchor=(await this.gmail.request('profile')).historyId;await this.updateRuntime({bootstrap_history:anchor});}
   const page=await this.gmail.list('newer_than:30d -in:sent -in:drafts',runtime.bootstrap_page);
   for(const item of page.messages||[]){this.budget();await this.ingest(await this.gmail.message(item.id));}
   if(page.nextPageToken){await this.updateRuntime({bootstrap_page:page.nextPageToken});return false;}
   await this.updateRuntime({history_id:anchor,bootstrap_page:null,bootstrap_history:null,last_sync_at:new Date().toISOString()});return true;
  }
  let cursor=null,last=runtime.history_id,seen=new Set();
  try{do{const page=await this.gmail.request('history?'+new URLSearchParams({startHistoryId:runtime.history_id,historyTypes:'messageAdded',maxResults:'100',...(cursor?{pageToken:cursor}:{})}));for(const change of page.history||[]){for(const addition of change.messagesAdded||[]){if(!seen.has(addition.message.id)){this.budget();seen.add(addition.message.id);await this.ingest(await this.gmail.message(addition.message.id));}}}last=page.historyId;cursor=page.nextPageToken;}while(cursor);
  }catch(error){if(error.status===404){await this.updateRuntime({history_id:null,bootstrap_page:null,bootstrap_history:null,last_sync_at:null});return false;}throw error;}
  await this.updateRuntime({history_id:last,last_sync_at:new Date().toISOString()});return true;
 }
 async reconcile(){const attempts=await this.result(this.db.from('outreach_attempts').select('id,message_id,created_at,state').in('state',['reserved','dispatching','uncertain']).lt('created_at',new Date(Date.now()-180000).toISOString()).limit(5));
  for(const a of attempts){this.budget();if(a.state==='reserved'){await this.result(this.db.from('outreach_attempts').update({state:'cancelled',error_code:'interrupted_before_dispatch'}).eq('id',a.id).eq('state','reserved'));const rows=await this.result(this.db.from('outreach_attempts').select('job_id').eq('id',a.id));await this.result(this.db.from('outreach_jobs').update({status:'queued'}).eq('id',rows[0].job_id).eq('status','reserved'));continue;}
   const page=await this.gmail.list('in:sent rfc822msgid:'+a.message_id.replace(/[<>]/g,''),null,2);
   if(page.messages?.length===1){const m=await this.gmail.message(page.messages[0].id);await this.rpc('bloxflow_record_sent',{p_attempt:a.id,p_gmail:m.id,p_thread:m.threadId,p_at:new Date(Number(m.internalDate)).toISOString()});}
   else {await this.result(this.db.from('outreach_attempts').update({state:'uncertain',error_code:'delivery_not_confirmed'}).eq('id',a.id).in('state',['dispatching','uncertain']));const rows=await this.result(this.db.from('outreach_attempts').select('job_id').eq('id',a.id));await this.result(this.db.from('outreach_jobs').update({status:'uncertain',stop_reason:'delivery_not_confirmed'}).eq('id',rows[0].job_id).in('status',['reserved','queued']));}
  }
 }
 async preflight(job){let blocked=false;const process=async messages=>{for(const m of messages||[])if(await this.ingest(m,job.id))blocked=true;};
  // Read the entire thread immediately before follow-up, including messages from other senders.
  if(job.thread_id){const thread=await this.gmail.thread(job.thread_id);await process(thread.messages);}
  // Exact address across all time, not only since the current enrollment. Never resend to an older respondent.
  const queries=['-in:sent -in:drafts {from:'+job.recipient+' to:'+job.recipient+'}'];
  const domain=job.identity_keys.find(k=>k.startsWith('domain:'))?.slice(7);const safeCompany=job.company_name.replace(/["\\{}()\r\n]/g,' ').trim();
  if(domain)queries.push('-in:sent -in:drafts "'+domain+'"');
  if(safeCompany.length>=4)queries.push('-in:sent -in:drafts "'+safeCompany+'"');
  for(const query of queries){let cursor;do{this.budget();const page=await this.gmail.list(query,cursor,25);for(const m of page.messages||[])await process([await this.gmail.message(m.id)]);cursor=page.nextPageToken;}while(cursor);}
  return !blocked;
 }
 async verifyPending(){const rows=await this.result(this.db.from('prospects').select('id,website_url,email,updated_at').eq('review_status','approved').eq('previously_contacted',false).eq('email_verified',false).is('archived_at',null).eq('send_blocker','campaign_not_approved').order('approved_at').limit(1));
 for(const p of rows){this.budget();const evidence=await verifyAddress(p.website_url,p.email);await this.rpc('bloxflow_email_evidence',{p_id:p.id,p_expected:p.updated_at,p_verified:evidence.verified,p_url:evidence.url||null,p_status:evidence.status});}}
 async run(){this.token=await this.rpc('bloxflow_worker_lock');if(!this.token)return {status:'busy'};
  try{
   const runtime=await this.runtime();const complete=await this.sync(runtime);if(!complete)return {status:'syncing'};
   await this.reconcile();await this.verifyPending();this.budget();const candidate=await this.rpc('bloxflow_reserve',{p_token:this.token});if(!candidate){await this.updateRuntime({last_error:null});return {status:'checked'};}
   const {job,attempt}=candidate;
   try{if(!await this.preflight(job)){await this.result(this.db.from('outreach_attempts').update({state:'cancelled',error_code:'reply_found'}).eq('id',attempt.id).eq('state','reserved'));return {status:'reply_stopped'};}
    this.budget();const raw=mime({to:job.recipient,step:attempt.step,messageId:attempt.message_id,parentId:job.parent_message_id});
    if(!await this.rpc('bloxflow_before_send',{p_token:this.token,p_attempt:attempt.id}))return {status:'blocked'};
    // Exactly one send call. Network failures/HTTP errors are never blindly retried.
    let sent;try{sent=await this.gmail.send(raw,job.thread_id);}catch{await this.result(this.db.from('outreach_attempts').update({state:'uncertain',error_code:'gmail_outcome_unknown'}).eq('id',attempt.id).eq('state','dispatching'));await this.result(this.db.from('outreach_jobs').update({status:'uncertain',stop_reason:'gmail_outcome_unknown'}).eq('id',job.id).eq('status','reserved'));throw Error('gmail_outcome_unknown');}
    await this.rpc('bloxflow_record_sent',{p_attempt:attempt.id,p_gmail:sent.id,p_thread:sent.threadId,p_at:new Date().toISOString()});await this.updateRuntime({last_error:null});return {status:'sent'};
   }catch(error){await this.result(this.db.from('outreach_attempts').update({state:'cancelled',error_code:'preflight_incomplete'}).eq('id',attempt.id).eq('state','reserved'));await this.result(this.db.from('outreach_jobs').update({status:'queued'}).eq('id',job.id).eq('status','reserved'));throw error;}
  }catch(error){await this.updateRuntime({last_error:String(error.message).replace(/[^a-zA-Z0-9_]/g,'').slice(0,100)});return {status:'paused_on_error'};}
  finally{await this.result(this.db.from('outreach_runtime').update({lease_until:null,lease_token:null}).eq('id',true).eq('lease_token',this.token));}
 }
}
