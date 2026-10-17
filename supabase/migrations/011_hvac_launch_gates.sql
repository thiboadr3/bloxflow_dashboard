begin;
alter table public.outreach_runtime add column if not exists campaign_started_at timestamptz;
alter table public.prospects add column if not exists email_evidence_url text;
alter table public.prospects add column if not exists email_checked_at timestamptz;
alter table public.prospects add column if not exists email_check_status text;
create table public.outreach_self_tests(id uuid primary key default gen_random_uuid(),status text not null default 'reserved',gmail_ids text[] not null default '{}',thread_id text,created_at timestamptz not null default now(),completed_at timestamptz,checks jsonb);
alter table public.outreach_self_tests enable row level security;
revoke all on public.outreach_self_tests from public,anon,authenticated;
grant all on public.outreach_self_tests to service_role;
create function public.bloxflow_email_evidence(p_id uuid,p_expected timestamptz,p_verified boolean,p_url text,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare p public.prospects;begin
select * into p from public.prospects where id=p_id for update;
if not found or p.updated_at is distinct from p_expected or p.review_status<>'approved' or p.archived_at is not null or p.previously_contacted then return;end if;
if not exists(select 1 from public.sectors where id=p.sector_id and source_sheet='HVAC') then return;end if;
update public.prospects set email_verified=p_verified and p_url is not null,email_evidence_url=case when p_verified then p_url else null end,email_checked_at=now(),email_check_status=p_status,send_blocker=case when p_verified then 'campaign_not_approved' else 'no_verified_email' end,updated_at=clock_timestamp() where id=p.id;
end $$;
revoke all on function public.bloxflow_email_evidence(uuid,timestamptz,boolean,text,text) from public,anon,authenticated;
grant execute on function public.bloxflow_email_evidence(uuid,timestamptz,boolean,text,text) to service_role;
-- Older review decisions never start the newly activated campaign without a fresh approval.
create or replace function public.bloxflow_job_safe(p public.prospects) returns boolean language sql stable security definer set search_path='' as $$
 select p.review_status='approved' and p.archived_at is null and not p.previously_contacted and p.website_checked and p.email_verified
 and exists(select 1 from public.outreach_runtime r where r.id and r.campaign_started_at is not null and p.approved_at>=r.campaign_started_at)
 and p.email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$'
 and p.send_blocker in('none','campaign_not_approved')
 and exists(select 1 from public.sectors s where s.id=p.sector_id and s.source_sheet='HVAC')
 and not exists(select 1 from public.contact_history_archive h where h.identity_keys && public.bloxflow_identity_keys(to_jsonb(p)))
 and not exists(select 1 from public.suppressions s where public.bloxflow_identity_keys(to_jsonb(s)) && public.bloxflow_identity_keys(to_jsonb(p)))
 and not exists(select 1 from public.outreach_blocks b where b.identity_keys && public.bloxflow_identity_keys(to_jsonb(p)));
$$;
commit;
