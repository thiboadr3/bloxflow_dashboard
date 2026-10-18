import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/+esm';
import {loadReviewFilters,saveReviewFilters,safeReviewStorage} from './review-state.js';
const db=createClient('https://dzygpjozhixnkbtfupqj.supabase.co','sb_publishable_928leTsuIvTdibfrugY9aw_oX4770Hg',{auth:{flowType:'pkce',detectSessionInUrl:true},global:{fetch:(input,options)=>fetch(input,{...options,cache:'no-store'})}});
const $=id=>document.getElementById(id),OWNER='thibo@bloxflow.be';let user=null,sectors=[],items=[],current=null,busy=false,request=0,mode='review',swipeStart=null,recoveryMode=false;
let previewReady=false,previewTimer,nextPreview=null,prefetchTimer;
const reviewStorage=safeReviewStorage(()=>localStorage);
let reviewFilters=loadReviewFilters(reviewStorage),filtersInitialized=false;
$('queue').value=reviewFilters.queue;$('withWebsite').checked=reviewFilters.withWebsite;
function rememberReviewFilters(){reviewFilters=saveReviewFilters(reviewStorage,{sector:$('sector').value,subsector:$('subsector').value,queue:$('queue').value,withWebsite:$('withWebsite').checked})}
let statusTimer;const setStatus=text=>{$('status').textContent=text;document.body.classList.add('showReviewStatus');clearTimeout(statusTimer);if(!/mislukt|niet bevestigd|controleer|probleem/i.test(text))statusTimer=setTimeout(()=>document.body.classList.remove('showReviewStatus'),3600)};const fmt=n=>Number(n).toLocaleString('nl-BE');
function safeUrl(value){try{const u=new URL(value);return ['https:','http:'].includes(u.protocol)?u.href:null}catch{return null}}
function syncDecisionButtons(){$('openWebsite').disabled=busy||!safeUrl(current?.website_url);['approve','reject','later'].forEach(id=>$(id).disabled=busy||!current||!previewReady||(id==='approve'&&!safeUrl(current?.website_url)))}
function invalidatePreview(){previewReady=false;clearTimeout(previewTimer);clearTimeout(prefetchTimer);resetSwipe();syncDecisionButtons()}
function setBusy(value){busy=value;['approve','reject','later','more','wrongSector','saveSector','sector','subsector','queue','withWebsite'].forEach(id=>$(id).disabled=value);document.querySelectorAll('[data-view]').forEach(button=>button.disabled=value);syncDecisionButtons()}
function showMode(view){if(view!=='review')clearNextPreview();mode=view;document.body.classList.toggle('reviewing',!!user&&!recoveryMode&&view==='review');$('reviewFilters').classList.remove('open');$('reviewFilterToggle').setAttribute('aria-expanded','false');if($('reviewNav').open)$('reviewNav').close();['review','dashboard','inbox'].forEach(id=>$(id).hidden=!user||recoveryMode||id!==view);document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===view))}
async function loadSummary(){const {data,error}=await db.rpc('bloxflow_sector_summary');if(error)throw error;sectors=data||[];const selected=filtersInitialized?$('sector').value:(reviewFilters.sector||sectors.find(s=>s.name==='HVAC')?.id||'all');filtersInitialized=true;$('sector').replaceChildren(new Option('Alle sectoren','all'));for(const s of sectors)$('sector').append(new Option(s.name+' · '+fmt(s.pending)+' open',s.id));if(selected==='all'||sectors.some(s=>s.id===selected))$('sector').value=selected;
$('sectorList').replaceChildren();for(const s of sectors){const row=document.createElement('article');row.className='sectorRow';const button=document.createElement('button');button.textContent=s.name+' →';button.onclick=async()=>{if(busy)return;$('sector').value=s.id;$('queue').value='needs_review';$('subsector').value='all';rememberReviewFilters();showMode('review');await loadSubsectors();await loadItems()};row.append(button);for(const [key,label] of [['total','Totaal'],['pending','Te beoordelen'],['approved','Goedgekeurd'],['ready','Klaar voor mail 1'],['contacted','Mail 1 verstuurd'],['replies','Antwoorden']]){const cell=document.createElement('span');cell.append(document.createTextNode(fmt(s[key])));const caption=document.createElement('small');caption.textContent=label;cell.append(caption);row.append(cell)}if(s.checking_email||s.needs_reapproval){const note=document.createElement('p');note.className='sectorNote';note.textContent=[s.checking_email?fmt(s.checking_email)+' e-mailcontroles bezig':null,s.needs_reapproval?fmt(s.needs_reapproval)+' eerdere goedkeuringen: opnieuw bevestigen':null].filter(Boolean).join(' · ');row.append(note)}$('sectorList').append(row)}}
async function loadSubsectors(){const n=++request,selected=reviewFilters.subsector;$('subsector').replaceChildren(new Option('Alle subsectoren','all'));const {data,error}=await db.rpc('bloxflow_subsectors',{p_sector:$('sector').value==='all'?null:$('sector').value,p_status:$('queue').value});if(n!==request)return;if(error)throw error;for(const label of data||[])$('subsector').append(new Option(label,label));if((data||[]).includes(selected))$('subsector').value=selected;rememberReviewFilters();}
async function loadItems(){if(!user)return;const n=++request;current=null;invalidatePreview();clearNextPreview();setBusy(true);setStatus('Prospecten ophalen…');$('prospect').hidden=true;$('websiteFrame').src='about:blank';try{let q=db.from('prospects').select('id,company_name,website_url,email,phone,subniche,sector_id,fit_reason,review_reason,review_status,previously_contacted,send_blocker,website_checked,email_verified,updated_at',{count:'exact'}).eq('review_status',$('queue').value).is('archived_at',null).order('created_at').order('id').limit(30);if($('withWebsite').checked)q=q.not('website_url','is',null).neq('website_url','');if($('sector').value!=='all')q=q.eq('sector_id',$('sector').value);if($('subsector').value!=='all')q=q.eq('subniche',$('subsector').value);const {data,error,count}=await q;if(n!==request)return;if(error)throw error;items=data||[];$('remaining').dataset.count=String(count||0);$('remaining').textContent=fmt(count||0)+' bedrijven';showProspect(items[0]||null);setStatus('Actuele voorraad · '+($('sector').selectedOptions[0]?.textContent||'Alle sectoren')+' · '+$('queue').selectedOptions[0].textContent)}catch(error){if(n===request){setStatus('Ophalen mislukt. Controleer je verbinding en probeer opnieuw.');$('empty').hidden=false;$('empty').querySelector('h1').textContent='Gegevens konden niet worden geladen.'}}finally{if(n===request)setBusy(false)}}
function showProspect(p){invalidatePreview();current=p;$('reviewCompany').textContent=p?.company_name||'Websites beoordelen';$('reviewCompany').title=p?.company_name||'';$('navCompany').textContent=p?.company_name||'Geen bedrijf geselecteerd';$('prospect').hidden=!p;$('empty').hidden=!!p;$('context').hidden=true;$('previewIdentity').textContent=p?p.company_name+' · Website laden…':'';if(!p){syncDecisionButtons();return}const sector=sectors.find(s=>s.id===p.sector_id);$('company').textContent=p.company_name;$('tags').textContent=[sector?.name,p.subniche].filter(Boolean).join(' · ');const url=safeUrl(p.website_url);mountPreview(p,url);$('websiteLink').hidden=!url;if(url)$('websiteLink').href=url;$('contactEmail').textContent=p.email||'Geen e-mailadres';$('phone').textContent=p.phone||'Niet opgegeven';$('fit').textContent=p.fit_reason||'Nog geen onderbouwing';$('priorReview').textContent=p.review_reason||'Nog niet beoordeeld';$('history').textContent=p.previously_contacted?'Bestaand Sheet-record: geblokkeerd voor nieuwe outreach. Historische verzending moet afzonderlijk gecontroleerd worden.':p.send_blocker;}
function clearNextPreview(){clearTimeout(prefetchTimer);nextPreview?.frame.remove();nextPreview=null}
function warmNextPreview(){
 clearTimeout(prefetchTimer);
 const connection=navigator.connection;if(connection?.saveData||['slow-2g','2g'].includes(connection?.effectiveType))return;
 const active=current?.id,index=items.findIndex(p=>p.id===active),p=index>=0?items[index+1]:null,url=safeUrl(p?.website_url);
 if(!p||!url)return;
 prefetchTimer=setTimeout(()=>{
  if(current?.id!==active||$('websiteFrame').dataset.prospectId!==active||mode!=='review')return;
  if(nextPreview?.id===p.id&&nextPreview.url===url)return;
  clearNextPreview();const frame=$('websiteFrame').cloneNode(false);frame.removeAttribute('src');frame.id='nextWebsiteFrame';frame.dataset.prospectId=p.id;
  frame.setAttribute('aria-hidden','true');frame.tabIndex=-1;frame.style.cssText='position:absolute;inset:0;width:100%;height:100%;border:0;visibility:hidden;pointer-events:none';
  const entry={id:p.id,url,frame,loaded:false};nextPreview=entry;
  frame.addEventListener('load',()=>{entry.loaded=true},{once:true});frame.src=url;$('websiteCard').append(frame);
 },800);
}
function mountPreview(p,url){
 const old=$('websiteFrame'),prepared=nextPreview?.id===p.id&&nextPreview.url===url?nextPreview:null;
 if(prepared)nextPreview=null;else clearNextPreview();
 const frame=prepared?.frame||old.cloneNode(false);if(!prepared)frame.removeAttribute('src');frame.dataset.prospectId=p.id;frame.style.visibility='';
 const ready=()=>{if(!url||current?.id!==p.id||$('websiteFrame')!==frame)return;requestAnimationFrame(()=>requestAnimationFrame(()=>{if(current?.id!==p.id||$('websiteFrame')!==frame)return;clearTimeout(previewTimer);frame.style.visibility='';frame.style.pointerEvents='';$('previewLoading').hidden=true;previewReady=true;$('previewIdentity').textContent=p.company_name+' · '+new URL(url).hostname;syncDecisionButtons();warmNextPreview()}))};
 frame.addEventListener('load',ready,{once:true});
 $('previewLoading').hidden=!url;$('previewLoadingText').textContent='Website van '+p.company_name+' laden…';
 if(prepared){old.remove();frame.id='websiteFrame';frame.removeAttribute('aria-hidden');frame.removeAttribute('tabindex')}else{frame.src=url||'about:blank';old.replaceWith(frame)}
 if(!url){previewReady=true;$('previewIdentity').textContent=p.company_name+' · Geen bruikbare website. Afwijzen of later bekijken.';syncDecisionButtons();return}
 previewTimer=setTimeout(()=>{if(current?.id===p.id&&$('websiteFrame')===frame&&!previewReady){$('previewIdentity').textContent=p.company_name+' · Laden duurt langer';$('previewLoadingText').textContent='De website laadt niet of blokkeert weergave. Open ze apart om verder te gaan.'}},12000);
 if(prepared?.loaded)ready();else warmNextPreview();
}
async function openDecision(value){if(busy||!current||!previewReady||$('websiteFrame').dataset.prospectId!==current.id||value==='approved'&&!safeUrl(current.website_url))return;const p=current;closeMenu();setBusy(true);setStatus('Keuze bewaren…');let saved=false;try{const {data:result,error}=await db.rpc('bloxflow_review',{p_id:p.id,p_decision:value,p_reason:null,p_website_checked:value==='approved',p_email_verified:false,p_expected_updated_at:p.updated_at});if(error)throw error;if(result?.saved!==true)throw Error('save_not_confirmed');saved=true;await animateDecision(value);items=items.filter(item=>item.id!==p.id);const number=Number($('remaining').dataset.count||0);$('remaining').dataset.count=String(Math.max(0,number-1));$('remaining').textContent=fmt(Math.max(0,number-1))+' bedrijven';const sector=sectors.find(s=>s.id===p.sector_id);if(sector){const keys={needs_review:'pending',approved:'approved',rejected:'rejected',later:'later'};const oldKey=keys[p.review_status],newKey=keys[value];if(oldKey)sector[oldKey]=Math.max(0,Number(sector[oldKey])-1);if(newKey)sector[newKey]=Number(sector[newKey])+1;const option=[...$('sector').options].find(o=>o.value===sector.id);if(option)option.textContent=sector.name+' · '+fmt(sector.pending)+' open'}if(items.length)showProspect(items[0]);else await loadItems();setStatus('Vorige keuze: '+p.company_name+' · '+(value==='approved'?'Goedgekeurd':value==='rejected'?'Afgewezen':'Bewaard voor later')+' · opgeslagen')}catch{setStatus(saved?'Keuze opgeslagen. Vernieuw de lijst om verder te gaan.':'Bewaren niet bevestigd. Je blijft bij dit bedrijf; probeer opnieuw of vernieuw de lijst.')}finally{setBusy(false)}}
// Recovery uses the already allowed /werkruimte callback; the SDK validates the PKCE link.
function showPasswordSetup(){recoveryMode=true;$('login').hidden=true;showMode('review');$('passwordSetup').hidden=false;setStatus('Stel zelf je wachtwoord in.');}
db.auth.onAuthStateChange(event=>{if(event==='PASSWORD_RECOVERY')showPasswordSetup()});
$('loginForm').onsubmit=async e=>{e.preventDefault();if($('email').value.trim().toLowerCase()!==OWNER){setStatus('Gebruik het toegelaten zakelijke account.');return}const button=e.submitter;button.disabled=true;setStatus('Aanmelden…');try{const {error}=await db.auth.signInWithPassword({email:OWNER,password:$('password').value});if(error)throw error;$('password').value='';location.replace('/werkruimte')}catch{setStatus('Aanmelden mislukt. Controleer je gegevens of kies ‘Wachtwoord instellen of vergeten’.')}finally{button.disabled=false}};
$('resetPassword').onclick=async()=>{const button=$('resetPassword');button.disabled=true;setStatus('Beveiligde link aanvragen…');try{const {error}=await db.auth.resetPasswordForEmail(OWNER,{redirectTo:location.origin+'/werkruimte'});if(error)throw error;setStatus('Link aangevraagd. Open de e-mail op dit toestel en in deze browser om je wachtwoord in te stellen.')}catch{setStatus('Link aanvragen mislukt. Wacht even en probeer opnieuw.')}finally{button.disabled=false}};
$('passwordForm').onsubmit=async e=>{e.preventDefault();const password=$('newPassword').value,confirmation=$('confirmPassword').value;if(password.length<12||password!==confirmation){$('passwordStatus').textContent='Gebruik minimaal 12 tekens en vul tweemaal hetzelfde wachtwoord in.';return}const button=e.submitter;button.disabled=true;try{const {data,error:identityError}=await db.auth.getUser();if(identityError||data.user?.email?.toLowerCase()!==OWNER)throw Error('identity');const {error}=await db.auth.updateUser({password});if(error)throw error;$('passwordForm').reset();$('passwordStatus').textContent='Wachtwoord opgeslagen. Je werkruimte wordt geopend.';location.replace('/werkruimte')}catch{$('passwordStatus').textContent='Opslaan mislukt. Gebruik een ander sterk wachtwoord of vraag een nieuwe link aan.'}finally{button.disabled=false}};
$('logout').onclick=async()=>{await db.auth.signOut();location.reload()};document.querySelectorAll('[data-view]').forEach(b=>b.onclick=async()=>{if(busy)return;showMode(b.dataset.view);if(b.dataset.view==='dashboard'&&user){try{await Promise.all([loadSummary(),loadMailState()])}catch{setStatus('Overzicht verversen mislukt.')}}if(b.dataset.view==='inbox'&&user)await loadInbox()});$('sector').onchange=async()=>{try{invalidatePreview();$('subsector').value='all';rememberReviewFilters();await loadSubsectors();await loadItems()}catch{setStatus('Sectoren ophalen mislukt. Vernieuw de pagina.')}};$('subsector').onchange=()=>{rememberReviewFilters();loadItems()};$('withWebsite').onchange=()=>{rememberReviewFilters();loadItems()};$('queue').onchange=$('sector').onchange;$('approve').onclick=()=>openDecision('approved');$('reject').onclick=()=>openDecision('rejected');$('later').onclick=()=>openDecision('later');$('showContext').onclick=()=>{$('context').hidden=false;$('contextDialog').showModal()};$('closeContext').onclick=()=>$('contextDialog').close();$('menuContext').onclick=()=>{closeMenu();$('showContext').click()};$('menuWebsite').onclick=()=>{closeMenu();$('toggleFrame').click()};$('openWebsite').onclick=()=>$('toggleFrame').click();$('openLoadingWebsite').onclick=()=>$('toggleFrame').click();$('toggleFrame').onclick=()=>{if(busy)return;const url=safeUrl(current?.website_url);if(url){window.open(url,'_blank','noopener,noreferrer');previewReady=true;$('previewLoadingText').textContent='Website apart geopend. Keer terug om '+current.company_name+' te beoordelen.';syncDecisionButtons()}};// The transparent surface captures gestures above the cross-origin website iframe.
$('swipe').addEventListener('pointerdown',e=>{
 if(busy||!current||e.isPrimary===false||(e.button!==undefined&&e.button!==0))return;
 swipeStart={x:e.clientX,y:e.clientY,id:current.id,pointer:e.pointerId,axis:null};
 $('swipe').setPointerCapture(e.pointerId);$('websiteCard').dataset.dragging='true';
});
$('swipe').addEventListener('pointermove',e=>{
 if(!swipeStart||busy||e.pointerId!==swipeStart.pointer)return;
 const dx=e.clientX-swipeStart.x,dy=e.clientY-swipeStart.y;
 if(!swipeStart.axis&&Math.max(Math.abs(dx),Math.abs(dy))>12){
  if(Math.abs(dx)>Math.abs(dy)*1.25)swipeStart.axis='x';
  else if(Math.abs(dy)>Math.abs(dx)*1.25)swipeStart.axis='y';
 }
 if(!swipeStart.axis)return;
 const horizontal=swipeStart.axis==='x',distance=horizontal?dx:dy;
 const direction=horizontal?(dx>0?'yes':'no'):(dy<0?'up':'down');
 const progress=Math.min(1,Math.abs(distance)/100),card=$('websiteCard');
 card.dataset.direction=direction;card.style.setProperty('--swipe-tint',String(progress*.2));
 card.style.transform=horizontal?`translate3d(${dx*.85}px,${dy*.12}px,0) rotate(${dx/35}deg)`:`translate3d(0,${dy*.4}px,0) scale(${1-progress*.025})`;
 $('swipeFeedback').textContent={yes:'Goedkeuren',no:'Afwijzen',up:'Website openen',down:'Menu openen'}[direction];
 $('swipeFeedback').dataset.direction=direction;$('swipeFeedback').style.opacity=String(progress);
});
$('swipe').addEventListener('pointerup',e=>{
 const start=swipeStart;
 if(!start||e.pointerId!==start.pointer)return;
 const dx=e.clientX-start.x,dy=e.clientY-start.y;
 const horizontal=Math.abs(dx)>72&&Math.abs(dx)>Math.abs(dy)*1.25;
 const vertical=Math.abs(dy)>72&&Math.abs(dy)>Math.abs(dx)*1.25;
 resetSwipe();
 if(busy||start.id!==current?.id)return;
 if(horizontal&&start.axis!=='y')openDecision(dx>0?'approved':'rejected');
 else if(vertical&&start.axis!=='x'){if(dy<0)$('toggleFrame').click();else $('more').click()}
});
$('swipe').addEventListener('pointercancel',resetSwipe);
$('swipe').addEventListener('lostpointercapture',()=>{if(swipeStart)resetSwipe()});
$('swipe').addEventListener('keydown',e=>{
 if(busy||e.repeat)return;
 if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key)){
  e.preventDefault();
  if(e.key==='ArrowUp')$('toggleFrame').click();
  else if(e.key==='ArrowDown')$('more').click();
  else openDecision(e.key==='ArrowRight'?'approved':'rejected');
 }
});
function resetSwipe(){swipeStart=null;const card=$('websiteCard');card.style.transform='';card.style.setProperty('--swipe-tint','0');delete card.dataset.dragging;delete card.dataset.direction;$('swipeFeedback').style.opacity='0';}
async function animateDecision(value){
 if(value==='later')return;
 const card=$('websiteCard'),feedback=$('swipeFeedback'),direction=value==='approved'?1:-1;
 card.dataset.direction=direction>0?'yes':'no';card.style.setProperty('--swipe-tint','.22');
 feedback.dataset.direction=card.dataset.direction;feedback.textContent=direction>0?'Goedgekeurd':'Afgewezen';feedback.style.opacity='1';
 let animation,timer;
 try{
  if(!card.animate||matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  animation=card.animate([{transform:'translateX(0) rotate(0)',opacity:1},{transform:`translateX(${direction*110}%) rotate(${direction*8}deg)`,opacity:0}],{duration:180,easing:'cubic-bezier(.22,1,.36,1)'});
  await Promise.race([animation.finished,new Promise(resolve=>{timer=setTimeout(resolve,240)})]);
 }catch{}finally{clearTimeout(timer);animation?.cancel();resetSwipe()}
}
$('reviewFilterToggle').onclick=()=>{const open=$('reviewFilters').classList.toggle('open');$('reviewFilterToggle').setAttribute('aria-expanded',String(open))};
$('reviewBack').onclick=async()=>{if(busy)return;showMode('dashboard');try{await Promise.all([loadSummary(),loadMailState()])}catch{setStatus('Overzicht verversen mislukt.')}};
document.addEventListener('keydown',e=>{if(e.key==='Escape'){$('reviewFilters').classList.remove('open');$('reviewFilterToggle').setAttribute('aria-expanded','false')}});

try{const {data:{session},error}=await db.auth.getSession();if(error)throw error;if(session){const {data,error}=await db.auth.getUser();if(error)throw error;if(data.user?.email?.toLowerCase()!==OWNER){await db.auth.signOut();throw Error('account')}user=data.user}$('login').hidden=!!user||recoveryMode;$('logout').hidden=!user;if(recoveryMode&&user){showPasswordSetup()}else if(user){await loadSummary();showMode('review');await loadSubsectors();await loadItems()}else setStatus('Aanmelden om je echte prospecten te bekijken')}catch{$('login').hidden=false;setStatus('De werkruimte is nog niet volledig geactiveerd of je sessie is verlopen. Meld opnieuw aan.');}

function closeMenu(){if($('reviewNav').open)$('reviewNav').close();$('more').setAttribute('aria-expanded','false')}
$('more').onclick=()=>{$('reviewNav').showModal();$('more').setAttribute('aria-expanded','true')};
$('closeReviewNav').onclick=closeMenu;
$('reviewNav').addEventListener('close',()=>$('more').setAttribute('aria-expanded','false'));
$('reviewNav').addEventListener('click',e=>{if(e.target===$('reviewNav'))closeMenu()});
$('navLogout').onclick=()=>$('logout').click();
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&$('reviewNav').open){closeMenu();$('more').focus()}});
$('wrongSector').onclick=()=>{if(busy||!current)return;closeMenu();$('sectorCompany').textContent=current.company_name;$('correctSector').replaceChildren(new Option('Kies de juiste sector',''));for(const s of sectors)if(s.id!==current.sector_id)$('correctSector').append(new Option(s.name,s.id));$('sectorError').textContent='';$('sectorDialog').showModal();$('correctSector').focus()};
$('cancelSector').onclick=()=>$('sectorDialog').close();
$('sectorDialog').addEventListener('cancel',e=>{if(busy)e.preventDefault()});
async function saveSectorCorrection(e){e.preventDefault();if(busy||!current||!$('correctSector').value)return;const p=current,target=$('correctSector').value;setBusy(true);$('cancelSector').disabled=true;$('sectorError').textContent='';let saved=false;try{const {data:result,error}=await db.rpc('bloxflow_change_sector',{p_id:p.id,p_sector:target,p_expected_updated_at:p.updated_at});if(error)throw error;if(result?.saved!==true)throw Error('save_not_confirmed');saved=true;const {data:updated,error:readError}=await db.from('prospects').select('*').eq('id',p.id).single();if(readError||!updated||updated.id!==p.id||updated.sector_id!==target)throw readError||Error('refresh_not_confirmed');current=updated;items=items.map(item=>item.id===p.id?updated:item);const sector=sectors.find(s=>s.id===target);$('tags').textContent=[sector?.name,updated.subniche].filter(Boolean).join(' · ');$('priorReview').textContent=updated.review_reason||'Nog niet beoordeeld';$('history').textContent=updated.previously_contacted?'Bestaand Sheet-record: geblokkeerd voor nieuwe outreach. Historische verzending moet afzonderlijk gecontroleerd worden.':updated.send_blocker;$('sectorDialog').close();setStatus('Sector aangepast naar '+(sector?.name||'de gekozen sector')+' · '+updated.company_name+' blijft open. Kies goedkeuren of afwijzen.')}catch{if(saved){previewReady=false;clearNextPreview()}$('sectorError').textContent=saved?'Sector opgeslagen, maar de actuele gegevens konden niet worden opgehaald. Vernieuw de pagina voordat je beoordeelt.':'Opslaan niet bevestigd. Het bedrijf blijft open; probeer opnieuw.'}finally{setBusy(false);$('cancelSector').disabled=false}}
$('sectorForm').onsubmit=saveSectorCorrection;

const dateLabel=value=>value?new Intl.DateTimeFormat('nl-BE',{timeZone:'Europe/Brussels',dateStyle:'short',timeStyle:'short'}).format(new Date(value)):'Nog niet uitgevoerd';
async function loadMailState(){const {data:r,error}=await db.rpc('bloxflow_mail_overview');if(error||!r){$('mailState').textContent='De maildienst is nog niet aangesloten.';$('pauseMail').disabled=true;return}$('mailState').textContent=r.enabled?'HVAC-verzending staat aan.':'HVAC-verzending staat gepauzeerd.';$('mailNumbers').textContent=fmt(r.sent_today)+' vandaag verstuurd · '+fmt(r.queued)+' in de wachtrij · '+fmt(r.replies)+' antwoorden';$('mailHealth').textContent='Inbox gecontroleerd: '+dateLabel(r.last_sync_at)+(r.last_error?' · De dienst meldt een storing; controle nodig.':'')+(r.uncertain?' · '+fmt(r.uncertain)+' verzendpogingen moeten worden gecontroleerd.':'')+(r.blocked_approved?' · '+fmt(r.blocked_approved)+' goedgekeurde bedrijven hebben nog een verzendblokkering.':'')+(!r.verified?' · Eindtest en activering zijn nog nodig.':'');$('pauseMail').disabled=!r.enabled;}
let inboxBefore=null,inboxBeforeId=null,inboxLoading=false;
async function loadInbox(append=false){if(inboxLoading)return;inboxLoading=true;$('refreshInbox').disabled=true;$('olderInbox').disabled=true;$('inboxState').textContent='Antwoorden ophalen…';try{const {data,error}=await db.rpc('bloxflow_inbox_page',{p_before:append?inboxBefore:null,p_before_id:append?inboxBeforeId:null});if(error)throw error;if(!append)$('inboxList').replaceChildren();for(const m of data||[]){const card=document.createElement('article');card.className='replyRow';const title=document.createElement('h2');title.textContent=m.company_name;const meta=document.createElement('p');meta.className='note';const types={reply:'Antwoord',opt_out:'Afmelding',delivery_issue:'Bezorgprobleem',automatic_reply:'Automatisch antwoord',ambiguous_reply:'Te controleren'};meta.textContent=(types[m.kind]||'Antwoord')+' · '+dateLabel(m.received_at)+' · Opvolging gestopt';const subject=document.createElement('p');subject.textContent=m.subject;const sender=document.createElement('p');sender.className='note';sender.textContent=m.from_address;const body=document.createElement('pre');body.textContent=m.body_text;const link=document.createElement('a');link.textContent='Open in Gmail ↗';link.target='_blank';link.rel='noopener noreferrer';link.href='https://mail.google.com/mail/u/?authuser=thibo%40bloxflow.be#all/'+encodeURIComponent(m.thread_id);card.append(title,meta,subject,sender,body,link);$('inboxList').append(card)}const rows=data||[];inboxBefore=rows.at(-1)?.received_at||null;inboxBeforeId=rows.at(-1)?.gmail_id||null;$('olderInbox').hidden=rows.length<50;$('inboxState').textContent=!append&&!rows.length?'Nog geen antwoorden uit de automatische HVAC-reeks.':'';}catch{$('inboxState').textContent='Antwoorden konden niet worden opgehaald. Controleer je verbinding; de inboxdienst moet aangesloten zijn.'}finally{inboxLoading=false;$('refreshInbox').disabled=false;$('olderInbox').disabled=false}}
$('refreshInbox').onclick=()=>loadInbox();$('olderInbox').onclick=()=>loadInbox(true);$('pauseMail').onclick=async()=>{$('pauseMail').disabled=true;const {error}=await db.rpc('bloxflow_pause_mail');if(error){setStatus('Pauzeren niet bevestigd. Probeer opnieuw.');$('pauseMail').disabled=false;return}setStatus('Verzending gepauzeerd. Een mail die al wordt verstuurd kan nog aankomen.');await loadMailState()};

window.addEventListener('pageshow',async e=>{if(e.persisted&&user&&!busy){try{await loadSummary();await loadSubsectors();await loadItems()}catch{setStatus('Actuele voorraad ophalen mislukt. Vernieuw de pagina.')}}});
