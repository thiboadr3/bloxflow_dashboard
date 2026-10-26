-- Piloot beoordeelt eerst bedrijven uit onze eigen database die nog nooit gemaild zijn
-- (vooral ±700 HVAC-bedrijven met website: 'later', 'needs_review' of geïmporteerd als 'rejected' zonder beoordeling).
-- Handmatig afgekeurde bedrijven (reviewed_at gevuld of met reden) blijven afgekeurd.

create or replace function public.bloxflow_autopilot_backlog(p_sector text, p_limit int default 40, p_exclude uuid[] default '{}')
returns table(id uuid, company_name text, website_url text, email text, phone text, municipality text, identity_keys text[])
language sql stable security definer set search_path='' as $$
 select p.id, p.company_name, p.website_url, p.email, p.phone, p.municipality, p.identity_keys
 from public.prospects p join public.sectors s on s.id = p.sector_id
 where s.source_sheet = p_sector and s.autopilot
   and p.archived_at is null and not p.previously_contacted
   and coalesce(p.website_url, '') <> '' and not (p.id = any(coalesce(p_exclude, '{}')))
   and (p.review_status in ('later', 'needs_review')
        or (p.review_status = 'rejected' and p.reviewed_at is null and not p.website_checked and p.review_reason is null))
   and not exists (select 1 from public.outreach_jobs j where j.prospect_id = p.id)
   and not exists (select 1 from public.outreach_autopilot_candidates c where c.prospect_id = p.id)
 order by p.created_at
 limit greatest(1, least(coalesce(p_limit, 40), 100));
$$;
create index if not exists autopilot_candidate_prospect on public.outreach_autopilot_candidates (prospect_id);

create or replace function public.bloxflow_autopilot_promote(p_id uuid, p jsonb, p_run uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare cfg public.outreach_autopilot_settings; pr public.prospects; today int; why text; new_email text;
begin
 select * into cfg from public.outreach_autopilot_settings where id for update;
 if not cfg.enabled then raise exception 'Piloot staat uit'; end if;
 select count(*) into today from public.prospects where autopilot_run_id is not null
  and (approved_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date;
 if today >= cfg.daily_new_limit then return null; end if;

 select * into pr from public.prospects where id = p_id for update;
 if not found or pr.archived_at is not null or pr.previously_contacted or pr.review_status = 'approved' then return null; end if;
 if exists (select 1 from public.outreach_jobs j where j.prospect_id = p_id) then return null; end if;

 new_email := lower(trim(coalesce(p->>'email', '')));
 why := public.bloxflow_autopilot_known(
          pr.identity_keys || public.bloxflow_identity_keys(jsonb_build_object('email', new_email)), pr.company_name, null);
 if why in ('suppression', 'contacthistoriek', 'geblokkeerd', 'al_in_mailreeks') then return null; end if;

 -- E-mail: nieuw publiek adres van de website (met bewijs), anders het bestaande adres als dat bruikbaar is.
 if coalesce(p->>'email_evidence_url', '') <> ''
    and new_email ~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$' then
   update public.prospects set email = new_email, normalized_email = new_email, email_verified = true,
     email_evidence_url = p->>'email_evidence_url', email_checked_at = now(), email_check_status = 'autopilot_public_page'
   where id = p_id;
 elsif not public.bloxflow_email_ready(pr) then
   return null;
 end if;

 update public.prospects set
   review_status = 'approved', review_reason = 'autopilot (database): ' || left(p->>'fit_reason', 1880),
   reviewed_at = now(), approved_at = now(), approved_by = 'autopilot', website_checked = true,
   fit_reason = left(p->>'fit_reason', 2000), subniche = coalesce(pr.subniche, p->>'subniche'),
   automation_allowed = true, send_blocker = 'none', autopilot_run_id = p_run, website_assessment = p->'assessment'
 where id = p_id;
 return p_id;
end $$;

revoke all on function public.bloxflow_autopilot_backlog(text, int, uuid[]), public.bloxflow_autopilot_promote(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.bloxflow_autopilot_backlog(text, int, uuid[]), public.bloxflow_autopilot_promote(uuid, jsonb, uuid) to service_role;
