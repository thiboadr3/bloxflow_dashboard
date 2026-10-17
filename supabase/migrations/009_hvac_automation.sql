begin;
create table public.outreach_runtime (
 id boolean primary key default true check(id), enabled boolean not null default false,
 followup_days integer[] not null default array[3,5],business_days boolean not null default true,
 start_hour integer not null default 8 check(start_hour between 6 and 17),end_hour integer not null default 18 check(end_hour between 9 and 22),
 daily_limit integer not null default 600 check(daily_limit between 1 and 600),step_limit integer not null default 200 check(step_limit between 1 and 200),
 worker_verified boolean not null default false,lease_token uuid,lease_until timestamptz,
 last_run_at timestamptz,last_sync_at timestamptz,last_error text,history_id text,
 bootstrap_page text,bootstrap_history text,worker_token_hash text,
 check(start_hour<end_hour),check(array_length(followup_days,1)=2)
);
insert into public.outreach_runtime(id) values(true);
create table public.outreach_jobs (
 id uuid primary key default gen_random_uuid(),prospect_id uuid not null unique references public.prospects(id),
 recipient text not null,company_name text not null,identity_keys text[] not null,
 next_step integer not null default 1 check(next_step between 1 and 3),due_at timestamptz not null default now(),
 status text not null default 'queued' check(status in('queued','reserved','uncertain','replied','stopped','completed')),
 stop_reason text,thread_id text,parent_message_id text,last_sent_at timestamptz,created_at timestamptz not null default now()
);
create index outreach_jobs_due on public.outreach_jobs(due_at) where status='queued';
create index outreach_jobs_keys on public.outreach_jobs using gin(identity_keys);
create table public.outreach_attempts (
 id uuid primary key default gen_random_uuid(),job_id uuid not null references public.outreach_jobs(id),step integer not null check(step between 1 and 3),
 state text not null default 'reserved' check(state in('reserved','dispatching','sent','uncertain','cancelled')),
 message_id text not null unique,gmail_id text unique,thread_id text,
 created_at timestamptz not null default now(),sent_at timestamptz,preflight_at timestamptz,error_code text
);
create unique index outreach_one_step on public.outreach_attempts(job_id,step) where state<>'cancelled';
create table public.outreach_messages (
 gmail_id text primary key,job_id uuid not null references public.outreach_jobs(id),thread_id text not null,
 from_address text not null,subject text not null,body_text text not null,received_at timestamptz not null,
 kind text not null check(kind in('reply','opt_out','delivery_issue','automatic_reply','ambiguous_reply')),
 seen boolean not null default false
);
-- A shared conversation can belong to multiple jobs; stop all matching jobs, store content once.
create table public.outreach_message_jobs(gmail_id text references public.outreach_messages(gmail_id),job_id uuid references public.outreach_jobs(id),primary key(gmail_id,job_id));
create table public.outreach_blocks(identity_keys text[] not null,reason text not null,created_at timestamptz not null default now());
create index outreach_blocks_keys on public.outreach_blocks using gin(identity_keys);
alter table public.outreach_runtime enable row level security;
alter table public.outreach_jobs enable row level security;
alter table public.outreach_attempts enable row level security;
alter table public.outreach_messages enable row level security;
alter table public.outreach_message_jobs enable row level security;
alter table public.outreach_blocks enable row level security;
revoke all on public.outreach_runtime,public.outreach_jobs,public.outreach_attempts,public.outreach_messages,public.outreach_message_jobs,public.outreach_blocks from public,anon,authenticated;
grant all on public.outreach_runtime,public.outreach_jobs,public.outreach_attempts,public.outreach_messages,public.outreach_message_jobs,public.outreach_blocks to service_role;

create function public.bloxflow_due(p_at timestamptz,p_days integer,p_business boolean) returns timestamptz language plpgsql immutable set search_path='' as $$
declare t timestamp:=p_at at time zone 'Europe/Brussels'; n integer:=0;begin
while n<p_days loop t:=t+interval '1 day';if not p_business or extract(isodow from t)<6 then n:=n+1;end if;end loop;
return t at time zone 'Europe/Brussels';end $$;
create function public.bloxflow_job_safe(p public.prospects) returns boolean language sql stable security definer set search_path='' as $$
 select p.review_status='approved' and p.archived_at is null and not p.previously_contacted and p.website_checked and p.email_verified
 and p.email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$'
 and p.send_blocker in('none','campaign_not_approved')
 and exists(select 1 from public.sectors s where s.id=p.sector_id and s.source_sheet='HVAC')
 and not exists(select 1 from public.contact_history_archive h where h.identity_keys && public.bloxflow_identity_keys(to_jsonb(p)))
 and not exists(select 1 from public.suppressions s where public.bloxflow_identity_keys(to_jsonb(s)) && public.bloxflow_identity_keys(to_jsonb(p)))
 and not exists(select 1 from public.outreach_blocks b where b.identity_keys && public.bloxflow_identity_keys(to_jsonb(p)));
$$;
create function public.bloxflow_worker_lock() returns uuid language plpgsql security definer set search_path='' as $$
declare token uuid:=gen_random_uuid();begin
update public.outreach_runtime set lease_token=token,lease_until=now()+interval '90 seconds',last_run_at=now() where id and (lease_until is null or lease_until<now());
if not found then return null;end if;return token;end $$;
create function public.bloxflow_reserve(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.outreach_runtime;j public.outreach_jobs;p public.prospects;a public.outreach_attempts;t timestamp:=now() at time zone 'Europe/Brussels';begin
select * into r from public.outreach_runtime where id for update;
if r.lease_token is distinct from p_token or r.lease_until<now() then raise exception 'Lease expired';end if;
if not r.enabled or not r.worker_verified or r.last_sync_at is null or r.last_sync_at<now()-interval '2 minutes' then return null;end if;
if not exists(select 1 from public.sending_settings where id and not paused and gmail_connected) or not exists(select 1 from public.gmail_connections where email='thibo@bloxflow.be' and sending_enabled) then return null;end if;
if extract(isodow from t)>5 or extract(hour from t)<r.start_hour or extract(hour from t)>=r.end_hour then return null;end if;
update public.outreach_jobs set status='uncertain',stop_reason='stale_reservation' where status='reserved' and id in(select job_id from public.outreach_attempts where state in('reserved','dispatching') and created_at<now()-interval '3 minutes');
update public.outreach_attempts set state='uncertain',error_code='worker_interrupted' where state in('reserved','dispatching') and created_at<now()-interval '3 minutes';
-- All imported records remain blocked until a separate, evidence-backed clearance.
insert into public.outreach_jobs(prospect_id,recipient,company_name,identity_keys)
select p.id,lower(trim(p.email)),p.company_name,public.bloxflow_identity_keys(to_jsonb(p)) from public.prospects p where public.bloxflow_job_safe(p)
and not exists(select 1 from public.outreach_jobs j where j.identity_keys && public.bloxflow_identity_keys(to_jsonb(p))) order by p.approved_at,p.id on conflict(prospect_id) do nothing;
if exists(select 1 from public.outreach_attempts where state in('reserved','dispatching','sent','uncertain') and coalesce(sent_at,created_at)>now()-interval '60 seconds') then return null;end if;
if (select count(*) from public.outreach_attempts where state in('reserved','dispatching','sent','uncertain') and (coalesce(sent_at,created_at)>now()-interval '24 hours' or (coalesce(sent_at,created_at) at time zone 'Europe/Brussels')::date=t::date))>=r.daily_limit then return null;end if;
for j in select * from public.outreach_jobs where status='queued' and due_at<=now() order by (next_step=1),due_at,id for update skip locked loop
select * into p from public.prospects where id=j.prospect_id for update;
if public.bloxflow_job_safe(p) is not true or lower(trim(p.email))<>j.recipient or exists(select 1 from public.outreach_jobs other join public.outreach_attempts used on used.job_id=other.id where other.id<>j.id and other.identity_keys && j.identity_keys and used.state in('reserved','dispatching','sent','uncertain')) then update public.outreach_jobs set status='stopped',stop_reason='prospect_gate_changed' where id=j.id;continue;end if;
if (select count(*) from public.outreach_attempts where step=j.next_step and state in('reserved','dispatching','sent','uncertain') and (coalesce(sent_at,created_at)>now()-interval '24 hours' or (coalesce(sent_at,created_at) at time zone 'Europe/Brussels')::date=t::date))>=r.step_limit then continue;end if;
insert into public.outreach_attempts(job_id,step,message_id) values(j.id,j.next_step,'<'||gen_random_uuid()::text||'@outreach.bloxflow.be>') returning * into a;
update public.outreach_jobs set status='reserved' where id=j.id;
return jsonb_build_object('attempt',to_jsonb(a),'job',to_jsonb(j));end loop;return null;
end $$;
create function public.bloxflow_before_send(p_token uuid,p_attempt uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.outreach_runtime;a public.outreach_attempts;j public.outreach_jobs;p public.prospects;begin
select * into r from public.outreach_runtime where id for update;
if r.lease_token is distinct from p_token or r.lease_until<now() then return false;end if;
select * into a from public.outreach_attempts where id=p_attempt for update;
select * into j from public.outreach_jobs where id=a.job_id for update;
select * into p from public.prospects where id=j.prospect_id for update;
if a.state<>'reserved' or a.created_at<now()-interval '90 seconds' or j.status<>'reserved' or not r.enabled or not r.worker_verified or r.last_sync_at is null or r.last_sync_at<now()-interval '2 minutes' or public.bloxflow_job_safe(p) is not true or lower(trim(p.email))<>j.recipient or exists(select 1 from public.outreach_jobs other join public.outreach_attempts used on used.job_id=other.id where other.id<>j.id and other.identity_keys && j.identity_keys and used.state in('reserved','dispatching','sent','uncertain')) or not exists(select 1 from public.sending_settings where id and not paused) or not exists(select 1 from public.gmail_connections where email='thibo@bloxflow.be' and sending_enabled) then
update public.outreach_attempts set state='cancelled' where id=a.id and state='reserved';update public.outreach_jobs set status='stopped',stop_reason='pre_send_gate' where id=j.id and status='reserved';return false;end if;
update public.outreach_attempts set state='dispatching',preflight_at=clock_timestamp() where id=a.id;return true;end $$;
create function public.bloxflow_record_sent(p_attempt uuid,p_gmail text,p_thread text,p_at timestamptz default now()) returns void language plpgsql security definer set search_path='' as $$
declare a public.outreach_attempts;j public.outreach_jobs;r public.outreach_runtime;begin
select * into a from public.outreach_attempts where id=p_attempt for update;if a.state='sent' then return;end if;
if a.state not in('dispatching','uncertain') then raise exception 'Invalid outcome state';end if;
select * into j from public.outreach_jobs where id=a.job_id for update;select * into r from public.outreach_runtime where id;
update public.outreach_attempts set state='sent',gmail_id=p_gmail,thread_id=p_thread,sent_at=p_at where id=a.id;
update public.outreach_jobs set status=case when status in('replied','stopped') then status when a.step=3 then 'completed' else 'queued' end,next_step=least(3,a.step+1),due_at=public.bloxflow_due(p_at,r.followup_days[least(2,a.step)],r.business_days),thread_id=p_thread,parent_message_id=a.message_id,last_sent_at=p_at where id=j.id;
end $$;
create function public.bloxflow_ingest_reply(p_message jsonb,p_job uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare j public.outreach_jobs;n integer:=0;email text:=lower(p_message->>'from_address');begin
for j in select * from public.outreach_jobs where id=p_job or thread_id=p_message->>'thread_id' or recipient=email loop
insert into public.outreach_messages(gmail_id,job_id,thread_id,from_address,subject,body_text,received_at,kind)
values(p_message->>'gmail_id',j.id,p_message->>'thread_id',email,left(p_message->>'subject',500),left(p_message->>'body_text',30000),(p_message->>'received_at')::timestamptz,p_message->>'kind') on conflict(gmail_id) do nothing;
insert into public.outreach_message_jobs(gmail_id,job_id) values(p_message->>'gmail_id',j.id) on conflict do nothing;
update public.outreach_jobs set status='replied',stop_reason=p_message->>'kind' where id=j.id;
insert into public.outreach_blocks(identity_keys,reason) select j.identity_keys,p_message->>'kind' where not exists(select 1 from public.outreach_blocks b where b.identity_keys=j.identity_keys);
n:=n+1;end loop;return n;end $$;
create function public.bloxflow_job_review_change() returns trigger language plpgsql security definer set search_path='' as $$ begin
if new.review_status<>'approved' or new.sector_id is distinct from old.sector_id or new.archived_at is not null or new.email is distinct from old.email then update public.outreach_jobs set status='stopped',stop_reason='review_changed' where prospect_id=new.id and status in('queued','reserved');end if;
return new;end $$;
create trigger bloxflow_stop_job_on_review after update on public.prospects for each row execute function public.bloxflow_job_review_change();
create function public.bloxflow_block_reimport() returns trigger language plpgsql security definer set search_path='' as $$ begin
if exists(select 1 from public.outreach_jobs j join public.outreach_attempts a on a.job_id=j.id where j.prospect_id<>new.id and j.identity_keys && public.bloxflow_identity_keys(to_jsonb(new)) and a.state in('dispatching','sent','uncertain')) then new.archived_at:=coalesce(new.archived_at,now());new.archive_reason:='already_contacted';new.previously_contacted:=true;new.automation_allowed:=false;new.send_blocker:='previously_contacted';end if;return new;end $$;
create trigger bloxflow_live_contact_guard before insert or update on public.prospects for each row execute function public.bloxflow_block_reimport();
-- The connection can now represent enabled sending, but stays disabled during testing.
do $$ declare c record;begin for c in select conname from pg_constraint where conrelid='public.gmail_connections'::regclass and contype='c' and pg_get_constraintdef(oid) like '%NOT sending_enabled%' loop execute format('alter table public.gmail_connections drop constraint %I',c.conname);end loop;end $$;
create function public.bloxflow_mail_overview() returns jsonb language plpgsql security definer set search_path='' as $$ begin
if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
return (select jsonb_build_object('enabled',r.enabled,'verified',r.worker_verified,'last_run_at',r.last_run_at,'last_sync_at',r.last_sync_at,'last_error',r.last_error,'followup_days',r.followup_days,'business_days',r.business_days,'start_hour',r.start_hour,'end_hour',r.end_hour,'queued',(select count(*) from public.outreach_jobs where status='queued'),'replies',(select count(*) from public.outreach_messages),'uncertain',(select count(*) from public.outreach_attempts where state='uncertain'),'sent_today',(select count(*) from public.outreach_attempts where state='sent' and (sent_at at time zone 'Europe/Brussels')::date=(now() at time zone 'Europe/Brussels')::date),'blocked_approved',(select count(*) from public.prospects p join public.sectors s on s.id=p.sector_id where s.source_sheet='HVAC' and p.archived_at is null and p.review_status='approved' and not public.bloxflow_job_safe(p))) from public.outreach_runtime r where id);end $$;
create function public.bloxflow_inbox(p_before timestamptz default null) returns jsonb language plpgsql security definer set search_path='' as $$ begin
if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
return (select coalesce(jsonb_agg(x order by received_at desc,gmail_id desc),'[]'::jsonb) from(select m.*,j.company_name,j.status as sequence_status from public.outreach_messages m join public.outreach_jobs j on j.id=m.job_id where p_before is null or m.received_at<p_before order by m.received_at desc,m.gmail_id desc limit 50)x);end $$;
create function public.bloxflow_pause_mail() returns void language plpgsql security definer set search_path='' as $$ begin
if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
update public.outreach_runtime set enabled=false where id;update public.sending_settings set paused=true where id;update public.gmail_connections set sending_enabled=false where email='thibo@bloxflow.be';end $$;
-- No client or anonymous execution of service functions.
do $$ declare f record;begin for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname in('bloxflow_due','bloxflow_job_safe','bloxflow_worker_lock','bloxflow_reserve','bloxflow_before_send','bloxflow_record_sent','bloxflow_ingest_reply','bloxflow_job_review_change','bloxflow_block_reimport','bloxflow_mail_overview','bloxflow_inbox','bloxflow_pause_mail') loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to service_role',f.signature);end loop;end $$;
grant execute on function public.bloxflow_mail_overview(),public.bloxflow_inbox(timestamptz),public.bloxflow_pause_mail() to authenticated;
commit;
