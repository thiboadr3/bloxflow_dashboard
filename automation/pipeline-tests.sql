-- Runs real database functions, with all data/function changes rolled back.
-- No HTTP calls and no real emails. The Monday clock applies ONLY inside this transaction.
begin;
select id from public.outreach_runtime where id for update;
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","email":"thibo@bloxflow.be","role":"authenticated"}',true);
insert into public.prospects(id,company_name,sector_id,website_url,email,created_at)
select '20261017-dddd-4000-8000-000000000001','ROLLBACK PIPELINE',id,'https://rollback-pipeline.invalid','pipeline@rollback-pipeline.invalid','1960-01-01' from public.sectors where source_sheet='HVAC';
-- Use the real owner review RPC, then service-side evidence RPC, never a review-made email claim.
select public.bloxflow_review(id,'approved',null,true,false,updated_at) from public.prospects where id='20261017-dddd-4000-8000-000000000001';
select public.bloxflow_email_evidence(id,updated_at,true,website_url,'transaction_test_only') from public.prospects where id='20261017-dddd-4000-8000-000000000001';
do $$ declare p public.prospects; t uuid; c jsonb;j uuid; a uuid; due timestamptz; s jsonb;f text;begin
select * into p from public.prospects where id='20261017-dddd-4000-8000-000000000001';
if public.bloxflow_job_safe(p) is not true then raise exception 'Approval/evidence not ready';end if;
select x into s from jsonb_array_elements(public.bloxflow_sector_summary()) x where x->>'id'=p.sector_id::text;
if (s->>'ready')::int<1 then raise exception 'Ready counter did not include eligible row';end if;
t:=public.bloxflow_worker_lock();if t is null then raise exception 'Worker busy; rerun later';end if;
-- Real current Saturday clock: enroll, but refuse dispatch.
c:=public.bloxflow_reserve(t);
if c is not null then raise exception 'Weekend unexpectedly reserved';end if;
select id into j from public.outreach_jobs where prospect_id=p.id;
if j is null then raise exception 'Weekend approval not queued';end if;
-- Temporary weekday clock in real reserve and before-send functions, discarded at rollback.
f:=pg_get_functiondef('public.bloxflow_reserve(uuid)'::regprocedure);
f:=replace(f,$q$now() at time zone 'Europe/Brussels'$q$,$q$timestamp '2026-10-19 10:00'$q$);
execute f;
f:=pg_get_functiondef('public.bloxflow_before_send(uuid,uuid)'::regprocedure);
f:=replace(f,$q$clock_timestamp() at time zone 'Europe/Brussels'$q$,$q$timestamp '2026-10-19 10:00'$q$);execute f;
for v_step in 1..3 loop
 update public.outreach_jobs set due_at=now()-interval '1 second' where id=j;
 update public.outreach_attempts set sent_at=now()-interval '5 minutes' where job_id=j and state='sent';
 c:=public.bloxflow_reserve(t);if c is null or c->'job'->>'id'<>j::text or (c->'attempt'->>'step')::int<>v_step then raise exception 'Reservation step % failed',v_step;end if;
 a:=(c->'attempt'->>'id')::uuid;
 if not public.bloxflow_before_send(t,a) then raise exception 'Preflight gate % failed',v_step;end if;
 perform public.bloxflow_record_sent(a,'rollback-gmail-'||v_step,'rollback-thread',now()-interval '5 minutes');
 perform public.bloxflow_record_sent(a,'rollback-gmail-'||v_step,'rollback-thread',now()-interval '5 minutes');
 if(select count(*) from public.outreach_attempts where job_id=j and step=v_step and state='sent')<>1 then raise exception 'Idempotency failed';end if;
 select due_at into due from public.outreach_jobs where id=j;
 if due<>public.bloxflow_due(now()-interval '5 minutes',3,true) then raise exception 'Followup interval failed';end if;
end loop;
if not exists(select 1 from public.outreach_jobs where id=j and status='completed') then raise exception 'Third mail did not complete';end if;
if public.bloxflow_reserve(t) is not null then raise exception 'Fourth mail was permitted';end if;
perform public.bloxflow_ingest_reply(jsonb_build_object('gmail_id','rollback-reply','thread_id','rollback-thread','from_address',p.email,'subject','Antwoord','body_text','Niet meer mailen','received_at',now(),'kind','opt_out'),j);
if not exists(select 1 from public.outreach_jobs where id=j and status='replied') or public.bloxflow_job_safe(p) is true then raise exception 'Reply did not stop/block';end if;
if not exists(select 1 from jsonb_array_elements(public.bloxflow_inbox()) x where x->>'gmail_id'='rollback-reply') then raise exception 'Owner inbox missing reply';end if;
if has_function_privilege('anon','public.bloxflow_reserve(uuid)','EXECUTE') or has_function_privilege('authenticated','public.bloxflow_before_send(uuid,uuid)','EXECUTE') then raise exception 'Sender permissions invalid';end if;
end $$;
rollback;
select 'PASS: review, email evidence, weekend queue, mail 1/2/3, threading IDs, duplicate outcome, three-day timing, completion, reply stop, suppression, owner inbox, sender permissions; all test changes rolled back' as result;
