# Bloxflow dashboard

Werkruimte voor het beoordelen van prospects, sectoroverzichten en het lezen van antwoorden. De statische frontend kan op Netlify draaien; gegevens en automatische mailverwerking blijven in het bestaande Supabase-project.

## Netlify

Importeer deze GitHub-repo in Netlify. De publicatiemap `dist` en routes staan in `netlify.toml`; er is geen buildstap nodig. De hoofdpagina verwijst naar `/werkruimte`.

Na de eerste publicatie: voeg de exacte nieuwe URL `https://<sitenaam>.netlify.app/werkruimte` toe aan de toegelaten redirect-URL's in Supabase Authentication → URL Configuration. Behoud de bestaande URL zolang de oude werkruimte gebruikt wordt. Test vervolgens aanmelden via e-maillink en toegang tot het onderdeel Antwoorden. Live werkruimte: https://bloxflow-dashboard.netlify.app/werkruimte. Dit exacte terugkeeradres is op 17 oktober 2026 met toestemming van de eigenaar toegevoegd aan Supabase Authentication. De hoofdpagina toont eveneens de echte aanmeldomgeving; de oude demoselectie is verwijderd.

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

## Aanmelden met wachtwoord

De werkruimte gebruikt `signInWithPassword`. Kies bij de eerste keer ‘Wachtwoord instellen of vergeten’ om een herstelmail aan het eigenaaraccount aan te vragen. Open de link op hetzelfde toestel en in dezelfde browser (PKCE). Het gevalideerde PASSWORD_RECOVERY-event opent het instelformulier; de eigenaar stelt zelf minimaal 12 tekens in. Er is geen openbaar registratieformulier. De terugkeer-URL blijft het reeds toegestane `/werkruimte`. Wachtwoorden staan niet in broncode of browseropslag van de app.

## Swipen over de websitekaart

De volledige websitekaart vangt pointer- en touchgebaren op: rechts goedkeuren,
links afwijzen, omhoog de website apart openen, omlaag het navigatiemenu openen.
De websitepreview is daardoor niet rechtstreeks interactief; gebruik omhoog of
‘Website openen’ om op de website te scrollen en klikken. Knoppen en pijltjestoetsen
blijven beschikbaar. Kleine, diagonale en geannuleerde bewegingen slaan niets op.
Groen/rood volgt de gekozen richting; de volgende kaart verschijnt pas na een
bevestigde opslag. Verminderde beweging wordt gerespecteerd.
