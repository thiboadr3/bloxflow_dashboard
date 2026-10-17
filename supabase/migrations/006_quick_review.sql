begin;
create or replace function public.bloxflow_review(p_id uuid,p_decision text,p_reason text,p_website_checked boolean,p_email_verified boolean,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.prospects; previous text;
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'email','')<>'thibo@bloxflow.be' then raise exception 'Geen toegang' using errcode='42501';end if;
 if p_decision not in ('approved','rejected','later') then raise exception 'Ongeldige keuze';end if;
 select * into p from public.prospects where id=p_id for update;
 if not found then raise exception 'Prospect niet gevonden';end if;
 if p.updated_at is distinct from p_expected_updated_at then raise exception 'De prospect is op een ander toestel gewijzigd. Vernieuw eerst de lijst.' using errcode='40001';end if;
 previous:=p.review_status;
 update public.prospects set review_status=p_decision,review_reason=coalesce(nullif(trim(p_reason),''),review_reason),reviewed_at=now(),website_checked=case when p_decision='approved' then true else website_checked end,approved_at=case when p_decision='approved' then now() else null end,approved_by=case when p_decision='approved' then auth.jwt()->>'email' else null end,automation_allowed=false,send_blocker=case when previously_contacted then 'previously_contacted' when p_decision='approved' and nullif(trim(website_url),'') is null then 'missing_website' when p_decision='approved' and nullif(trim(email),'') is null then 'missing_email' when p_decision='approved' then 'campaign_not_approved' else 'not_approved' end,updated_at=now() where id=p_id;
 insert into public.review_events(prospect_id,previous_status,decision,actor,notes) values(p_id,previous,p_decision,auth.jwt()->>'email',left(trim(p_reason),2000));
 update public.enrollments set status='stopped',stopped_at=now(),stop_reason='review_changed' where prospect_id=p_id and status in ('active','queued');
 return jsonb_build_object('saved',true,'automation_allowed',false);
end $$;
revoke all on function public.bloxflow_review(uuid,text,text,boolean,boolean,timestamptz) from public,anon;
grant execute on function public.bloxflow_review(uuid,text,text,boolean,boolean,timestamptz) to authenticated;
commit;
