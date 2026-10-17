begin;
alter table public.prospects add column if not exists review_reason text;
alter table public.prospects add column if not exists reviewed_at timestamptz;
alter table public.prospects add column if not exists website_checked boolean not null default false;
alter table public.prospects add column if not exists email_verified boolean not null default false;
create policy bloxflow_owner_read_sectors on public.sectors for select to authenticated using ((select auth.jwt()->>'email')='thibo@bloxflow.be');
create policy bloxflow_owner_read_prospects on public.prospects for select to authenticated using ((select auth.jwt()->>'email')='thibo@bloxflow.be');
grant select on public.sectors,public.prospects to authenticated;
create or replace function public.bloxflow_review(p_id uuid,p_decision text,p_reason text,p_website_checked boolean,p_email_verified boolean,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.prospects; previous text;
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
 if p_decision not in ('approved','rejected','later') then raise exception 'Ongeldige keuze';end if;
 select * into p from public.prospects where id=p_id for update;
 if not found then raise exception 'Prospect niet gevonden';end if;
 if p.updated_at is distinct from p_expected_updated_at then raise exception 'De prospect is op een ander toestel gewijzigd. Vernieuw eerst de lijst.' using errcode='40001';end if;
 if p_decision='approved' and (not coalesce(p_website_checked,false) or not coalesce(p_email_verified,false) or length(trim(coalesce(p_reason,'')))<8 or nullif(trim(p.website_url),'') is null or nullif(trim(p.email),'') is null) then raise exception 'Controleer de website en het openbare e-mailadres en noteer een concrete verbeterkans';end if;
 previous:=p.review_status;
 update public.prospects set review_status=p_decision,review_reason=left(trim(p_reason),2000),reviewed_at=now(),website_checked=p_website_checked,email_verified=p_email_verified,approved_at=case when p_decision='approved' then now() else null end,approved_by=case when p_decision='approved' then auth.jwt()->>'email' else null end,automation_allowed=false,send_blocker=case when previously_contacted then 'previously_contacted' when p_decision='approved' then 'campaign_not_approved' else 'not_approved' end,updated_at=now() where id=p_id;
 insert into public.review_events(prospect_id,previous_status,decision,actor,notes) values(p_id,previous,p_decision,auth.jwt()->>'email',left(trim(p_reason),2000));
 update public.enrollments set status='stopped',stopped_at=now(),stop_reason='review_changed' where prospect_id=p_id and status in ('active','queued');
 return jsonb_build_object('saved',true,'automation_allowed',false);
end $$;
revoke all on function public.bloxflow_review(uuid,text,text,boolean,boolean,timestamptz) from public,anon;
grant execute on function public.bloxflow_review(uuid,text,text,boolean,boolean,timestamptz) to authenticated;
create or replace function public.bloxflow_sector_summary()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(x order by name),'[]'::jsonb) from (select s.id,s.name,count(p.id) total,count(p.id) filter(where p.review_status='needs_review') pending,count(p.id) filter(where p.review_status='approved') approved,count(p.id) filter(where p.review_status='rejected') rejected,count(p.id) filter(where p.review_status='later') later,count(p.id) filter(where p.automation_allowed) ready from public.sectors s left join public.prospects p on p.sector_id=s.id group by s.id,s.name)x);
end $$;
revoke all on function public.bloxflow_sector_summary() from public,anon;
grant execute on function public.bloxflow_sector_summary() to authenticated;
commit;
