-- Activate only after explicit stock clearance and owner-only send test.
begin;
do $$ begin
if (select count(*) from public.hvac_stock_clearance)<>2625 then raise exception 'Clearance not verified';end if;
if not exists(select 1 from public.outreach_self_tests where id='57b753f1-32a0-4216-9403-959ec2f35ed7' and status='passed') then raise exception 'Send test incomplete';end if;
if not exists(select 1 from public.outreach_runtime where id and worker_verified and history_id is not null and last_sync_at>now()-interval '5 minutes' and last_error is null) then raise exception 'Mailbox sync unhealthy';end if;
if not exists(select 1 from cron.job where jobname='bloxflow-hvac-worker' and active) then raise exception 'Scheduler inactive';end if;
if not exists(select 1 from public.gmail_connections where email='thibo@bloxflow.be') then raise exception 'Mailbox missing';end if;
end $$;
update public.outreach_runtime set enabled=true,campaign_started_at=coalesce(campaign_started_at,clock_timestamp()),daily_limit=600,step_limit=200,followup_days=array[3,3],business_days=true where id;
update public.sending_settings set paused=false where id and gmail_connected;
update public.gmail_connections set sending_enabled=true where email='thibo@bloxflow.be';
do $$ begin
if not exists(select 1 from public.sending_settings where id and not paused and gmail_connected) then raise exception 'Sending settings not ready';end if;
end $$;
commit;
select enabled,worker_verified,campaign_started_at,followup_days from public.outreach_runtime where id;
