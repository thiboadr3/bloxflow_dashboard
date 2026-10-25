-- Automatische piloot (beslissing Thibo, 23 oktober 2026):
-- nieuwe bedrijven zoeken, website beoordelen en duidelijke prospects zonder handmatige review
-- in de mailreeks zetten. Alle bestaande veiligheidspoorten (contacthistoriek, suppression,
-- blokkades, e-mailbewijs, dag- en staplimieten, antwoordstop) blijven ongewijzigd van kracht.
-- De piloot staat UIT tot outreach_autopilot_settings.enabled expliciet op true wordt gezet.
begin;
set local lock_timeout = '5s';

-- 1. Welke sectoren de piloot mag vullen
alter table public.sectors add column if not exists autopilot boolean not null default false;
update public.sectors set autopilot=true
 where source_sheet in ('HVAC','DAK & GEVEL','TUINAANLEG','SCHRIJNWERK','RENOVATIE','METAALWERK','SOLAR');
do $$ begin
 if (select count(*) from public.sectors where autopilot)<>7 then
  raise exception 'Verwacht 7 bouwsectoren met autopilot; gevonden: %',(select string_agg(source_sheet,', ') from public.sectors where autopilot);
 end if;
end $$;

-- 2. De mailpoort accepteert naast HVAC ook de andere piloot-sectoren (zelfde mailtekst: algemeen voor de bouwsector)
do $$ declare f text; sig text; begin
 foreach sig in array array['public.bloxflow_job_safe(public.prospects)'] loop
  f:=pg_get_functiondef(sig::regprocedure);
  if position('s.source_sheet=''HVAC''' in f)=0 then raise exception 'Onverwachte definitie van %',sig;end if;
  execute replace(f,'s.source_sheet=''HVAC''','(s.source_sheet=''HVAC'' or s.autopilot)');
 end loop;
end $$;

-- 3. Instellingen, cursor en dagrapporten
create table if not exists public.outreach_autopilot_settings(
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 daily_new_limit integer not null default 200 check(daily_new_limit between 0 and 200),
 cursor jsonb not null default '{}'::jsonb,
 updated_at timestamptz not null default now());
insert into public.outreach_autopilot_settings(id) values(true) on conflict do nothing;

create table if not exists public.outreach_autopilot_candidates(
 id uuid primary key default gen_random_uuid(),
 identity_keys text[] not null,
 place_id text,
 company_name text,
 website_url text,
 sector text,
 decision text not null,
 reasons text,
 details jsonb,
 prospect_id uuid references public.prospects(id),
 run_id uuid,
 created_at timestamptz not null default now());
create index if not exists autopilot_candidate_keys on public.outreach_autopilot_candidates using gin(identity_keys);
create index if not exists autopilot_candidate_place on public.outreach_autopilot_candidates(place_id);

create table if not exists public.outreach_autopilot_runs(
 id uuid primary key default gen_random_uuid(),
 started_at timestamptz not null default now(),
 finished_at timestamptz,
 counts jsonb not null default '{}'::jsonb,
 report text);

alter table public.prospects add column if not exists autopilot_run_id uuid;
alter table public.prospects add column if not exists website_assessment jsonb;

alter table public.outreach_autopilot_settings enable row level security;
alter table public.outreach_autopilot_candidates enable row level security;
alter table public.outreach_autopilot_runs enable row level security;
revoke all on public.outreach_autopilot_settings,public.outreach_autopilot_candidates,public.outreach_autopilot_runs from public,anon,authenticated;
grant all on public.outreach_autopilot_settings,public.outreach_autopilot_candidates,public.outreach_autopilot_runs to service_role;

-- 4. Is dit bedrijf al gekend? (elke sector, ook gearchiveerd, contacthistoriek, suppression, blokkades, jobs, eerder beoordeeld)
create or replace function public.bloxflow_autopilot_known(p_keys text[],p_name text,p_place text default null) returns text
language plpgsql stable security definer set search_path='' as $$
declare n text:=lower(regexp_replace(coalesce(p_name,''),'[^[:alnum:]]','','g'));begin
 if exists(select 1 from public.suppressions s where public.bloxflow_identity_keys(to_jsonb(s)) && p_keys
   or (length(n)>=5 and lower(regexp_replace(coalesce(s.company_name,''),'[^[:alnum:]]','','g'))=n)) then return 'suppression';end if;
 if exists(select 1 from public.contact_history_archive h where h.identity_keys && p_keys) then return 'contacthistoriek';end if;
 if exists(select 1 from public.outreach_blocks b where b.identity_keys && p_keys) then return 'geblokkeerd';end if;
 if exists(select 1 from public.outreach_jobs j where j.identity_keys && p_keys) then return 'al_in_mailreeks';end if;
 if exists(select 1 from public.prospects p where public.bloxflow_identity_keys(to_jsonb(p)) && p_keys) then return 'al_in_database';end if;
 if exists(select 1 from public.outreach_autopilot_candidates c where c.identity_keys && p_keys or (p_place is not null and c.place_id=p_place)) then return 'al_beoordeeld';end if;
 return null;
end $$;

-- 5. Nieuwe, door de piloot goedgekeurde prospect toevoegen (met dagplafond)
create or replace function public.bloxflow_autopilot_insert(p jsonb,p_run uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare cfg public.outreach_autopilot_settings;sid uuid;new_id uuid;keys text[];today int;begin
 select * into cfg from public.outreach_autopilot_settings where id for update;
 if not cfg.enabled then raise exception 'Piloot staat uit';end if;
 select count(*) into today from public.prospects where autopilot_run_id is not null
  and (approved_at at time zone 'Europe/Brussels')::date=(now() at time zone 'Europe/Brussels')::date;
 if today>=cfg.daily_new_limit then return null;end if;
 select id into sid from public.sectors where source_sheet=p->>'sector' and autopilot;
 if sid is null then raise exception 'Sector niet toegelaten voor piloot: %',p->>'sector';end if;
 keys:=public.bloxflow_identity_keys(p);
 if public.bloxflow_autopilot_known(keys,p->>'company_name',null) in ('suppression','contacthistoriek','geblokkeerd','al_in_mailreeks','al_in_database') then return null;end if;
 if coalesce(p->>'email_evidence_url','')='' or (p->>'email') !~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$' then raise exception 'Geen publiek e-mailbewijs';end if;
 insert into public.prospects(sector_id,company_name,website_url,normalized_domain,email,normalized_email,phone,normalized_phone,municipality,source_url,fit_reason,subniche,
   review_status,review_reason,reviewed_at,approved_at,approved_by,website_checked,email_verified,email_evidence_url,email_checked_at,email_check_status,
   previously_contacted,automation_allowed,send_blocker,autopilot_run_id,website_assessment)
 values(sid,p->>'company_name',p->>'website_url',
   lower(regexp_replace(split_part(regexp_replace(p->>'website_url','^https?://','','i'),'/',1),'^www\.','','i')),
   lower(trim(p->>'email')),lower(trim(p->>'email')),p->>'phone',regexp_replace(coalesce(p->>'phone',''),'[^0-9]','','g'),p->>'municipality',
   p->>'source_url',left(p->>'fit_reason',2000),p->>'subniche',
   'approved','autopilot: '||left(p->>'fit_reason',1900),now(),now(),'autopilot',true,true,p->>'email_evidence_url',now(),'autopilot_public_page',
   false,true,'none',p_run,p->'assessment')
 returning id into new_id;
 return new_id;
end $$;

create or replace function public.bloxflow_autopilot_save_cursor(p_cursor jsonb) returns void
language sql security definer set search_path='' as $$
 update public.outreach_autopilot_settings set cursor=p_cursor,updated_at=now() where id;
$$;

revoke all on function public.bloxflow_autopilot_known(text[],text,text),public.bloxflow_autopilot_insert(jsonb,uuid),public.bloxflow_autopilot_save_cursor(jsonb) from public,anon,authenticated;
grant execute on function public.bloxflow_autopilot_known(text[],text,text),public.bloxflow_autopilot_insert(jsonb,uuid),public.bloxflow_autopilot_save_cursor(jsonb),public.bloxflow_identity_keys(jsonb) to service_role;

commit;
-- Activeren (pas na een geslaagde droge run):
--   update public.outreach_autopilot_settings set enabled=true, daily_new_limit=200 where id;
-- Noodstop:
--   update public.outreach_autopilot_settings set enabled=false where id;
