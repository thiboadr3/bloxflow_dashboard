-- Explicit owner authorization, 2026-10-23. Only future inbound replies; disabled until deployed/tested.
begin;
create table public.outreach_future_reply_settings(id boolean primary key default true check(id),enabled boolean not null default false,activated_at timestamptz,delay_minutes int not null default 30 check(delay_minutes=30));
insert into public.outreach_future_reply_settings(id) values(true);
alter table public.outreach_future_reply_settings enable row level security;
revoke all on public.outreach_future_reply_settings from public,anon,authenticated;
grant all on public.outreach_future_reply_settings to service_role;
create table public.outreach_future_replies(
 id uuid primary key default gen_random_uuid(),job_id uuid not null unique references public.outreach_jobs(id),source_message_id text not null unique,
 thread_id text not null,recipient text not null,parent_message_id text not null,identity_keys text[] not null,
 received_at timestamptz not null,due_at timestamptz not null,
 status text not null default 'pending' check(status in('pending','reserved','dispatching','sent','uncertain','cancelled')),
 message_id text not null unique default ('<'||gen_random_uuid()::text||'@reply.bloxflow.be>'),reserved_at timestamptz,sent_at timestamptz,gmail_id text,reason text,created_at timestamptz not null default now(),
 check(due_at>=received_at+interval '30 minutes'));
create index outreach_future_reply_due on public.outreach_future_replies(due_at) where status='pending';
create index outreach_future_reply_identity on public.outreach_future_replies using gin(identity_keys);
alter table public.outreach_future_replies enable row level security;
revoke all on public.outreach_future_replies from public,anon,authenticated;
grant all on public.outreach_future_replies to service_role;
create function public.bloxflow_queue_future_reply(p_message text,p_parent text) returns void language plpgsql security definer set search_path='' as $$
declare m public.outreach_messages;j public.outreach_jobs;cfg public.outreach_future_reply_settings;begin
 select * into cfg from public.outreach_future_reply_settings where id and enabled; if not found then return;end if;
 select * into m from public.outreach_messages where gmail_id=p_message;if not found or m.kind<>'reply' or m.received_at<cfg.activated_at or m.received_at>now()+interval '2 minutes' then return;end if;
 -- Serialize by job, and additionally by identity to prevent multiple concurrent queues for the same company.
 perform pg_advisory_xact_lock(hashtextextended('bloxflow_future_reply_queue',0));
 select * into j from public.outreach_jobs where id=m.job_id for update;
 if not found or j.is_test or j.status<>'replied' or j.stop_reason<>'reply' or j.thread_id is distinct from m.thread_id or j.last_sent_at is null then return;end if;
 if m.from_address<>j.recipient and not exists(select 1 from unnest(j.identity_keys) k where k like 'domain:%' and split_part(m.from_address,'@',2)=substr(k,8) and substr(k,8) not in('gmail.com','outlook.com','hotmail.com','telenet.be','skynet.be','live.be','yahoo.com')) then return;end if;
 if exists(select 1 from public.outreach_future_replies f where f.identity_keys && j.identity_keys) then return;end if;
 if exists(select 1 from public.suppressions s where public.bloxflow_identity_keys(to_jsonb(s)) && j.identity_keys)
 or exists(select 1 from public.outreach_blocks b where b.identity_keys && j.identity_keys and b.reason<>'reply') then return;end if;
 if p_parent!~'^<[^<>\r\n ]+>$' then return;end if;
 insert into public.outreach_future_replies(job_id,source_message_id,thread_id,recipient,parent_message_id,identity_keys,received_at,due_at)
 values(j.id,m.gmail_id,m.thread_id,m.from_address,p_parent,j.identity_keys,m.received_at,m.received_at+interval '30 minutes') on conflict do nothing;
end$$;
create function public.bloxflow_future_reply_safe(f public.outreach_future_replies) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.outreach_future_reply_settings where id and enabled and f.received_at>=activated_at)
 and f.due_at<=now() and f.received_at>now()-interval '2 days'
 and exists(select 1 from public.outreach_jobs j join public.prospects p on p.id=j.prospect_id where j.id=f.job_id and not j.is_test and j.status='replied' and j.stop_reason='reply' and p.archived_at is null)
 and not exists(select 1 from public.outreach_messages m join public.outreach_message_jobs link on link.gmail_id=m.gmail_id join public.outreach_jobs j on j.id=link.job_id where j.identity_keys && f.identity_keys and (m.received_at>f.received_at or m.kind<>'reply'))
 and not exists(select 1 from public.suppressions s where public.bloxflow_identity_keys(to_jsonb(s)) && f.identity_keys)
 and not exists(select 1 from public.outreach_blocks b where b.identity_keys && f.identity_keys and b.reason<>'reply');
$$;
create function public.bloxflow_future_reply_capacity() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.outreach_runtime r where id and enabled and worker_verified and last_error is null and last_sync_at>now()-interval '2 minutes'

 and exists(select 1 from public.sending_settings where id and not paused and gmail_connected)
 and exists(select 1 from public.gmail_connections where email='thibo@bloxflow.be' and sending_enabled)
 and (select count(*) from public.outreach_attempts a where a.state in('reserved','dispatching','sent','uncertain') and (coalesce(a.sent_at,a.created_at)>now()-interval '24 hours' or (coalesce(a.sent_at,a.created_at) at time zone 'Europe/Brussels')::date=(now() at time zone 'Europe/Brussels')::date))+
 (select count(*) from public.outreach_future_replies f where f.status in('dispatching','sent','uncertain') and (coalesce(f.sent_at,f.reserved_at)>now()-interval '24 hours' or (coalesce(f.sent_at,f.reserved_at) at time zone 'Europe/Brussels')::date=(now() at time zone 'Europe/Brussels')::date))<r.daily_limit
 and not exists(select 1 from public.outreach_attempts a where a.state in('reserved','dispatching','sent','uncertain') and coalesce(a.sent_at,a.created_at)>now()-interval '60 seconds')
 and not exists(select 1 from public.outreach_future_replies f where f.status in('dispatching','sent','uncertain') and coalesce(f.sent_at,f.reserved_at)>now()-interval '60 seconds'));
$$;
create function public.bloxflow_reserve_future_reply(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare f public.outreach_future_replies;begin
 perform 1 from public.outreach_runtime where id and lease_token=p_token and lease_until>now() for update;if not found then raise exception 'Lease expired';end if;
 update public.outreach_future_replies q set status='cancelled',reason='new_activity_or_expired' where q.status='pending' and q.due_at<=now() and not public.bloxflow_future_reply_safe(q);
 if not public.bloxflow_future_reply_capacity() then return null;end if;
 select * into f from public.outreach_future_replies q where q.status='pending' and public.bloxflow_future_reply_safe(q) order by due_at,id for update skip locked limit 1;
 if not found then return null;end if;
 update public.outreach_future_replies set status='reserved',reserved_at=now() where id=f.id returning * into f;return to_jsonb(f);
end$$;
create function public.bloxflow_before_future_reply(p_token uuid,p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare f public.outreach_future_replies;begin
 perform 1 from public.outreach_runtime where id and lease_token=p_token and lease_until>now() for update;if not found then return false;end if;
 select * into f from public.outreach_future_replies where id=p_id for update;
 if not found or f.status<>'reserved' then return false;end if;
 if f.reserved_at<now()-interval '90 seconds' or not public.bloxflow_future_reply_safe(f) or not public.bloxflow_future_reply_capacity() then
 update public.outreach_future_replies set status=case when public.bloxflow_future_reply_safe(f) then 'pending' else 'cancelled' end,reason='pre_send_gate' where id=f.id;return false;end if;
 update public.outreach_future_replies set status='dispatching' where id=f.id;return true;
end$$;
create function public.bloxflow_finish_future_reply(p_token uuid,p_id uuid,p_action text,p_gmail text) returns void language plpgsql security definer set search_path='' as $$
declare f public.outreach_future_replies;begin
 perform 1 from public.outreach_runtime where id and lease_token=p_token and lease_until>now() for update;if not found then raise exception 'Lease expired';end if;
 select * into f from public.outreach_future_replies where id=p_id for update;if not found then return;end if;
 if p_action='sent' and p_gmail is not null and f.status in('dispatching','uncertain') then update public.outreach_future_replies set status='sent',gmail_id=p_gmail,sent_at=now() where id=f.id;
 elsif p_action='uncertain' and f.status in('dispatching','uncertain') then update public.outreach_future_replies set status='uncertain',reason='delivery_not_confirmed' where id=f.id;
 elsif p_action='retry' and f.status='reserved' then update public.outreach_future_replies set status='pending',reason='interrupted_before_dispatch' where id=f.id;
 elsif p_action='cancel' and f.status='reserved' then update public.outreach_future_replies set status='cancelled',reason='manual_reply_draft_or_new_activity' where id=f.id;
 end if;
end$$;
-- Include these extra replies in the existing overall 600-message cap and 60-second pacing.
do $patch$ declare f text;signature text;needle text:='))>=r.daily_limit';extra text:='))+(select count(*) from public.outreach_future_replies f where f.status in(''dispatching'',''sent'',''uncertain'') and (coalesce(f.sent_at,f.reserved_at)>now()-interval ''24 hours'' or (coalesce(f.sent_at,f.reserved_at) at time zone ''Europe/Brussels'')::date=t::date))>=r.daily_limit';begin
 signature:='public.bloxflow_reserve(uuid)';f:=pg_get_functiondef(signature::regprocedure);
 if position(needle in f)=0 then raise exception 'Unexpected reserve definition';end if;
 f:=replace(f,needle,extra);
 f:=replace(f,'if not r.enabled', 'if exists(select 1 from public.outreach_future_replies f where f.status in(''dispatching'',''sent'',''uncertain'') and coalesce(f.sent_at,f.reserved_at)>now()-interval ''60 seconds'') then return null;end if; if not r.enabled');
 execute f;
end $patch$;
do $$declare f record;begin for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname in('bloxflow_queue_future_reply','bloxflow_future_reply_safe','bloxflow_future_reply_capacity','bloxflow_reserve_future_reply','bloxflow_before_future_reply','bloxflow_finish_future_reply') loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to service_role',f.signature);end loop;end$$;
commit;
