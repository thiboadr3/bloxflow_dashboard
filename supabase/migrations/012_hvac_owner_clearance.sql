-- Explicit owner permission received 17 October 2026: release only source-new HVAC stage 0.
-- Source data and previous reviews are preserved. All real contact history still wins.
begin;
create table public.hvac_stock_clearance (
 prospect_id uuid primary key references public.prospects(id),
 source_record_id uuid not null references public.source_records(id),
 prior_previously_contacted boolean not null,prior_send_blocker text,
 approved_by text not null default 'thibo@bloxflow.be',
 evidence text not null default 'Owner explicitly released source-new HVAC step 0 on 2026-10-17',
 released_at timestamptz not null default now()
);
alter table public.hvac_stock_clearance enable row level security;
revoke all on public.hvac_stock_clearance from public,anon,authenticated;
create temporary table stock_candidates on commit drop as
select p.id,p.source_record_id,p.previously_contacted,p.send_blocker,
 public.bloxflow_identity_keys(to_jsonb(p)) as identity_keys
from public.prospects p join public.source_records r on r.id=p.source_record_id
join public.sectors s on s.id=p.sector_id
where s.source_sheet='HVAC' and p.archived_at is null
and r.raw_data->>'Status' in('needs_review','Nieuw prospect') and r.raw_data->>'sequence_step'='0';
do $$ begin
if (select count(*) from stock_candidates)<>2632 then raise exception 'Source-new stock changed; review required';end if;
end $$;
-- Materialize normalized keys once, rather than repeating normalization for each pair.
create temporary table blocked_keys on commit drop as
select identity_keys from public.contact_history_archive
union all select public.bloxflow_identity_keys(to_jsonb(s)) from public.suppressions s
union all select identity_keys from public.outreach_blocks;
create index on blocked_keys using gin(identity_keys);
insert into public.hvac_stock_clearance(prospect_id,source_record_id,prior_previously_contacted,prior_send_blocker)
select c.id,c.source_record_id,c.previously_contacted,c.send_blocker from stock_candidates c
where not exists(select 1 from blocked_keys b where b.identity_keys && c.identity_keys);
update public.prospects p set previously_contacted=false,automation_allowed=false,
 send_blocker=case when p.review_status='approved' then 'campaign_not_approved' else 'not_approved' end,
 updated_at=clock_timestamp()
from public.hvac_stock_clearance c where c.prospect_id=p.id;
-- Deliberately leave the campaign paused until clearance results have been verified.
commit;
select count(*) as released from public.hvac_stock_clearance;
