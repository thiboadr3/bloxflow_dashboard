begin;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$ declare token text;begin
if not exists(select 1 from vault.secrets where name='bloxflow_hvac_worker_token') then
 token:=encode(extensions.gen_random_bytes(32),'hex');perform vault.create_secret(token,'bloxflow_hvac_worker_token','Private HVAC worker authentication');
else select decrypted_secret into token from vault.decrypted_secrets where name='bloxflow_hvac_worker_token';end if;
update public.outreach_runtime set worker_token_hash=encode(extensions.digest(token,'sha256'),'hex') where id;
end $$;
select cron.schedule('bloxflow-hvac-worker','* * * * *',$cron$
select net.http_post(url:='https://dzygpjozhixnkbtfupqj.supabase.co/functions/v1/hvac-worker',headers:=jsonb_build_object('Content-Type','application/json','x-bloxflow-worker',(select decrypted_secret from vault.decrypted_secrets where name='bloxflow_hvac_worker_token')),body:='{}'::jsonb,timeout_milliseconds:=60000);
$cron$);
commit;
select 'Scheduler ingericht; verzending blijft gepauzeerd' as resultaat;
