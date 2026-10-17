begin;
create table if not exists public.sector_change_events (
 id uuid primary key default gen_random_uuid(),
 prospect_id uuid not null references public.prospects(id),
 previous_sector uuid references public.sectors(id),
 new_sector uuid not null references public.sectors(id),
 actor text not null,
 created_at timestamptz not null default now()
);
alter table public.sector_change_events enable row level security;
revoke all on public.sector_change_events from anon,authenticated;
create or replace function public.bloxflow_change_sector(p_id uuid,p_sector uuid,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.prospects;
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
 select * into p from public.prospects where id=p_id for update;
 if not found then raise exception 'Prospect niet gevonden';end if;
 if p.updated_at is distinct from p_expected_updated_at then raise exception 'De prospect is gewijzigd. Vernieuw eerst de lijst.' using errcode='40001';end if;
 if not exists(select 1 from public.sectors where id=p_sector) then raise exception 'Ongeldige sector';end if;
 if p.sector_id=p_sector then return jsonb_build_object('saved',true);end if;
 update public.prospects set sector_id=p_sector,subniche=null,review_status='needs_review',approved_at=null,approved_by=null,automation_allowed=false,send_blocker=case when previously_contacted then 'previously_contacted' else 'not_approved' end,updated_at=clock_timestamp() where id=p_id;
 insert into public.sector_change_events(prospect_id,previous_sector,new_sector,actor) values(p_id,p.sector_id,p_sector,auth.jwt()->>'email');
 update public.enrollments set status='stopped',stopped_at=now(),stop_reason='sector_changed' where prospect_id=p_id and status in ('active','queued');
 return jsonb_build_object('saved',true,'automation_allowed',false);
end $$;
revoke all on function public.bloxflow_change_sector(uuid,uuid,timestamptz) from public,anon;
grant execute on function public.bloxflow_change_sector(uuid,uuid,timestamptz) to authenticated;
commit;
