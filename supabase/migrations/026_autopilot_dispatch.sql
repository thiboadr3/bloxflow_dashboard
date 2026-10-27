-- Supabase start de piloot zelf (GitHub's eigen planner loopt uren achter of slaat runs over).
-- Vereist één Vault-secret, door Thibo zelf aan te maken in de SQL Editor:
--   select vault.create_secret('<fine-grained GitHub token, Actions: read & write op bloxflow_dashboard>', 'github_dispatch_token');
-- Zonder die secret doet dit niets (geen fouten).
--
-- Werkdagen:
--   04:00  start de piloot via de GitHub API (workflow_dispatch, echte run)
--   07:30  nog geen run gestart vandaag?  → Telegram-melding + één nieuwe startpoging
--   (de geplande GitHub-run om 06:47 blijft als reserve; een tweede run stopt meteen als de daglimiet al gehaald is)

alter table public.outreach_notify_state
  add column if not exists last_dispatch date,
  add column if not exists last_dispatch_check date;

create or replace function public.bloxflow_autopilot_dispatch() returns boolean
language plpgsql security definer set search_path = '' as $$
declare tok text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'github_dispatch_token';
  if tok is null then return false; end if;
  perform net.http_post(
    url := 'https://api.github.com/repos/thiboadr3/bloxflow_dashboard/actions/workflows/autopilot.yml/dispatches',
    body := jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('dry_run', 'false')),
    headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'bloxflow-supabase'),
    timeout_milliseconds := 10000);
  return true;
end $$;
revoke execute on function public.bloxflow_autopilot_dispatch() from public, anon, authenticated;

create or replace function public.bloxflow_autopilot_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare
  t time := (now() at time zone 'Europe/Brussels')::time;
  d date := (now() at time zone 'Europe/Brussels')::date;
  workday boolean := extract(isodow from (now() at time zone 'Europe/Brussels')) between 1 and 5;
  s public.outreach_notify_state; enabled boolean; started boolean;
begin
  if not workday then return; end if;
  select a.enabled into enabled from public.outreach_autopilot_settings a where a.id;
  if not coalesce(enabled, false) then return; end if;
  select * into s from public.outreach_notify_state where id for update;
  started := exists (select 1 from public.outreach_autopilot_runs r
                     where (r.started_at at time zone 'Europe/Brussels')::date = d);

  if t >= time '04:00' and t < time '07:30' and s.last_dispatch is distinct from d then
    if not started then perform public.bloxflow_autopilot_dispatch(); end if;
    update public.outreach_notify_state set last_dispatch = d where id;
  end if;

  if t >= time '07:30' and t < time '12:00' and s.last_dispatch_check is distinct from d then
    if not started then
      if public.bloxflow_autopilot_dispatch() then
        perform public.bloxflow_telegram('⚠️ Piloot was om 07:30 nog niet gestart. Ik heb hem opnieuw gestart.');
      else
        perform public.bloxflow_telegram('⚠️ Piloot was om 07:30 nog niet gestart en de GitHub-sleutel ontbreekt in Supabase.');
      end if;
    end if;
    update public.outreach_notify_state set last_dispatch_check = d where id;
  end if;
end $$;
revoke execute on function public.bloxflow_autopilot_tick() from public, anon, authenticated;

-- Vandaag (dag van invoering) niet automatisch starten: de run van vandaag wordt handmatig gestart na de merge van PR #7.
update public.outreach_notify_state
  set last_dispatch = (now() at time zone 'Europe/Brussels')::date,
      last_dispatch_check = (now() at time zone 'Europe/Brussels')::date
  where id;

select cron.schedule('bloxflow-autopilot-start', '*/15 * * * *', 'select public.bloxflow_autopilot_tick()');

-- Voor run.py: hoeveel er vandaag al ingepland zijn (zodat een tweede run niets dubbel doet).
create or replace function public.bloxflow_autopilot_planned_today() returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.prospects where autopilot_run_id is not null
    and (approved_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date;
$$;
revoke all on function public.bloxflow_autopilot_planned_today() from public, anon, authenticated;
grant execute on function public.bloxflow_autopilot_planned_today() to service_role;
