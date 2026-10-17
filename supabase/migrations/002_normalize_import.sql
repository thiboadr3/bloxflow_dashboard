begin;
do $$ begin
 if exists(select 1 from public.import_batches b where b.source_row_count<>(select count(*) from public.source_records r where r.batch_id=b.id)) then
 raise exception 'Import onvolledig: bronaantallen komen niet overeen'; end if;
end $$;
create unique index if not exists prospect_source_unique on public.prospects(source_record_id);
create unique index if not exists suppression_source_unique on public.suppressions(source_record_id);
with source as (
 select r.id,r.raw_data as d,s.id as sector_id,
 lower(regexp_replace(split_part(regexp_replace(trim(coalesce(r.raw_data->>'Website URL','')),'^https?://','','i'),'/',1),'^www\.','','i')) as domain,
 lower(trim(coalesce(r.raw_data->>'Email',''))) as normalized_email
 from public.source_records r join public.import_batches b on b.id=r.batch_id
 join public.sectors s on s.source_sheet=b.source_sheet
 where nullif(trim(r.raw_data->>'Naam'),'') is not null
), ranked as (
 select *,row_number() over(partition by sector_id,coalesce(nullif(domain,''),nullif(normalized_email,''),lower(trim(d->>'Naam'))||'|'||coalesce(d->>'gemeente',d->>'Gemeente','')) order by (d->>'approved_by_user'='Ja') desc nulls last,id) as duplicate_rank from source
)
insert into public.prospects(sector_id,company_name,website_url,normalized_domain,email,normalized_email,phone,normalized_phone,kbo_number,municipality,source_url,fit_reason,subniche,review_status,previously_contacted,automation_allowed,send_blocker,reply_type,reply_summary,outcome,source_record_id)
select sector_id,d->>'Naam',nullif(d->>'Website URL',''),nullif(domain,''),nullif(d->>'Email',''),nullif(normalized_email,''),d->>'Telefoon',regexp_replace(coalesce(d->>'Telefoon',''),'[^0-9]','','g'),coalesce(d->>'KBO',d->>'kbo_number'),coalesce(d->>'gemeente',d->>'Gemeente'),coalesce(d->>'source_url',d->>'Google Maps URL',d->>'Website URL'),coalesce(d->>'fit_feedback',d->>'icp_fit_reason',d->>'Waarom opnemen',d->>'Sourcing note (auto)'),d->>'niche',
 case when coalesce(d->>'website_screening_result','') like 'uitsluiten%' then 'rejected' when d->>'approved_by_user'='Ja' then 'approved' else 'needs_review' end,
 true,false,'previously_contacted',d->>'reply_type',coalesce(d->>'reply_summary',d->>'Antwoord:'),d->>'outcome',id
from ranked where duplicate_rank=1
on conflict(source_record_id) do nothing;
insert into public.suppressions(email,domain,company_name,reason,source_record_id)
select nullif(lower(trim(r.raw_data->>'email')),''),nullif(lower(trim(r.raw_data->>'domain')),''),nullif(r.raw_data->>'company',''),
 case when coalesce(r.raw_data->>'reason','') in ('','#REF!','#ERROR!') then 'Bestaande blokkering uit Google Sheets; oorspronkelijke foutwaarde bewaard in bronrecord' else r.raw_data->>'reason' end,r.id
from public.source_records r join public.import_batches b on b.id=r.batch_id
where b.source_sheet='Suppression' and (nullif(r.raw_data->>'email','') is not null or nullif(r.raw_data->>'domain','') is not null or nullif(r.raw_data->>'company','') is not null)
on conflict(source_record_id) do nothing;
update public.import_batches b set status='imported',imported_row_count=(select count(*) from public.source_records r where r.batch_id=b.id);
commit;
select (select count(*) from public.source_records) as bronrijen,(select count(*) from public.prospects) as sectorprospecten,(select count(*) from public.suppressions) as blokkeringen,(select count(*) from public.prospects where automation_allowed) as automatisch_verzendbaar,(select paused from public.sending_settings) as verzending_gepauzeerd;
