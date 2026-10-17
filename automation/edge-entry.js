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
