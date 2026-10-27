-- Snellere dubbel-controles: identiteitssleutels van prospects en suppressions worden één keer
-- berekend en opgeslagen (generated column) met een GIN-index, in plaats van bij elke controle
-- voor alle ~11.000 rijen opnieuw. Gedrag blijft identiek: dezelfde functie, dezelfde velden.

-- jsonb_build_object is niet IMMUTABLE gemarkeerd; deze wrapper wel (zelfde resultaat voor dezelfde invoer).
create or replace function public.bloxflow_identity_keys_of(p_company text, p_website text, p_domain text, p_email text,
  p_phone text, p_kbo text, p_municipality text) returns text[]
language sql immutable set search_path = '' as $$
  select public.bloxflow_identity_keys(jsonb_build_object('company_name',p_company,'website_url',p_website,
    'normalized_domain',p_domain,'email',p_email,'phone',p_phone,'kbo_number',p_kbo,'municipality',p_municipality));
$$;

alter table public.prospects add column if not exists identity_keys text[] generated always as (
  public.bloxflow_identity_keys_of(company_name, website_url, normalized_domain, email, phone, kbo_number, municipality)
) stored;
create index if not exists prospects_identity_keys on public.prospects using gin (identity_keys);

alter table public.suppressions add column if not exists identity_keys text[] generated always as (
  public.bloxflow_identity_keys_of(company_name, null, domain, email, null, kbo_number, null)
) stored;
alter table public.suppressions add column if not exists name_norm text generated always as (
  lower(regexp_replace(coalesce(company_name,''),'[^[:alnum:]]','','g'))
) stored;
create index if not exists suppressions_identity_keys on public.suppressions using gin (identity_keys);
create index if not exists suppressions_name_norm on public.suppressions (name_norm);

-- Eén controle, nu volledig via indexen.
create or replace function public.bloxflow_autopilot_known(p_keys text[],p_name text,p_place text default null) returns text
language plpgsql stable security definer set search_path='' as $$
declare n text:=lower(regexp_replace(coalesce(p_name,''),'[^[:alnum:]]','','g'));begin
 if exists(select 1 from public.suppressions s where s.identity_keys && p_keys)
  or (length(n)>=5 and exists(select 1 from public.suppressions s where s.name_norm=n)) then return 'suppression';end if;
 if exists(select 1 from public.contact_history_archive h where h.identity_keys && p_keys) then return 'contacthistoriek';end if;
 if exists(select 1 from public.outreach_blocks b where b.identity_keys && p_keys) then return 'geblokkeerd';end if;
 if exists(select 1 from public.outreach_jobs j where j.identity_keys && p_keys) then return 'al_in_mailreeks';end if;
 if exists(select 1 from public.prospects p where p.identity_keys && p_keys) then return 'al_in_database';end if;
 if exists(select 1 from public.outreach_autopilot_candidates c where c.identity_keys && p_keys)
  or (p_place is not null and exists(select 1 from public.outreach_autopilot_candidates c where c.place_id=p_place)) then return 'al_beoordeeld';end if;
 return null;
end $$;
create index if not exists autopilot_candidate_place on public.outreach_autopilot_candidates (place_id);

-- Hele zoekresultaat in één call: sleutels berekenen + controleren.
-- In: [{website_url, phone, company_name, municipality, email?, place_id?}, ...]
-- Uit: [{keys: [...], reason: text|null}, ...] in dezelfde volgorde.
create or replace function public.bloxflow_autopilot_check(p_items jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('keys',to_jsonb(k.keys),
   'reason',public.bloxflow_autopilot_known(k.keys,i.value->>'company_name',nullif(i.value->>'place_id',''))) order by i.ord),'[]'::jsonb)
 from jsonb_array_elements(p_items) with ordinality i(value,ord)
 cross join lateral (select public.bloxflow_identity_keys(i.value - 'place_id') keys) k;
$$;
revoke all on function public.bloxflow_autopilot_check(jsonb) from public,anon,authenticated;
grant execute on function public.bloxflow_autopilot_check(jsonb) to service_role;

-- Mailworker en antwoord-functies: opgeslagen sleutels gebruiken i.p.v. herberekenen.
do $$
declare f text; def text; new_def text;
begin
  foreach f in array array['bloxflow_job_safe','bloxflow_reserve','bloxflow_future_reply_safe','bloxflow_queue_future_reply'] loop
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f;
    new_def := replace(def, 'public.bloxflow_identity_keys(to_jsonb(s))', 's.identity_keys');
    new_def := replace(new_def, 'public.bloxflow_identity_keys(to_jsonb(candidate_prospect))', 'candidate_prospect.identity_keys');
    new_def := replace(new_def, 'public.bloxflow_identity_keys(to_jsonb(p))', 'coalesce(p.identity_keys,public.bloxflow_identity_keys(to_jsonb(p)))');
    if new_def is distinct from def then execute new_def; end if;
  end loop;
end $$;
