begin;
select id from public.outreach_runtime where id for update;
DO $test$ declare pid uuid:=gen_random_uuid();jid uuid:=gen_random_uuid();token uuid:=gen_random_uuid();fid uuid;mid text:='rollback-future-'||gen_random_uuid();f public.outreach_future_replies;n int;begin
 update public.outreach_runtime set lease_token=token,lease_until=now()+interval '5 minutes' where id;
 update public.outreach_future_reply_settings set enabled=true,activated_at=now()-interval '2 hours' where id;
 insert into public.prospects(id,company_name,sector_id,website_url,email,email_verified,email_evidence_url,review_status,approved_at,website_checked,send_blocker)
 select pid,'ROLLBACK FUTURE REPLY',id,'https://future-reply-test.invalid','owner@future-reply-test.invalid',true,'https://future-reply-test.invalid/contact','approved',now(),true,'none' from public.sectors where source_sheet='HVAC';
 insert into public.outreach_jobs(id,prospect_id,recipient,company_name,identity_keys,last_sent_at,thread_id,parent_message_id,status)
 select jid,pid,email,company_name,public.bloxflow_identity_keys(to_jsonb(p)),now()-interval '4 hours','rollback-future-thread','<rollback-parent@test.invalid>','queued' from public.prospects p where id=pid;
 perform public.bloxflow_ingest_reply(jsonb_build_object('gmail_id',mid,'thread_id','rollback-future-thread','from_address','owner@future-reply-test.invalid','subject','Re: Korte vraag over jullie website','body_text','Op dit moment niet. Bedankt.','received_at',now()-interval '3 hours','kind','reply'),jid);
 perform public.bloxflow_queue_future_reply(mid,'<incoming@test.invalid>');
 if exists(select 1 from public.outreach_future_replies where job_id=jid) then raise exception 'Old replies must not enqueue';end if;
 update public.outreach_messages set received_at=now()-interval '29 minutes' where gmail_id=mid;
 perform public.bloxflow_queue_future_reply(mid,'<incoming@test.invalid>');
 select * into strict f from public.outreach_future_replies where job_id=jid;fid:=f.id;
 if f.due_at<>f.received_at+interval '30 minutes' or public.bloxflow_future_reply_safe(f) then raise exception '30-minute delay failed';end if;
 perform public.bloxflow_queue_future_reply(mid,'<incoming@test.invalid>');
 if(select count(*) from public.outreach_future_replies where job_id=jid)<>1 then raise exception 'Duplicate queued';end if;
 update public.outreach_messages set received_at=now()-interval '31 minutes' where gmail_id=mid;
 update public.outreach_future_replies set received_at=now()-interval '31 minutes',due_at=now()-interval '1 minute' where id=fid returning * into f;
 if not public.bloxflow_future_reply_safe(f) then raise exception 'Due rejection blocked';end if;
 -- Capacity is exercised separately; deterministic test ignores current clock only inside rollback.
 execute 'create or replace function public.bloxflow_future_reply_capacity() returns boolean language sql stable security definer set search_path='''' as ''select true''';
 if (public.bloxflow_reserve_future_reply(token)->>'id')::uuid<>fid then raise exception 'Reservation failed';end if;
 perform public.bloxflow_finish_future_reply(token,fid,'retry',null);
 if(select status from public.outreach_future_replies where id=fid)<>'pending' then raise exception 'Interrupted-before-send retry failed';end if;
 perform public.bloxflow_reserve_future_reply(token);
 if not public.bloxflow_before_future_reply(token,fid) then raise exception 'Before-send failed';end if;
 perform public.bloxflow_finish_future_reply(token,fid,'retry',null);
 if(select status from public.outreach_future_replies where id=fid)<>'dispatching' then raise exception 'Ambiguous send was retried';end if;
 perform public.bloxflow_finish_future_reply(token,fid,'uncertain',null);
 if public.bloxflow_reserve_future_reply(token) is not null then raise exception 'Uncertain task was retried';end if;
 perform public.bloxflow_finish_future_reply(token,fid,'sent','rollback-gmail');
 perform public.bloxflow_finish_future_reply(token,fid,'sent','rollback-gmail');
 if(select status from public.outreach_future_replies where id=fid)<>'sent' then raise exception 'Delivery reconciliation failed';end if;
 if(select status from public.outreach_jobs where id=jid)<>'replied' then raise exception 'Followup resumed';end if;
 -- Any new reply/opt-out makes the old candidate unsafe.
 perform public.bloxflow_ingest_reply(jsonb_build_object('gmail_id',mid||'-optout','thread_id','rollback-future-thread','from_address','owner@future-reply-test.invalid','subject','Stop','body_text','Niet meer mailen','received_at',now(),'kind','opt_out'),jid);
 select * into f from public.outreach_future_replies where id=fid;
 if public.bloxflow_future_reply_safe(f) then raise exception 'Optout ignored';end if;
 if has_function_privilege('anon','public.bloxflow_queue_future_reply(text,text)','EXECUTE') or has_function_privilege('authenticated','public.bloxflow_reserve_future_reply(uuid)','EXECUTE') then raise exception 'Sender exposed';end if;
end $test$;
rollback;
select 'PASS: activation cutoff, 30-minute delay, deduplication, lease, pre-send, interrupted/uncertain delivery, reply stop, opt-out, private permissions; no mail sent; all fixtures rolled back' as result;
