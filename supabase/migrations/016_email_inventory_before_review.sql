-- Owner instruction: use the email supplied by sourcing; never crawl after review.
-- source_provided means import provenance, not a fresh website verification.
begin;
create table if not exists public.email_inventory_audit(id bigint generated always as identity primary key,prospect_id uuid not null,prior_record jsonb not null,action text not null,source_url text,changed_at timestamptz not null default now());
alter table public.email_inventory_audit enable row level security;
revoke all on public.email_inventory_audit from public,anon,authenticated;
insert into public.email_inventory_audit(prospect_id,prior_record,action)
select p.id,to_jsonb(p),'adopt_source_email' from public.prospects p join public.source_records r on r.id=p.source_record_id
where p.archived_at is null and not p.email_verified
and p.email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$'
and lower(trim(p.email))=lower(trim(r.raw_data->>'Email'));
update public.prospects p set email_check_status='source_provided',updated_at=clock_timestamp()
from public.source_records r where p.source_record_id=r.id and p.archived_at is null and not p.email_verified
and p.email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$'
and lower(trim(p.email))=lower(trim(r.raw_data->>'Email'));
create or replace function public.bloxflow_email_ready(p public.prospects) returns boolean
language sql stable security definer set search_path='' as $$
select coalesce(p.email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$'
and ((p.email_verified and p.email_evidence_url is not null) or
(p.email_check_status='source_provided' and exists(select 1 from public.source_records r where r.id=p.source_record_id and lower(trim(p.email))=lower(trim(r.raw_data->>'Email'))))),false);
$$;
revoke all on function public.bloxflow_email_ready(public.prospects) from public,anon,authenticated;
grant execute on function public.bloxflow_email_ready(public.prospects) to service_role;
do $$declare f text;begin
 f:=pg_get_functiondef('public.bloxflow_job_safe(public.prospects)'::regprocedure);
 if position('p.email_verified' in f)=0 then raise exception 'Unexpected job gate definition';end if;
 execute replace(f,'p.email_verified','public.bloxflow_email_ready(p)');
 f:=pg_get_functiondef('public.bloxflow_sector_summary()'::regprocedure);
 f:=replace(f,'p.email_verified','public.bloxflow_email_ready(p)');
 -- rows is a record with additional computed fields; the composite must be explicit.
 f:=replace(f,'not public.bloxflow_email_ready(p) and p.send_blocker', 'not (p.email_verified or p.email_check_status=''source_provided'') and p.send_blocker');
 execute f;
 f:=pg_get_functiondef('public.bloxflow_review(uuid,text,text,boolean,boolean,timestamp with time zone)'::regprocedure);
 if position('when p_decision=''approved'' then ''campaign_not_approved''' in f)=0 then raise exception 'Unexpected review definition';end if;
 execute replace(f,'when p_decision=''approved'' then ''campaign_not_approved''','when p_decision=''approved'' and public.bloxflow_email_ready(p) then ''none'' when p_decision=''approved'' then ''email_not_ready''');
end$$;
update public.prospects p set send_blocker='none',updated_at=clock_timestamp()
where p.archived_at is null and p.review_status='approved' and not p.previously_contacted
and p.send_blocker in('campaign_not_approved','no_verified_email') and public.bloxflow_email_ready(p);
alter table public.prospects add constraint active_prospect_requires_email check(archived_at is not null or coalesce(email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$',false));
create function public.bloxflow_require_source_email() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.archived_at is not null then return new;end if;
 if new.email is null or new.email !~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$' then raise exception 'Find a public business email during sourcing before adding an active prospect';end if;
 if tg_op='UPDATE' and new.email is distinct from old.email and new.email_checked_at is not distinct from old.email_checked_at then new.email_verified:=false;new.email_evidence_url:=null;end if;
 if tg_op='INSERT' or new.email is distinct from old.email then
  if exists(select 1 from public.source_records r where r.id=new.source_record_id and lower(trim(new.email))=lower(trim(r.raw_data->>'Email'))) then
   new.email_check_status:='source_provided';new.email_verified:=false;
  elsif not (new.email_verified and new.email_evidence_url is not null) then
   raise exception 'Store source email or public email evidence before importing';
  end if;
 end if;
 return new;
end$$;
revoke all on function public.bloxflow_require_source_email() from public,anon,authenticated;
create trigger prospects_require_source_email before insert or update of email,archived_at on public.prospects for each row execute function public.bloxflow_require_source_email();
select count(*) as actieve_bedrijven,count(*) filter(where not public.bloxflow_email_ready(p)) as email_niet_klaar from public.prospects p where archived_at is null;
do $$begin if exists(select 1 from public.prospects p where p.archived_at is null and not public.bloxflow_email_ready(p)) then raise exception 'Active inventory contains an email without provenance';end if;end$$;
commit;
