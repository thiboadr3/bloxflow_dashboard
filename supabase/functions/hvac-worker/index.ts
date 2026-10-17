import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
const OWNER='thibo@bloxflow.be';
const SUBJECT='Korte vraag over jullie website';
const COPY=[
'Ik kwam onlangs op jullie website terecht en vroeg me af of jullie plannen hebben om die binnenkort te vernieuwen.\n\nMet Bloxflow maak ik websites voor bedrijven in de bouwsector. Als jullie daarvoor openstaan, maak ik graag vrijblijvend een demo, zodat jullie kunnen zien hoe een vernieuwde website eruit zou kunnen zien.\n\nIs dat iets waar jullie momenteel over nadenken? Meer informatie vinden jullie [hier](https://web.bloxflow.be/demo).',
'Ik wou nog even terugkomen op mijn vorige mail.\n\nLijkt het jullie interessant als ik een vrijblijvende websitedemo uitwerk? Dan zien jullie meteen hoe die eruit zou kunnen zien, zonder dat jullie vooraf iets hoeven voor te bereiden.\n\n[Hier](https://web.bloxflow.be/demo) kunnen jullie zien waaraan zo’n website voldoet.\n\nZal ik daarmee aan de slag gaan?',
'Nog een laatste berichtje over jullie website.\n\nIs een vernieuwing iets voor binnenkort, of eerder voor later? Als jullie graag eens zien wat er mogelijk is, werk ik met plezier een vrijblijvende demo uit.\n\nMeer informatie vinden jullie [hier](https://web.bloxflow.be/demo).'];
function localParts(now=new Date()) {const x=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Brussels',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(now).map(p=>[p.type,p.value]));return x;}
function greeting(now=new Date()){const p=localParts(now),m=Number(p.hour)*60+Number(p.minute);return m>=360&&m<=660?'Goedemorgen,':m>660&&m<=1050?'Goedemiddag,':'Goedenavond,';}
const signature='Groetjes,\n\nThibo Adriaenssens\n\nM: 0497 32 74 64\nE: thibo@bloxflow.be\n[web.bloxflow.be](https://web.bloxflow.be/)';
const escapeHtml=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const b64=s=>btoa(String.fromCharCode(...new TextEncoder().encode(s))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const unb64=s=>new TextDecoder().decode(Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0)));
function render(step,now=new Date()){if(!Number.isInteger(step)||step<1||step>3)throw Error('Invalid step');const body=greeting(now)+'\n\n'+COPY[step-1]+'\n\n'+signature;return {plain:body.replace(/\[([^\]]+)\]\((https:\/\/[^)]+)\)/g,'$1 ($2)'),html:escapeHtml(body).replace(/\[([^\]]+)\]\((https:\/\/[^)]+)\)/g,'<a href="$2">$1</a>').split('\n\n').map(p=>'<p>'+p.replaceAll('\n','<br>')+'</p>').join('')};}
function mime({to,step,messageId,parentId=null,now=new Date()}){if(!/^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i.test(to)||/[\r\n]/.test(to))throw Error('Invalid recipient');if(!/^<[a-zA-Z0-9._@-]+>$/.test(messageId)||parentId&&!/^<[^<>\r\n ]+>$/.test(parentId))throw Error('Invalid message id');if(step>1&&!parentId)throw Error('Missing parent');const {plain,html}=render(step,now),boundary='blox_'+crypto.randomUUID().replaceAll('-','');const headers=['From: Thibo Adriaenssens <'+OWNER+'>','To: '+to,'Subject: '+SUBJECT,'Date: '+now.toUTCString(),'Message-ID: '+messageId,'MIME-Version: 1.0',...(parentId?['In-Reply-To: '+parentId,'References: '+parentId]:[]),'Content-Type: multipart/alternative; boundary="'+boundary+'"'];return b64(headers.join('\r\n')+'\r\n\r\n'+['--'+boundary,'Content-Type: text/plain; charset=UTF-8','Content-Transfer-Encoding: base64','',b64mime(plain),'--'+boundary,'Content-Type: text/html; charset=UTF-8','Content-Transfer-Encoding: base64','',b64mime(html),'--'+boundary+'--',''].join('\r\n'));}
function b64mime(s){return btoa(String.fromCharCode(...new TextEncoder().encode(s))).match(/.{1,76}/g).join('\r\n');}
function headers(message){return Object.fromEntries((message.payload?.headers||[]).map(h=>[h.name.toLowerCase(),h.value]));}
function address(value=''){const match=value.match(/<([^>]+)>/);return (match?match[1]:value).trim().toLowerCase();}
function bodyText(payload){if(payload?.mimeType==='text/plain'&&payload.body?.data)return unb64(payload.body.data);if(payload?.mimeType==='text/html'&&payload.body?.data)return unb64(payload.body.data).replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi,'').replace(/<br\s*\/?\s*>|<\/(p|div|li)>/gi,'\n').replace(/<[^>]*>/g,'').replaceAll('&nbsp;',' ').replaceAll('&amp;','&').replaceAll('&lt;','<').replaceAll('&gt;','>').trim();const children=payload?.parts||[];const plain=children.filter(p=>p.mimeType==='text/plain').map(bodyText).filter(Boolean);if(plain.length)return plain.join('\n');return children.map(bodyText).filter(Boolean).join('\n');}
function inbound(message){const h=headers(message),from=address(h.from);if((message.labelIds||[]).includes('SENT')||from===OWNER)return null;const body=bodyText(message.payload)||message.snippet||'';let type='reply';if(/mailer-daemon|postmaster/i.test(from)||/delivery-status/.test(message.payload?.mimeType||''))type='delivery_issue';else if(/unsubscribe|uitschrijven|geen.*mails|niet meer.*(mail|contact)|verwijder.*gegevens/i.test(body))type='opt_out';else if(h['auto-submitted']&&h['auto-submitted']!=='no'||/out of office|automatisch antwoord|afwezig/i.test(h.subject||''))type='automatic_reply';return {gmail_id:message.id,thread_id:message.threadId,from_address:from,subject:h.subject||'',body_text:body.slice(0,30000),received_at:new Date(Number(message.internalDate)).toISOString(),kind:type};}

// Only accept an exact, publicly visible address; never construct an address from a domain.
function publicSite(value,base){const u=new URL(value,base);if(!['https:','http:'].includes(u.protocol)||u.username||u.password||u.port&&!['80','443'].includes(u.port))throw Error('unsupported_website');const h=u.hostname.toLowerCase();if(!/^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i.test(h)||/\.(local|localhost|internal|invalid|test|onion)$/.test(h))throw Error('private_website');return u;}
const root=u=>u.hostname.toLowerCase().replace(/^www\./,'');
function decodeHtml(s){return s.replace(/&#(x[0-9a-f]+|[0-9]+);?/gi,(_,n)=>String.fromCodePoint(parseInt(n[0].toLowerCase()==='x'?n.slice(1):n,n[0].toLowerCase()==='x'?16:10))).replaceAll('&commat;','@').replaceAll('&period;','.').replaceAll('&amp;','&');}
function hasAddress(html,email){const decoded=decodeHtml(html).toLowerCase();const escaped=email.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g,'\\$&');return new RegExp('(^|[^a-z0-9.!#$%&\'*+/=?^_`{|}~-])'+escaped+'(?=$|[^a-z0-9.-])','i').test(decoded);}
async function page(url,fetcher){const response=await fetcher(url,{redirect:'manual',headers:{'User-Agent':'Bloxflow-ContactCheck/1.0'},signal:AbortSignal.timeout(4000)});if(response.status>=300&&response.status<400){const location=response.headers.get('location');if(!location)throw Error('website_redirect');return {redirect:location};}if(!response.ok)throw Error('website_unavailable');if(!/text\/html/i.test(response.headers.get('content-type')||''))throw Error('not_html');const reader=response.body.getReader();let size=0,parts=[];try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>400000)break;parts.push(new TextDecoder().decode(value));}}finally{await reader.cancel();}return {html:parts.join('')};}
async function verifyAddress(website,email,fetcher=fetch){let start;try{start=publicSite(website);}catch{return {verified:false,status:'unsupported_website'}}let queue=[start.href],visited=new Set();let failed=false,discoveredLinks=false;
 for(let i=0;i<queue.length&&visited.size<4;i++){const u=publicSite(queue[i],start);if(root(u)!==root(start)||visited.has(u.href))continue;visited.add(u.href);try{const result=await page(u.href,fetcher);if(result.redirect){const next=publicSite(result.redirect,u);if(root(next)===root(start))queue.push(next.href);continue;}if(hasAddress(result.html,email))return {verified:true,status:'verified',url:u.href};if(!discoveredLinks){discoveredLinks=true;const links=[...result.html.matchAll(/href\s*=\s*["']([^"']+)["']/gi)].map(x=>x[1]).filter(x=>/contact|over-ons|about/i.test(x)).slice(0,8);for(const link of [...links,'/contact','/contacteer-ons']){try{const next=publicSite(decodeHtml(link),u);if(root(next)===root(start))queue.push(next.href)}catch{}}}}catch{failed=true;}}
 return {verified:false,status:failed?'website_check_failed':'email_not_found'};
}

class Gmail {
 constructor(token,fetcher=fetch){this.token=token;this.fetcher=fetcher;}
 async request(path,options={}){const response=await this.fetcher('https://gmail.googleapis.com/gmail/v1/users/me/'+path,{...options,headers:{Authorization:'Bearer '+this.token,'Content-Type':'application/json'},signal:AbortSignal.timeout(10000)});if(!response.ok){const error=Error('gmail_'+response.status);error.status=response.status;throw error;}return response.json();}
 async list(query,pageToken,max=25){return this.request('messages?'+new URLSearchParams({q:query,maxResults:String(max),includeSpamTrash:'true',...(pageToken?{pageToken}:{})}));}
 async message(id){return this.request('messages/'+encodeURIComponent(id)+'?format=full');}
 async thread(id){return this.request('threads/'+encodeURIComponent(id)+'?format=full');}
 async send(raw,threadId){return this.request('messages/send',{method:'POST',body:JSON.stringify({raw,...(threadId?{threadId}:{})})});}
}
class Engine {
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
 async preflight(job){let blocked=false;
  const process=async(message,knownThread=false)=>{const parsed=inbound(message);if(!parsed)return;const sender=parsed.from_address,domain=job.identity_keys.find(k=>k.startsWith('domain:'))?.slice(7);const related=knownThread||sender===job.recipient||domain&&sender.endsWith('@'+domain);if(related){await this.rpc('bloxflow_ingest_reply',{p_message:parsed,p_job:job.id});blocked=true;}};
  if(job.thread_id){const thread=await this.gmail.thread(job.thread_id);for(const m of thread.messages||[])await process(m,true);}
  // Search exact counterpart, then require sender/domain evidence before assigning any result.
  const queries=['-in:sent -in:drafts from:'+job.recipient];
  const domain=job.identity_keys.find(k=>k.startsWith('domain:'))?.slice(7);
  if(domain)queries.push('-in:sent -in:drafts from:(@'+domain+')');
  for(const query of queries){let cursor;do{this.budget();const page=await this.gmail.list(query,cursor,25);for(const m of page.messages||[])await process(await this.gmail.message(m.id));cursor=page.nextPageToken;}while(cursor);}
  return !blocked;
 }
 async verifyPending(){const runtime=await this.runtime();if(!runtime.campaign_started_at)return;const rows=await this.result(this.db.from('prospects').select('id,website_url,email,updated_at').eq('review_status','approved').gte('approved_at',runtime.campaign_started_at).eq('previously_contacted',false).eq('email_verified',false).is('archived_at',null).eq('send_blocker','campaign_not_approved').order('approved_at').limit(1));
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

// Sends only to the verified mailbox owner, never to a prospect. Each test id is single use.
async function selfTest(db,gmail,testId){
 if(!/^[0-9a-f-]{36}$/.test(testId))throw Error('invalid_test');
 const {data:claims,error}=await db.from('outreach_self_tests').update({status:'running'}).eq('id',testId).eq('status','reserved').select('id');
 if(error||claims?.length!==1)throw Error('test_not_reserved');
 try{let thread=null,parent=null,ids=[];
 for(let step=1;step<=3;step++){const messageId='<selftest-'+testId+'-'+step+'@outreach.bloxflow.be>';const raw=mime({to:OWNER,step,messageId,parentId:parent});const sent=await gmail.send(raw,thread);ids.push(sent.id);thread=sent.threadId;parent=messageId;const {error:e}=await db.from('outreach_self_tests').update({gmail_ids:ids,thread_id:thread}).eq('id',testId);if(e)throw Error('test_record_failed');}
 await verifySelfTest(db,gmail,testId);return {status:'self_test_passed',messages:3};
 }catch{await db.from('outreach_self_tests').update({status:'failed_or_uncertain'}).eq('id',testId);throw Error('self_test_failed');}
}

async function verifySelfTest(db,gmail,testId){
const {data:t,error}=await db.from('outreach_self_tests').select('gmail_ids,thread_id').eq('id',testId).single();if(error||t.gmail_ids?.length!==3)throw Error('test_messages_missing');
let checks=[];for(const id of t.gmail_ids){const m=await gmail.message(id),h=headers(m);const body=bodyText(m.payload);checks.push({thread:m.threadId===t.thread_id,to:!!h.to?.toLowerCase().includes(OWNER),signature:body.includes('0497 32 74 64'),link:body.includes('https://web.bloxflow.be/demo')});}
const passed=checks.every(c=>c.thread&&c.to&&c.signature&&c.link);const {error:e}=await db.from('outreach_self_tests').update({status:passed?'passed':'verification_failed',completed_at:new Date().toISOString(),checks}).eq('id',testId);if(e)throw Error('test_record_failed');return {status:passed?'self_test_passed':'verification_failed',checks};
}

// This file is bundled with mail.js and engine.js into the deployed Edge Function.
const env=name=>{const value=Deno.env.get(name);if(!value)throw Error('missing_configuration');return value;};
const db=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
const bytes=value=>Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
const digest=async value=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))).map(x=>x.toString(16).padStart(2,'0')).join('');
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response('Method not allowed',{status:405});
 try{
  const presented=req.headers.get('x-bloxflow-worker')||'';
  if(presented.length<40)return new Response('Unauthorized',{status:401});
  const {data:runtime,error}=await db.from('outreach_runtime').select('worker_token_hash').eq('id',true).single();
  if(error||!runtime.worker_token_hash||await digest(presented)!==runtime.worker_token_hash)return new Response('Unauthorized',{status:401});
  const {data:connection,error:ce}=await db.from('gmail_connections').select('refresh_token_ciphertext,refresh_token_iv,scopes').eq('email',OWNER).single();
  if(ce||!connection||!['https://www.googleapis.com/auth/gmail.readonly','https://www.googleapis.com/auth/gmail.send'].every(s=>connection.scopes.includes(s)))throw Error('gmail_not_connected');
  const raw=await crypto.subtle.digest('SHA-256',new TextEncoder().encode('bloxflow-refresh-v1:'+env('GOOGLE_CLIENT_SECRET')));
  const key=await crypto.subtle.importKey('raw',raw,'AES-GCM',false,['decrypt']);
  const refresh=new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes(connection.refresh_token_iv),additionalData:new TextEncoder().encode(OWNER)},key,bytes(connection.refresh_token_ciphertext)));
  const tokenResponse=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:env('GOOGLE_CLIENT_ID'),client_secret:env('GOOGLE_CLIENT_SECRET'),grant_type:'refresh_token',refresh_token:refresh}),signal:AbortSignal.timeout(10000)});
  if(!tokenResponse.ok)throw Error('gmail_refresh_failed');const tokens=await tokenResponse.json();
  const gmail=new Gmail(tokens.access_token);const profile=await gmail.request('profile');if(profile.emailAddress?.toLowerCase()!==OWNER)throw Error('wrong_mailbox');
  const input=await req.json();
  const result=input.action==='verify_self_test'?await verifySelfTest(db,gmail,input.test_id):input.action==='self_test'?await selfTest(db,gmail,input.test_id):await new Engine(db,gmail).run();return Response.json(result,{headers:{'Cache-Control':'no-store'}});
 }catch(error){await db.from('outreach_runtime').update({last_error:'gmail_connection_or_runtime_error',last_run_at:new Date().toISOString()}).eq('id',true);return Response.json({status:'unavailable'},{status:503});}
});
