HVAC outreach implementation — 17 October 2026

Implemented locally:
- Approved three HVAC messages, real clickable demo links, complete signature and send-time Europe/Brussels greeting.
- Gmail history synchronization with paged bootstrap/recovery; failed or partial sync prevents sending.
- A fresh conversation/address/domain/company inbox check before dispatch; every found response stops the enrollment. Incoming messages are never answered automatically.
- Atomic database reservations, 90-second worker lease, one send per minute, weekday/time window, 200 per step and 600 total in local day AND rolling 24 hours.
- Stable Message-ID and threading, no blind retry on uncertain Gmail outcome; uncertain outcomes reconciled by exact sent Message-ID.
- Review/sector/email changes stop queued work; historical contact, suppression, verified-email and owner restrictions remain.
- Owner-only inbox RPC, pause RPC and status RPC; frontend answer screen and pause/status controls.

Cloud work verified:
- Migration 009 executed successfully: query 28078233-08eb-4a0d-ba5f-6e0781072cfc.
- Transactional database tests passed: query 2f68c57c-81fb-4cd7-9976-584b55a210aa. Reply stops job, suppression block stored, weekdays and owner-only access correct. Test data rolled back.
- hvac-worker successfully deployed through Supabase dashboard at /functions/hvac-worker/details.
- Migration 010 scheduler installed: query fe229470-6b03-4e27-bff9-5f7b76b15619. One minute schedule with random token stored only in Vault; SHA256 stored in outreach_runtime. No secret in source.

CURRENT STATE / 17 October 2026:
- Custom Vault-held worker secret authentication is active. Missing/wrong keys return 401.
- Scheduler and Gmail history synchronization work independently of Codex/Windows.
- Three REAL self-test messages sent only to thibo@bloxflow.be; no prospect mail sent. Test 57b753f1-32a0-4216-9403-959ec2f35ed7 passed on 2026-10-17 at 10:00:25 UTC: all three messages have the correct recipient, demo link, signature and same Gmail thread. Verification used saved Gmail IDs and did NOT resend messages.
- ACTIVE since 2026-10-17 10:53:31.692679 UTC: worker_verified=true, enabled=true, sending_settings.paused=false, gmail_connections.sending_enabled=true. First eligible production window Monday 19 October 2026 08:00 Europe/Brussels. No prospect mails sent at activation (Saturday).
- Followups configured at 3 then 3 working days, matching the requested repeated three-day interval; weekday 08–18 Europe/Brussels.
- Migration 011 installed: campaign-start approval gate and exact public email evidence check. Older approvals cannot enroll without a fresh approval after campaign start.
- Owner explicitly authorized stock release: migration 012 released 2,625 source-new HVAC step-0 records. Seven additional suppression matches stayed blocked, as did 805 archived and 100 scheduled records. Clearance evidence is in owner-inaccessible hvac_stock_clearance; source data and reviews preserved.
- Migration 013 activated the campaign after fresh Gmail sync, passing send test and active cron checks. Existing approvals are NOT eligible; only approvals at/after campaign_started_at enroll. Launch gates tested in a rolled-back transaction: valid fresh approval passes; prior contact, unverified email, old approval and archive fail.
- Email verification now checks the exact address on the public website/contact pages after approval. Review approval does not manufacture email evidence.
- Frontend inbox/pause/status changes remain LOCAL ONLY at the user's explicit request. Existing Sites project lookup returns NOT_FOUND; do not publish/create another project without authorization.
- Reply stopping has passed mocked worker and transactional database tests, not an external real-prospect reply test.

Tests:
node --test automation/*.test.mjs (17 passing)
node --check dist/werkruimte.js
node automation/build.mjs (rebuild standalone Edge entry after source edits)

Scheduling in Supabase means no Windows PC/Codex needs to stay open once tested and activated. Cloud availability still matters; downtime must not cause catchup bursts.

AUDIT UPDATE 17 October 2026: migrations 014/015 and updated worker deployed. Full database pipeline, real UI approval/website verification/weekend queue and real own-account incoming message/opt-out stop verified. System test record archived and test traffic excluded from production counts. 27 Node tests pass. See AUDIT-2026-10-17.txt for exact evidence and limits. Supersedes earlier counter/readiness notes.

E-mailvoorraad (17 oktober 2026)
Zoek en registreer één exact openbaar zakelijk adres tijdens sourcing. Voeg een
prospect pas daarna actief toe. Lever source_record_id met hetzelfde Email-veld,
of verse email_verified/email_evidence_url/email_checked_at met openbare bron mee.
source_provided betekent afkomstig uit de aangeleverde bron, niet opnieuw gecrawld.
De mailworker zoekt na goedkeuring geen e-mailadressen. De database bewaakt formaat,
bronherkomst, goedkeuring, contacthistoriek en uitsluitingen. Geen gevonden adres:
herstelbaar archiveren met identity keys; nooit de contacthistoriek weggooien.
