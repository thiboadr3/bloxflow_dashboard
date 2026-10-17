begin;
alter table public.prospects add column if not exists archived_at timestamptz;
alter table public.prospects add column if not exists archive_reason text;
create table if not exists public.contact_history_archive (
 id uuid primary key default gen_random_uuid(),
 source_record_id uuid unique references public.source_records(id),
 sector text not null,
 company_name text,
 identity_keys text[] not null,
 reason text not null,
 evidence jsonb not null,
 archived_at timestamptz not null default now()
);
alter table public.contact_history_archive enable row level security;
revoke all on public.contact_history_archive from public,anon,authenticated;
create index if not exists contact_history_identity_keys on public.contact_history_archive using gin(identity_keys);
create or replace function public.bloxflow_identity_keys(d jsonb) returns text[] language sql immutable set search_path='' as $$
 with v as (select
 lower(trim(coalesce(nullif(d->>'email',''),d->>'Email',''))) email,
 lower(regexp_replace(split_part(regexp_replace(trim(coalesce(nullif(d->>'normalized_domain',''),nullif(d->>'domain',''),nullif(d->>'website_url',''),d->>'Website URL','')),'^https?://','','i'),'/',1),'^www\.','','i')) domain,
 regexp_replace(regexp_replace(coalesce(nullif(d->>'phone',''),d->>'Telefoon',''),'[^0-9]','','g'),'^(0032|32)','0') phone,
 regexp_replace(coalesce(d->>'kbo_number',d->>'KBO',''),'[^0-9]','','g') kbo,
 lower(regexp_replace(trim(coalesce(d->>'company_name',d->>'Naam','')),'[^[:alnum:]]','','g')) name,
 lower(regexp_replace(trim(coalesce(d->>'municipality',d->>'gemeente',d->>'Gemeente','')),'[^[:alnum:]]','','g')) municipality)
 select array_remove(array[
 case when length(kbo)=10 then 'kbo:'||kbo end,
 case when domain<>'' and domain like '%.%' then 'domain:'||rtrim(domain,'.') end,
 case when email like '%@%.%' then 'email:'||email end,
 case when length(phone)>=9 then 'phone:'||phone end,
 case when name<>'' and municipality<>'' then 'nameplace:'||name||':'||municipality end],null) from v;
$$;
revoke all on function public.bloxflow_identity_keys(jsonb) from public,anon,authenticated;

-- Source rows and contact fields were compared with the live Sheet before execution.
do $$ begin
 if (select count(*) from public.source_records where batch_id='20261016-0000-4000-8000-000000000001')<>3673 then raise exception 'HVAC bron gewijzigd; vergelijk opnieuw';end if;
 if (select md5(string_agg(b.source_sheet||':'||r.source_row::text||':'||(select md5(string_agg(trim(coalesce(r.raw_data->>k,'')),chr(31) order by n)) from unnest(array['Naam','Website URL','Email','Telefoon','Status','Geantwoord','sequence_step','last_email_date','Laatste contact op','reply_date','reply_type','stop_reason','normalized_status','sector']) with ordinality t(k,n))||chr(10),'' order by b.source_sheet collate "C",r.source_row)) from public.source_records r join public.import_batches b on b.id=r.batch_id where b.source_sheet in ('Contacted Archive','HVAC','HVAC Snapshot 2026-05-17'))<>'00e3e039c1cc1e9ccfa74bb599d8d07e' then raise exception 'Historiek verschilt van live vergelijking';end if;
end $$;
insert into public.contact_history_archive(source_record_id,sector,company_name,identity_keys,reason,evidence)
select r.id,'HVAC',r.raw_data->>'Naam',public.bloxflow_identity_keys(r.raw_data),'already_contacted',
 jsonb_build_object('sheet',b.source_sheet,'row',r.source_row,'status',r.raw_data->>'Status','sequence_step',r.raw_data->>'sequence_step','last_email_date',r.raw_data->>'last_email_date','last_contact',r.raw_data->>'Laatste contact op','reply_type',r.raw_data->>'reply_type')
from public.source_records r join public.import_batches b on b.id=r.batch_id
where b.source_sheet in ('HVAC','Contacted Archive','HVAC Snapshot 2026-05-17')
 and (b.source_sheet<>'Contacted Archive' or upper(coalesce(r.raw_data->>'sector',''))='HVAC')
 and (b.source_sheet='Contacted Archive'
 or coalesce(r.raw_data->>'sequence_step','') ~ '^[1-9][0-9]*$'
 or lower(coalesce(r.raw_data->>'Geantwoord','')) in ('ja','yes','true')
 or coalesce(r.raw_data->>'Status','') ~* '(verstuurd|antwoord|reply|bounced|delivery issue|opt.out|vraag ontvangen|out of office)'
 or coalesce(r.raw_data->>'normalized_status','') ~* '(mailed|replied|bounced|opt.out)'
 or coalesce(r.raw_data->>'last_email_date','') ~ '^[0-9]'
 or coalesce(r.raw_data->>'Laatste contact op','') ~ '^[0-9]'
 or coalesce(r.raw_data->>'reply_date','') ~ '^[0-9]')
on conflict(source_record_id) do nothing;

-- Preserve every operational row and review. Hide only matched HVAC contacts.
update public.prospects p set archived_at=coalesce(p.archived_at,now()),archive_reason='already_contacted',previously_contacted=true,automation_allowed=false,send_blocker='previously_contacted',updated_at=clock_timestamp()
where (p.sector_id in(select id from public.sectors where source_sheet='HVAC')
 or p.source_record_id in(select r.id from public.source_records r join public.import_batches b on b.id=r.batch_id where b.source_sheet='HVAC'))
and exists(select 1 from public.contact_history_archive h where h.identity_keys && public.bloxflow_identity_keys(to_jsonb(p)) or h.source_record_id=p.source_record_id);
update public.enrollments e set status='stopped',stopped_at=now(),stop_reason='historical_contact_archived'
where e.status in ('active','queued') and exists(select 1 from public.prospects p where p.id=e.prospect_id and p.archived_at is not null);

-- A future imported copy cannot be activated by changing its review or sector.
create or replace function public.bloxflow_guard_contact_history() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' then
  if old.archived_at is not null and (new.review_status is distinct from old.review_status or new.sector_id is distinct from old.sector_id) then raise exception 'Al gecontacteerd: dit bedrijf staat in het archief';end if;
  if old.archived_at is not null then new.archived_at:=old.archived_at;end if;
 end if;
 if new.archived_at is not null or exists(select 1 from public.contact_history_archive h where h.identity_keys && public.bloxflow_identity_keys(to_jsonb(new)) or h.source_record_id=new.source_record_id) then
  new.archived_at:=coalesce(new.archived_at,now());new.archive_reason:='already_contacted';new.previously_contacted:=true;new.automation_allowed:=false;new.send_blocker:='previously_contacted';
 end if;
 return new;
end $$;
revoke all on function public.bloxflow_guard_contact_history() from public,anon,authenticated;
create trigger bloxflow_contact_history_guard before insert or update on public.prospects for each row execute function public.bloxflow_guard_contact_history();
alter policy bloxflow_owner_read_prospects on public.prospects using ((select auth.jwt()->>'email')='thibo@bloxflow.be' and archived_at is null);

create or replace function public.bloxflow_sector_summary() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(x order by name),'[]'::jsonb) from (select s.id,s.name,count(p.id) filter(where p.archived_at is null) total,count(p.id) filter(where p.archived_at is null and p.review_status='needs_review') pending,count(p.id) filter(where p.archived_at is null and p.review_status='approved') approved,count(p.id) filter(where p.archived_at is null and p.review_status='rejected') rejected,count(p.id) filter(where p.archived_at is null and p.review_status='later') later,count(p.id) filter(where p.archived_at is null and p.automation_allowed) ready,count(p.id) filter(where p.archived_at is not null) contacted_archive from public.sectors s left join public.prospects p on p.sector_id=s.id group by s.id,s.name)x);
end $$;
create or replace function public.bloxflow_subsectors(p_sector uuid default null,p_status text default 'needs_review') returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x.subniche order by x.subniche),'[]'::jsonb) from(select distinct subniche from public.prospects where archived_at is null and (p_sector is null or sector_id=p_sector) and review_status=p_status and nullif(trim(subniche),'') is not null)x);
end $$;
commit;
select (select count(*) from public.contact_history_archive) as history_rows,(select count(*) from public.prospects where archived_at is not null) as archived_prospects,(select count(*) from public.prospects where automation_allowed) as enabled;
