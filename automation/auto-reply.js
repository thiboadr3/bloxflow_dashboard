import {OWNER,SUBJECTS,headers,inbound,signature,escapeHtml,b64,versionFromSubject} from './mail.js';
// Deliberately narrow: unknown wording is left for the owner, never guessed by an LLM.
export function replyTop(text='') {
 return text.split(/\r?\n(?:_{3,}|-{3,}|Van:|From:|Op .+schreef:|On .+wrote:)|\n>/i)[0].trim();
}
export function softRejection(text='') {
 const top=replyTop(text).toLowerCase();
 if(top.length>1200||/uitschrij|unsubscribe|verwijder|niet meer|geen (?:verdere |volgende )?(?:mails|mailtjes|berichten)|stop|overleden|faill|gestopt|afwezig|automatisch|out of office|maar|wel interesse|bel me|bel ons|prijs\?|kost.*\?|demo.*\?/i.test(top))return false;
 const clean=top.split(/\n\s*(?:met vriendelijke|vriendelijke|mvg\b|groet|groetjes|sent from|verzonden vanaf)/i)[0]
 .replace(/^(?:(?:beste|hey|hallo|dag|goedemorgen|goedemiddag|goedenavond)[^\n]*\n\s*)/i,'').trim().replace(/\s+/g,' ');
 return /^(?:(?:we|wij|ik) (?:hebben|heb) (?:momenteel |op dit moment |nu )?geen interesse[.!]?|(?:nee[, ]+)?(?:niet is )?niet nodig[.!]?|op dit moment niet[.!]?(?: bedankt[.!]?)?|ik ben tevreden over mijn website[.!]? ik heb geen nood aan een andere[.!]?)$/i.test(clean);
}
export function replyCopy(name='') {
 return `Hey${name?' '+name:''},\n\nBedankt voor je reactie, geen probleem!\n\nMisschien handig om te weten voor de toekomst: voor een volledige website betaal je €416 per maand gedurende zes maanden.\n\nIk maak graag vrijblijvend een demo voor jullie bedrijf. Die kunnen we samen in 20 minuten bekijken, zonder voorbereiding of verplichtingen.\n\nLaat maar iets weten als je dit in de toekomst graag uitgewerkt ziet.\n\n${signature}`;
}
export function futureReplyMime(task,threadSubject='') {
 if(!/^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/.test(task.recipient)||!/^<[^<>\r\n ]+>$/.test(task.parent_message_id)||!/^<[^<>\r\n ]+>$/.test(task.message_id))throw Error('invalid_reply_headers');
 const html=escapeHtml(replyCopy()).replace(/\[([^\]]+)\]\((https:\/\/[^)]+)\)/g,'<a href="$2">$1</a>').split('\n\n').map(p=>'<p>'+p.replaceAll('\n','<br>')+'</p>').join('');
 const encoded=btoa(String.fromCharCode(...new TextEncoder().encode(html))).match(/.{1,76}/g).join('\r\n');
 return b64(['From: Thibo Adriaenssens <'+OWNER+'>','To: '+task.recipient,'Subject: Re: '+SUBJECTS[versionFromSubject(threadSubject)],'Date: '+new Date().toUTCString(),'Message-ID: '+task.message_id,'In-Reply-To: '+task.parent_message_id,'References: '+task.parent_message_id,'MIME-Version: 1.0','Content-Type: text/html; charset=UTF-8','Content-Transfer-Encoding: base64','',encoded].join('\r\n'));
}
export async function considerFutureReply(engine,message,parsed) {
 if(message.labelIds?.includes('DRAFT')||parsed?.kind!=='reply'||!softRejection(parsed.body_text))return;
 const h=headers(message);if(h['auto-submitted']&&h['auto-submitted']!=='no'||h['list-id']||h['list-unsubscribe']||!/^[<][^<>\r\n ]+[>]$/.test(h['message-id']||''))return;
 await engine.rpc('bloxflow_queue_future_reply',{p_message:parsed.gmail_id,p_parent:h['message-id']});
}
export async function processFutureReply(engine) {
 // Reconcile ambiguous sends by the stable Message-ID; never retry a possible delivery.
 const pending=await engine.result(engine.db.from('outreach_future_replies').select('*').in('status',['reserved','dispatching','uncertain']).lt('reserved_at',new Date(Date.now()-180000).toISOString()).limit(3));
 for(const t of pending){engine.budget();if(t.status==='reserved'){await engine.rpc('bloxflow_finish_future_reply',{p_token:engine.token,p_id:t.id,p_action:'retry',p_gmail:null});continue;}
  const found=await engine.gmail.list('in:sent rfc822msgid:'+t.message_id.slice(1,-1),null,2);
  await engine.rpc('bloxflow_finish_future_reply',{p_token:engine.token,p_id:t.id,p_action:found.messages?.length===1?'sent':'uncertain',p_gmail:found.messages?.length===1?found.messages[0].id:null});
 }
 const task=await engine.rpc('bloxflow_reserve_future_reply',{p_token:engine.token});if(!task)return false;
 let dispatched=false;
 try {
  const thread=await engine.gmail.thread(task.thread_id);let source=false,changed=false;
  for(const m of thread.messages||[]){if(m.id===task.source_message_id){source=true;continue;}if(m.labelIds?.includes('DRAFT')||Number(m.internalDate)>=Date.parse(task.received_at)&&(m.labelIds?.includes('SENT')||inbound(m)))changed=true;}
  // Also catches a separate manual conversation, draft, opt-out, or fresh inbound from the same person.
  let cursor;do{engine.budget();const page=await engine.gmail.list('{from:'+task.recipient+' to:'+task.recipient+'} after:'+Math.floor(Date.parse(task.received_at)/1000),cursor,25);
   for(const item of page.messages||[]){if(item.id===task.source_message_id)continue;const m=await engine.gmail.message(item.id);if(Number(m.internalDate)>=Date.parse(task.received_at))changed=true;}cursor=page.nextPageToken;
  }while(cursor&&!changed);
  if(!source||changed){await engine.rpc('bloxflow_finish_future_reply',{p_token:engine.token,p_id:task.id,p_action:'cancel',p_gmail:null});return false;}
  const msgs=thread.messages||[],first=msgs.find(m=>m.labelIds?.includes('SENT'))||msgs[0];const raw=futureReplyMime(task,headers(first||{}).subject);engine.budget();if(!await engine.rpc('bloxflow_before_future_reply',{p_token:engine.token,p_id:task.id}))return false;
  dispatched=true;const sent=await engine.gmail.send(raw,task.thread_id);
  await engine.rpc('bloxflow_finish_future_reply',{p_token:engine.token,p_id:task.id,p_action:'sent',p_gmail:sent.id});return true;
 }catch(error){await engine.rpc('bloxflow_finish_future_reply',{p_token:engine.token,p_id:task.id,p_action:dispatched?'uncertain':'retry',p_gmail:null});throw error;}
}
