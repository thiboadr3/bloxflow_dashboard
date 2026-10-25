-- Telegram-updates voor de mailworker (Supabase-kant).
-- Vereist twee Vault-secrets, door Thibo zelf aan te maken in de SQL Editor:
--   select vault.create_secret('<bot token van BotFather>', 'telegram_bot_token');
--   select vault.create_secret('<chat id van het kanaal, bv. -100...>', 'telegram_chat_id');
-- Zonder die secrets doet alles hieronder niets (geen fouten, geen berichten).
--
-- Berichten (enkel aantallen, geen inhoud van mails of persoonsgegevens):
--   * werkdagen ±07:45  "Vandaag klaar": nieuwe mails + opvolgmails die vandaag kunnen vertrekken
--   * werkdagen ±18:00  dagrapport: verstuurd per mail, antwoorden, opt-outs, bounces, voorraad voor morgen
--   * meteen (binnen 15 min) als de mailworker een fout geeft of niet meer draait, en wanneer hij hersteld is

create table if not exists public.outreach_notify_state(
  id boolean primary key default true check (id),
  last_error text,
  stale_alerted boolean not null default false,
  last_morning date,
  last_evening date
);
insert into public.outreach_notify_state(id) values (true) on conflict (id) do nothing;
alter table public.outreach_notify_state enable row level security;
revoke all on public.outreach_notify_state from anon, authenticated;

create or replace function public.bloxflow_telegram(p_text text) returns void
language plpgsql security definer set search_path = '' as $$
declare tok text; chat text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into chat from vault.decrypted_secrets where name = 'telegram_chat_id';
  if tok is null or chat is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', left(p_text, 4000), 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke execute on function public.bloxflow_telegram(text) from public, anon, authenticated;

create or replace function public.bloxflow_telegram_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare
  t timestamp := now() at time zone 'Europe/Brussels';
  d date := (now() at time zone 'Europe/Brussels')::date;
  workday boolean := extract(isodow from (now() at time zone 'Europe/Brussels')) between 1 and 5;
  s public.outreach_notify_state;
  r public.outreach_runtime;
  n1 int; n2 int; n3 int; s1 int; s2 int; s3 int;
  rep int; opt int; bnc int; auto int; tomorrow int;
begin
  select * into s from public.outreach_notify_state where id for update;
  select * into r from public.outreach_runtime where id;

  -- 1. Foutmeldingen (elke tick)
  if r.last_error is distinct from s.last_error then
    if r.last_error is not null then
      perform public.bloxflow_telegram('⚠️ Mailworker meldt een fout: ' || r.last_error
        || E'\nVerzending wacht tot dit opgelost is.');
    elsif s.last_error is not null then
      perform public.bloxflow_telegram('✅ Mailworker hersteld, verzending loopt weer normaal.');
    end if;
    update public.outreach_notify_state set last_error = r.last_error where id;
  end if;
  if r.enabled and r.last_run_at < now() - interval '20 minutes' and not s.stale_alerted then
    perform public.bloxflow_telegram('⚠️ Mailworker draait niet meer sinds '
      || to_char(r.last_run_at at time zone 'Europe/Brussels', 'DD/MM HH24:MI') || '.');
    update public.outreach_notify_state set stale_alerted = true where id;
  elsif r.last_run_at >= now() - interval '20 minutes' and s.stale_alerted then
    perform public.bloxflow_telegram('✅ Mailworker draait opnieuw.');
    update public.outreach_notify_state set stale_alerted = false where id;
  end if;

  -- 2. Ochtendoverzicht (werkdagen, tussen 07:45 en 09:00)
  if workday and t::time >= time '07:45' and t::time < time '09:00' and s.last_morning is distinct from d then
    select count(*) filter (where next_step = 1), count(*) filter (where next_step = 2), count(*) filter (where next_step = 3)
      into n1, n2, n3
      from public.outreach_jobs where status = 'queued' and not is_test and due_at < (d + 1)::timestamp at time zone 'Europe/Brussels';
    perform public.bloxflow_telegram('☀️ Vandaag (' || to_char(d, 'DD/MM') || E') klaar om te versturen:\n'
      || '• ' || n1 || ' nieuwe bedrijven (mail 1)' || E'\n• ' || n2 || ' keer mail 2' || E'\n• ' || n3 || ' keer mail 3'
      || E'\nMaximum 200 per mail per dag, tussen 08 en 18u.');
    update public.outreach_notify_state set last_morning = d where id;
  end if;

  -- 3. Dagrapport (werkdagen, vanaf 18:00)
  if workday and t::time >= time '18:00' and s.last_evening is distinct from d then
    select count(*) filter (where step = 1), count(*) filter (where step = 2), count(*) filter (where step = 3)
      into s1, s2, s3
      from public.outreach_attempts where state = 'sent' and (sent_at at time zone 'Europe/Brussels')::date = d;
    select count(*) filter (where kind = 'reply'), count(*) filter (where kind = 'opt_out'),
           count(*) filter (where kind = 'delivery_issue'), count(*) filter (where kind = 'automatic_reply')
      into rep, opt, bnc, auto
      from public.outreach_messages where (received_at at time zone 'Europe/Brussels')::date = d;
    select count(*) into tomorrow from public.outreach_jobs where status = 'queued' and not is_test and next_step = 1;
    perform public.bloxflow_telegram('📊 Dagrapport ' || to_char(d, 'DD/MM') || E'\n'
      || 'Verstuurd: ' || s1 || ' × mail 1, ' || s2 || ' × mail 2, ' || s3 || E' × mail 3\n'
      || 'Binnengekomen: ' || rep || ' antwoorden, ' || opt || ' uitschrijvingen, ' || bnc || ' bounces, ' || auto || E' automatische antwoorden\n'
      || 'Voorraad nieuwe bedrijven: ' || tomorrow
      || case when rep > 0 then E'\n👉 Kijk je antwoorden na in het dashboard.' else '' end);
    update public.outreach_notify_state set last_evening = d where id;
  end if;
end $$;
revoke execute on function public.bloxflow_telegram_tick() from public, anon, authenticated;

select cron.schedule('bloxflow-telegram', '*/15 * * * *', 'select public.bloxflow_telegram_tick()');
