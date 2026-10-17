-- Run in SQL Editor as postgres. Everything is rolled back; no transport calls.
begin;
select set_config('request.jwt.claims',jsonb_build_object('email','thibo@bloxflow.be','sub',(select id::text from auth.users where email='thibo@bloxflow.be' limit 1))::text,true);
do $$declare p public.prospects;blocked boolean:=false;begin
 select * into p from public.prospects where archived_at is null and review_status='needs_review' and email_check_status='source_provided' and not previously_contacted and website_url ~ '^https?://' limit 1;
 if p.id is null or public.bloxflow_email_ready(p) is not true then raise exception 'Source email not ready';end if;
 p.email:='made-up@example.invalid';if public.bloxflow_email_ready(p) then raise exception 'Changed email accepted without evidence';end if;
 begin update public.prospects set email='contactformulier' where id=p.id;exception when others then blocked:=SQLERRM like 'Find a public business email%';end;
 if not blocked then raise exception 'Invalid email input accepted';end if;
 select * into p from public.prospects where id=p.id;
 perform public.bloxflow_review(p.id,'approved',null,true,false,p.updated_at);
 select * into p from public.prospects where id=p.id;
 if p.send_blocker<>'none' then raise exception 'Approval still waits for email lookup';end if;
 p.previously_contacted:=true;if public.bloxflow_job_safe(p) is true then raise exception 'Contact history protection weakened';end if;
 p.email:=null;if public.bloxflow_email_ready(p) then raise exception 'Missing email accepted';end if;
 if has_function_privilege('anon','public.bloxflow_email_ready(public.prospects)','execute') then raise exception 'Anonymous email provenance access';end if;
end$$;
select 'PASS: source email, changed email blocked, invalid input blocked, approval without website crawl, contact history preserved, anonymous access denied' as result;
rollback;
