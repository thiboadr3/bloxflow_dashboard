-- Nieuwe piloot-niche: glazenwassers, gevel- en dakreiniging (testgewicht 8 in autopilot/niches.json).
insert into public.sectors(name, source_sheet, paused, autopilot)
select 'REINIGING', 'REINIGING', true, true
where not exists (select 1 from public.sectors where source_sheet = 'REINIGING');
