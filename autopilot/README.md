# Bloxflow piloot

Elke werkdag om ±05:15 automatisch: **zoeken → e-mail vinden → website beoordelen → prospect in de mailreeks**.
De bestaande maildienst in Supabase verstuurt daarna tussen 08 en 18 uur (max. 200 nieuwe bedrijven per dag, opvolgmails apart). Beslissing van Thibo op 23/10/2026: volledig automatisch, zonder swipen.

## Wat de piloot doet
1. **Zoeken** — Google Places, per niche uit `niches.json` (zoekterm × Vlaamse gemeente). Enkel actieve bedrijven met website en Vlaamse postcode. De voortgang (cursor) staat in Supabase, zodat elke dag nieuwe combinaties aan bod komen.
2. **Ontdubbelen** — tegen álle prospects (elke sector, ook gearchiveerd), contacthistoriek, suppression/no-contact, blokkades, lopende mailreeksen en eerder beoordeelde kandidaten.
3. **E-mail** — exact adres dat letterlijk op de eigen website staat (homepage/contactpagina). Nooit gegokt. Geen adres = overgeslagen.
4. **Beoordelen** — screenshots desktop + mobiel, technische feiten, Gemini met Thibo's voorbeelden (`anchors/`), beslisregel v3 (zie `screening/criteria-goede-website.md`). Extra poort: hoofdactiviteit moet bij de niche passen, Nederlandstalig, lokaal bedrijf.
5. **Inplannen** — enkel `prospect`. Twijfel, hosting-/bouwpagina's en bedrijven buiten de niche worden niet gemaild maar wel gelogd.
6. **Rapport** — per run in `outreach_autopilot_runs` (Supabase) en in de GitHub Actions-samenvatting.

## Activeren (eenmalig)
1. **Google Places-sleutel**: Google Cloud Console → *APIs & Services* → schakel **Places API (New)** in → *Credentials* → API-sleutel aanmaken → beperk tot Places API (New). Facturatie moet aan staan.
2. **Gemini**: verhoog de uitgavenlimiet (spend cap) van het project van je Gemini-sleutel.
3. **Supabase**: voer `supabase/migrations/020_autopilot.sql` uit in de SQL Editor. Noteer de Project URL en de `service_role`-sleutel (*Project Settings → API*).
4. **No-contactlijst**: `python3 autopilot/import_no_contact.py screening/no-contact.csv` (lokaal, met SUPABASE_URL en SUPABASE_SERVICE_ROLE_KEY in de omgeving). Nooit in GitHub zetten.
5. **GitHub**: een **privé** repository, met deze secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `GEMINI_API_KEY`, `GOOGLE_PLACES_API_KEY`.
6. **Droge run**: Actions → *Bloxflow piloot* → *Run workflow* met `dry_run` aan. Controleer het rapport.
7. **Aanzetten** (SQL): `update public.outreach_autopilot_settings set enabled=true, daily_new_limit=200 where id;`

## Noodstop
`update public.outreach_autopilot_settings set enabled=false where id;` — stopt nieuwe inplanningen. Om ook verzending te stoppen: de bestaande pauzeknop in het dashboard (sending_settings.paused).

## Kosten (ruwe schatting, te bevestigen)
- Places Text Search: ±150–300 zoekopdrachten/dag.
- Gemini: ±25k tokens per beoordeling met voorbeelden; ±400–800 beoordelingen/dag.
- GitHub Actions: ±2–5 uur per werkdag (privé repo: gratis tegoed 2.000 min/maand; daarboven betalend).

## Lokaal testen
`python3 autopilot/run.py --dry-run --no-db --target 10` (met GEMINI_API_KEY en GOOGLE_PLACES_API_KEY in de omgeving).
