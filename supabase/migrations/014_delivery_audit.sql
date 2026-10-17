begin;
create or replace function public.bloxflow_reserve(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.outreach_runtime;j public.outreach_jobs;p public.prospects;a public.outreach_attempts;t timestamp:=now() at time zone 'Europe/Brussels';begin
select * into r from public.outreach_runtime where id for update;
if r.lease_token is distinct from p_token or r.lease_until<now() then raise exception 'Lease expired';end if;
if not r.enabled or not r.worker_verified or r.last_sync_at is null or r.last_sync_at<now()-interval '2 minutes' then return null;end if;
if not exists(select 1 from public.sending_settings where id and not paused and gmail_connected) or not exists(select 1 from public.gmail_connections where email='thibo@bloxflow.be' and sending_enabled) then return null;end if;

update public.outreach_jobs set status='uncertain',stop_reason='stale_reservation' where status='reserved' and id in(select job_id from public.outreach_attempts where state in('reserved','dispatching') and created_at<now()-interval '3 minutes');
update public.outreach_attempts set state='uncertain',error_code='worker_interrupted' where state in('reserved','dispatching') and created_at<now()-interval '3 minutes';
-- All imported records remain blocked until a separate, evidence-backed clearance.
insert into public.outreach_jobs(prospect_id,recipient,company_name,identity_keys)
select candidate_prospect.id,lower(trim(candidate_prospect.email)),candidate_prospect.company_name,public.bloxflow_identity_keys(to_jsonb(candidate_prospect)) from public.prospects candidate_prospect where public.bloxflow_job_safe(candidate_prospect)
and not exists(select 1 from public.outreach_jobs existing_job where existing_job.identity_keys && public.bloxflow_identity_keys(to_jsonb(candidate_prospect))) order by candidate_prospect.approved_at,candidate_prospect.id on conflict(prospect_id) do nothing;
if extract(isodow from t)>5 or extract(hour from t)<r.start_hour or extract(hour from t)>=r.end_hour then return null;end if;
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
create or replace function public.bloxflow_before_send(p_token uuid,p_attempt uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.outreach_runtime;a public.outreach_attempts;j public.outreach_jobs;p public.prospects;begin
select * into r from public.outreach_runtime where id for update;
if r.lease_token is distinct from p_token or r.lease_until<now() then return false;end if;
select * into a from public.outreach_attempts where id=p_attempt for update;
select * into j from public.outreach_jobs where id=a.job_id for update;
select * into p from public.prospects where id=j.prospect_id for update;
if extract(isodow from (clock_timestamp() at time zone 'Europe/Brussels'))>5 or extract(hour from (clock_timestamp() at time zone 'Europe/Brussels'))<r.start_hour or extract(hour from (clock_timestamp() at time zone 'Europe/Brussels'))>=r.end_hour then update public.outreach_attempts set state='cancelled',error_code='outside_window' where id=a.id and state='reserved';update public.outreach_jobs set status='queued' where id=j.id and status='reserved';return false;end if;
if a.state<>'reserved' or a.created_at<now()-interval '90 seconds' or j.status<>'reserved' or not r.enabled or not r.worker_verified or r.last_sync_at is null or r.last_sync_at<now()-interval '2 minutes' or public.bloxflow_job_safe(p) is not true or lower(trim(p.email))<>j.recipient or exists(select 1 from public.outreach_jobs other join public.outreach_attempts used on used.job_id=other.id where other.id<>j.id and other.identity_keys && j.identity_keys and used.state in('reserved','dispatching','sent','uncertain')) or not exists(select 1 from public.sending_settings where id and not paused) or not exists(select 1 from public.gmail_connections where email='thibo@bloxflow.be' and sending_enabled) then
update public.outreach_attempts set state='cancelled' where id=a.id and state='reserved';update public.outreach_jobs set status='stopped',stop_reason='pre_send_gate' where id=j.id and status='reserved';return false;end if;
update public.outreach_attempts set state='dispatching',preflight_at=clock_timestamp() where id=a.id;return true;end $$;
create or replace function public.bloxflow_sector_summary() returns jsonb language plpgsql security definer set search_path='' as $$
begin
if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
return (with rows as materialized(select p.*,s.source_sheet,
 case when s.source_sheet='HVAC' and p.review_status='approved' and p.archived_at is null and not p.previously_contacted and p.email_verified then public.bloxflow_job_safe(p) else false end as safe,
 exists(select 1 from public.outreach_attempts a join public.outreach_jobs j on j.id=a.job_id where j.prospect_id=p.id and a.step=1 and a.state='sent') as contacted,
 exists(select 1 from public.outreach_jobs j where j.prospect_id=p.id and j.status in('reserved','stopped','replied','completed','uncertain')) as stopped,
 exists(select 1 from public.outreach_jobs j where j.prospect_id=p.id and j.status='replied') as replied
 from public.prospects p join public.sectors s on s.id=p.sector_id where p.archived_at is null),
 counts as(select s.id,s.name,
 count(p.id) total,count(p.id) filter(where p.review_status='needs_review') pending,
 count(p.id) filter(where p.review_status='approved') approved,
 count(p.id) filter(where p.review_status='rejected') rejected,count(p.id) filter(where p.review_status='later') later,
 count(p.id) filter(where p.safe and not p.contacted and not p.stopped) ready,
 count(p.id) filter(where p.contacted) contacted,count(p.id) filter(where p.replied) replies,
 count(p.id) filter(where p.source_sheet='HVAC' and p.review_status='approved' and not p.previously_contacted and p.approved_at>=r.campaign_started_at and not p.email_verified and p.send_blocker='campaign_not_approved') checking_email,
 count(p.id) filter(where p.source_sheet='HVAC' and p.review_status='approved' and p.approved_at<r.campaign_started_at) needs_reapproval
 from public.sectors s cross join public.outreach_runtime r left join rows p on p.sector_id=s.id where r.id group by s.id,s.name)
 select coalesce(jsonb_agg(counts order by name),'[]'::jsonb) from counts);
end $$;

commit;
