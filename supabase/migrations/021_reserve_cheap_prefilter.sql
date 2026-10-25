-- Fix: bloxflow_reserve liep sinds 24/10/2026 elke minuut in een statement timeout,
-- omdat bloxflow_job_safe() (dure suppressie-/archiefcontroles) voor alle ±10.600 prospects
-- werd uitgevoerd. De goedkope voorwaarden die job_safe zelf al vereist, worden nu eerst
-- gecontroleerd (CASE garandeert de volgorde). Zelfde regels, zelfde resultaat; ±12 s -> ±20 ms.
do $mig$
declare def text; old_txt text; new_txt text;
begin
  def := pg_get_functiondef('public.bloxflow_reserve'::regproc);
  old_txt := E'where public.bloxflow_job_safe(candidate_prospect)\nand not exists(select 1 from public.outreach_jobs existing_job where existing_job.identity_keys && public.bloxflow_identity_keys(to_jsonb(candidate_prospect))) order by';
  new_txt := E'where case when candidate_prospect.review_status=''approved'' and candidate_prospect.archived_at is null and candidate_prospect.approved_at>=r.campaign_started_at and not exists(select 1 from public.outreach_jobs own_job where own_job.prospect_id=candidate_prospect.id) then public.bloxflow_job_safe(candidate_prospect)\nand not exists(select 1 from public.outreach_jobs existing_job where existing_job.identity_keys && public.bloxflow_identity_keys(to_jsonb(candidate_prospect))) else false end order by';
  if position(old_txt in def) = 0 then raise exception 'bloxflow_reserve definition changed; migration aborted'; end if;
  execute replace(def, old_txt, new_txt);
end $mig$;
