# Bloxflow dashboard

Werkruimte voor het beoordelen van prospects, sectoroverzichten en het lezen van antwoorden. De statische frontend kan op Netlify draaien; gegevens en automatische mailverwerking blijven in het bestaande Supabase-project.

## Netlify

Importeer deze GitHub-repo in Netlify. De publicatiemap `dist` en routes staan in `netlify.toml`; er is geen buildstap nodig. De hoofdpagina verwijst naar `/werkruimte`.

Na de eerste publicatie: voeg de exacte nieuwe URL `https://<sitenaam>.netlify.app/werkruimte` toe aan de toegelaten redirect-URL's in Supabase Authentication → URL Configuration. Behoud de bestaande URL zolang de oude werkruimte gebruikt wordt. Test vervolgens aanmelden via e-maillink en toegang tot het onderdeel Antwoorden. De nieuwe Netlify-URL is nog niet gekoppeld of gepubliceerd door deze repository-upload.

Er zijn geen geheime sleutels nodig in Netlify. De frontend bevat uitsluitend de openbare Supabase publishable key; databasebeleid schermt echte prospecten en antwoorden af voor het aangemelde eigenaaraccount. Gmail- en workergeheimen blijven in Supabase.

## Lokaal controleren

Node.js 20 of nieuwer:

```sh
npm test
npm run check
python3 -m http.server 8766 --directory dist
```

## Maildienst

De HVAC-dienst draait in Supabase, onafhankelijk van deze frontend en van de lokale pc. Alleen nieuwe goedkeuringen vanaf de campagnestart tellen mee, na e-mailverificatie en controle van contacthistoriek en uitsluitingen. Werkdagen 08–18 uur Belgische tijd, maximaal 200 per mailstap / 600 totaal, met telkens drie werkdagen tussen opvolgingen. Antwoorden stoppen verdere opvolging.

`automation/` bevat de workerbron en tests; `supabase/functions/` de Edge Functions. `npm run build:worker` genereert de worker opnieuw. Deze GitHub-upload implementeert of wijzigt geen Edge Function en voert geen databasemigratie uit.

De migraties en `supabase/ACTIVATION.txt` documenteren het bestaande project. Voer import-, vrijgave- of activatiescripts niet opnieuw uit als gewone deploystap. De oorspronkelijke databasestructuur en bedrijfsgegevens zijn niet als algemene nieuwe-installatiebootstrap meegeleverd. Oudere statusnotities zijn historisch; zie de laatste activeringsnotities en `automation/README.txt`.

Geen prospectexports, Gmail-tokens, OAuth-clientgeheimen of workergeheimen worden in deze repo opgeslagen.
