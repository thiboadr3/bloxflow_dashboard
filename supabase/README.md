# Historical setup notes

Current verified behavior and audit: `../automation/AUDIT-2026-10-17.txt` and the latest entries in `ACTIVATION.txt`. The dated setup notes below describe earlier states, not the active campaign.

# Bloxflow Supabase

Project: https://supabase.com/dashboard/project/dzygpjozhixnkbtfupqj

The public demo is NOT connected to this database. Never expose service-role keys or allow anonymous prospect writes. All 11 initial tables have RLS enabled and client-role grants revoked. Application authorization and secure server-side integration remain to be implemented.

Initial structure was executed through the Supabase SQL Editor, saved query cd2f4af5-beee-4a61-843d-cf273012e9eb. Ten sectors correspond to the live Sheet tabs. All sectors and sending are paused; Gmail is disconnected. New company ceiling: 200 per working day; initial total mail ceiling: 200.

Source spreadsheet: 1xI2bmizT4XCC7CR5VJh1oPxfx_qpXDBlZJdkZzR9Abs. Original Sheet remains unchanged. Source records preserve displayed values, including legacy errors and contact history. They are a values snapshot, not a workbook/formula backup. All existing Sheet companies are treated as previously contacted according to workspace rules. Review approval does not enable sending.

Import CSV is sensitive and remains outside this Site repository under mailbox-audit/supabase-migration-2026-10-16/. Do not publish or commit it. No Gmail credentials have been collected.

002_normalize_import.sql validates batch counts before importing sector prospects and suppressions; retains duplicate sources without merging away history. Exact domain/email/name deduplication is preliminary; full KBO/phone/address conflict review remains before cutover.

## Verified import result

2026-10-16: 12,054 source rows imported and batch counts checked. 10,651 sector prospect records after preliminary per-sector exact-key deduplication; these are existing records, not newly qualified leads. 112 suppression entries. 0 prospects enabled for automation. Sending remains paused. No source Sheet changes, no emails sent. 94 Contacted Archive rows, 17 Later Opvolgen rows and 998 snapshot rows remain preserved in source_records for history reconciliation. Full historical mail-event reconstruction, cross-record identity reconciliation and application connection remain pending.

## Owner workspace, 2026-10-17

Explicitly approved owner access activated with migrations 004 and 005. The static public demo remains separate. werkruimte.html uses Supabase Auth and a publishable key; reads require the owner's signed-in email. Narrow review RPC logs changes and always leaves sending disabled. See ACTIVATION.txt for verified checks and remaining email-login handoff.
