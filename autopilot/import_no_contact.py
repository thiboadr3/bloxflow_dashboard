#!/usr/bin/env python3
"""Zet een no-contactlijst (bv. klanten van het agency) in de Supabase-tabel suppressions.

CSV-kolommen (koprij verplicht): bedrijfsnaam, website, email (optioneel), kbo (optioneel)
Gebruik: SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python3 import_no_contact.py pad/naar/no-contact.csv

De lijst blijft privé: zet hem NIET in GitHub. Draai dit script lokaal.
De piloot blokkeert op domein, e-mail(domein), ondernemingsnummer en exacte bedrijfsnaam.
"""
import csv, re, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from db import DB

def domain(u):
    return re.sub(r"^www\.", "", re.sub(r"^https?://", "", (u or "").strip().lower()).split("/")[0])

def main(path):
    db = DB()
    existing = db.select("suppressions", "select=domain,company_name&reason=eq.no_contact_agency") or []
    seen = {(r.get("domain") or "", (r.get("company_name") or "").lower()) for r in existing}
    n = 0
    for r in csv.DictReader(open(path, encoding="utf-8-sig")):
        name = (r.get("bedrijfsnaam") or r.get("naam") or "").strip()
        dom = domain(r.get("website"))
        email = (r.get("email") or "").strip().lower() or None
        if not (name or dom or email):
            continue
        if (dom, name.lower()) in seen:
            continue
        db.insert("suppressions", {"company_name": name or None, "domain": dom or None, "email": email,
                                   "reason": "no_contact_agency"})
        if email and "@" in email:
            mail_dom = email.split("@", 1)[1]
            if mail_dom != dom and mail_dom not in ("gmail.com", "hotmail.com", "outlook.com", "telenet.be", "skynet.be"):
                db.insert("suppressions", {"company_name": name or None, "domain": mail_dom, "reason": "no_contact_agency"})
        n += 1
    print(f"{n} bedrijven toegevoegd aan de no-contactlijst.")

if __name__ == "__main__":
    main(sys.argv[1])
