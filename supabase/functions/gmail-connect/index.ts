// Connection only: deliberately no send API or background sender.
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
const env = (name) => { const value=Deno.env.get(name); if(!value) throw new Error('Missing configuration'); return value; };
const owner='thibo@bloxflow.be';
const scopes=['https://www.googleapis.com/auth/gmail.readonly','https://www.googleapis.com/auth/gmail.send'];
const base=env('SUPABASE_URL')+'/functions/v1/gmail-connect';
const db=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
const enc=new TextEncoder();
const b64=(bytes)=>btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const hash=async(value)=>b64(await crypto.subtle.digest('SHA-256',enc.encode(value)));
const response=(text,status=200,extra={})=>new Response(text,{status,headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff',...extra}});
const cookie=(value,age)=>'__Host-bloxflow-oauth='+value+'; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age='+age;
Deno.serve(async(req)=>{
 try {
  const url=new URL(req.url);
  if(req.method!=='GET')return response('Method not allowed',405);
  if(url.pathname.endsWith('/start')){
   const nonce=b64(crypto.getRandomValues(new Uint8Array(32)));
   const verifier=b64(crypto.getRandomValues(new Uint8Array(48)));
   const {error}=await db.from('gmail_oauth_states').insert({state_hash:await hash(nonce),verifier,expires_at:new Date(Date.now()+600000).toISOString()});
   if(error)throw Error('State storage failed');
   const auth=new URL('https://accounts.google.com/o/oauth2/v2/auth');
   auth.search=new URLSearchParams({client_id:env('GOOGLE_CLIENT_ID'),redirect_uri:base+'/callback',response_type:'code',scope:scopes.join(' '),access_type:'offline',prompt:'consent',login_hint:owner,state:nonce,code_challenge:await hash(verifier),code_challenge_method:'S256'}).toString();
   return response('',302,{'Location':auth.toString(),'Set-Cookie':cookie(nonce,600)});
  }
  if(url.pathname.endsWith('/callback')){
   const state=url.searchParams.get('state')||'';
   const browserState=(req.headers.get('cookie')||'').split(';').map(x=>x.trim()).find(x=>x.startsWith('__Host-bloxflow-oauth='))?.split('=')[1];
   if(state.length!==43||state!==browserState)return response('Ongeldige of verlopen koppeling. Open opnieuw /start.',400);
   const {data:rows,error}=await db.from('gmail_oauth_states').delete().eq('state_hash',await hash(state)).gt('expires_at',new Date().toISOString()).select('verifier');
   if(error||rows?.length!==1)return response('Koppeling verlopen of al gebruikt.',400);
   if(url.searchParams.has('error'))return response('Gmail-toestemming niet verleend. Er zijn geen mails verstuurd.',400,{'Set-Cookie':cookie('',0)});
   const code=url.searchParams.get('code'); if(!code)return response('Google-code ontbreekt.',400);
   const exchange=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:env('GOOGLE_CLIENT_ID'),client_secret:env('GOOGLE_CLIENT_SECRET'),redirect_uri:base+'/callback',grant_type:'authorization_code',code,code_verifier:rows[0].verifier})});
   if(!exchange.ok)throw Error('Google exchange failed');
   const tokens=await exchange.json();
   if(!tokens.access_token||!tokens.refresh_token||!scopes.every(s=>(tokens.scope||'').split(' ').includes(s)))throw Error('Required permission missing');
   const profileResponse=await fetch('https://gmail.googleapis.com/gmail/v1/users/me/profile',{headers:{Authorization:'Bearer '+tokens.access_token}});
   if(!profileResponse.ok)throw Error('Mailbox verification failed');
   const profile=await profileResponse.json();
   if(profile.emailAddress?.toLowerCase()!==owner){await fetch('https://oauth2.googleapis.com/revoke',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({token:tokens.refresh_token})});return response('Alleen de Bloxflow-mailbox kan gekoppeld worden.',403,{'Set-Cookie':cookie('',0)});}
   // Key stays in Supabase runtime only. Client secret rotation requires reconnect.
   const rawKey=await crypto.subtle.digest('SHA-256',enc.encode('bloxflow-refresh-v1:'+env('GOOGLE_CLIENT_SECRET')));
   const key=await crypto.subtle.importKey('raw',rawKey,'AES-GCM',false,['encrypt']);
   const iv=crypto.getRandomValues(new Uint8Array(12));
   const sealed=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:enc.encode(owner)},key,enc.encode(tokens.refresh_token));
   const {error:saveError}=await db.from('gmail_connections').upsert({email:owner,refresh_token_ciphertext:b64(sealed),refresh_token_iv:b64(iv),scopes:tokens.scope.split(' '),connected_at:new Date().toISOString(),sending_enabled:false},{onConflict:'email'});
   if(saveError)throw Error('Connection storage failed');
   const {error:settingsError}=await db.from('sending_settings').update({gmail_connected:true,paused:true}).eq('id',true);
   if(settingsError)throw Error('Settings update failed');
   return response('Gmail is gekoppeld aan Bloxflow. Verzending blijft gepauzeerd. Er zijn geen mails verstuurd. Je kunt dit venster sluiten.',200,{'Set-Cookie':cookie('',0)});
  }
  return response('Bloxflow Gmail-koppeling. Geen verzendfunctie actief. Open /start om te verbinden.');
 }catch{return response('Koppelen is niet gelukt. Er zijn geen mails verstuurd. Probeer opnieuw via /start of controleer de serverinstellingen.',503,{'Set-Cookie':cookie('',0)});}
});
