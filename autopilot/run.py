#!/usr/bin/env python3
"""Automatische piloot: zoeken → e-mail vinden → website beoordelen → prospect in de mailreeks.

Gebruik:
  python3 autopilot/run.py                 # echte run (vereist enabled=true in Supabase)
  python3 autopilot/run.py --dry-run       # alles behalve wegschrijven/inplannen
  python3 autopilot/run.py --dry-run --no-db --target 10   # lokale test zonder database

Omgevingsvariabelen: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GEMINI_API_KEY, GOOGLE_PLACES_API_KEY,
optioneel GEMINI_MODEL (standaard gemini-3.8-flash).
"""
import argparse, asyncio, concurrent.futures as cf, csv, json, os, re, sys, time, uuid
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import places, email_finder, capture, judge, nocontact  # noqa: E402
from db import DB  # noqa: E402

def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)

def notify(text):
    """Stuurt een korte update naar Telegram (TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID). Fouten worden genegeerd."""
    token, chat = os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        return
    try:
        import urllib.request
        body = json.dumps({"chat_id": chat, "text": text[:4000], "disable_web_page_preview": True}).encode()
        req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=body,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=20).read()
    except Exception as e:
        log("Telegram-melding mislukt:", type(e).__name__)

def allocate(target, niches):
    total = sum(n["gewicht"] for n in niches)
    raw = [(n["sector"], target * n["gewicht"] / total) for n in niches]
    base = {s: int(v) for s, v in raw}
    rest = target - sum(base.values())
    for s, v in sorted(raw, key=lambda x: x[1] - int(x[1]), reverse=True)[:rest]:
        base[s] += 1
    return base

def combos(niche):
    return [(t, g) for g in places.GEMEENTEN for t in niche["zoektermen"]]

def local_keys(rec):
    dom = re.sub(r"^www\.", "", re.sub(r"^https?://", "", rec.get("website_url", "") or "").split("/")[0].lower())
    keys = []
    if "." in dom:
        keys.append("domain:" + dom.rstrip("."))
    if rec.get("email"):
        keys.append("email:" + rec["email"].lower())
    ph = re.sub(r"^(0032|32)", "0", re.sub(r"[^0-9]", "", rec.get("phone") or ""))
    if len(ph) >= 9:
        keys.append("phone:" + ph)
    return keys

async def capture_batch(rows, outdir):
    from playwright.async_api import async_playwright
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--disable-dev-shm-usage"])
        sem = asyncio.Semaphore(6)
        async def one(r):
            async with sem:
                try:
                    await asyncio.wait_for(capture.capture_one(browser, {"website": r["website_url"]}, outdir), timeout=150)
                except Exception as e:
                    d = outdir / capture.slug(r["website_url"])
                    d.mkdir(parents=True, exist_ok=True)
                    (d / "facts.json").write_text(json.dumps({"input_url": r["website_url"], "loaded": False, "page_type": "laadt_niet", "error": str(e)[:200]}))
        await asyncio.gather(*(one(r) for r in rows))
        await browser.close()

def gemini_cost_line(tok):
    """Werkelijke Gemini-kost van deze run uit usageMetadata. Prijzen in USD per miljoen tokens (env overschrijfbaar)."""
    p_in = float(os.environ.get("GEMINI_PRICE_INPUT", "0.75"))
    p_cache = float(os.environ.get("GEMINI_PRICE_CACHED", "0.075"))
    p_out = float(os.environ.get("GEMINI_PRICE_OUTPUT", "3.75"))
    fresh = max(tok["prompt"] - tok["cached"], 0)
    usd = (fresh * p_in + tok["cached"] * p_cache + (tok["output"] + tok["thinking"]) * p_out) / 1e6
    per = usd / tok["calls"] if tok["calls"] else 0
    return (f"Gemini: {tok['calls']} oordelen, {fresh} nieuwe + {tok['cached']} gecachete inputtokens, "
            f"{tok['output']} output + {tok['thinking']} denk-tokens = ${usd:.2f} (${per:.4f} per oordeel, excl. cache-opslag)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-db", action="store_true")
    ap.add_argument("--target", type=int, default=0, help="aantal nieuwe prospects (standaard: daglimiet uit Supabase)")
    ap.add_argument("--max-queries", type=int, default=400)
    ap.add_argument("--max-judged", type=int, default=1200)
    ap.add_argument("--minutes", type=int, default=300)
    ap.add_argument("--workdir", default="/tmp/autopilot")
    a = ap.parse_args()
    t0 = time.time()
    niches = json.loads((HERE / "niches.json").read_text())["niches"]
    gem_key = os.environ["GEMINI_API_KEY"]
    places_key = os.environ["GOOGLE_PLACES_API_KEY"]
    model = os.environ.get("GEMINI_MODEL", "gemini-3.8-flash")
    db = None if a.no_db else DB(dry_run=a.dry_run)
    settings = db.settings() if db else {"enabled": False, "daily_new_limit": 200, "cursor": {}}
    if db and not a.dry_run and not settings["enabled"]:
        log("Piloot staat UIT in Supabase (outreach_autopilot_settings.enabled=false). Niets gedaan.")
        return 0
    target = a.target or settings["daily_new_limit"]
    quota = allocate(target, niches)
    cursor = settings.get("cursor") or {}
    run_id = str(uuid.uuid4())
    if db and not a.dry_run:
        db.insert("outreach_autopilot_runs", {"id": run_id})
    # No-contactlijst (agency-klanten): uit Supabase, of lokaal bestand bij --no-db
    if db:
        nc_names = [r["company_name"] for r in db.select("suppressions", "select=company_name&reason=eq.no_contact_agency") or [] if r.get("company_name")]
        if not nc_names:
            log("No-contactlijst ontbreekt in Supabase; piloot stopt uit voorzorg.")
            notify("⛔ Piloot gestopt: de no-contactlijst ontbreekt in Supabase. Er werd niets ingepland.")
            return 1
    else:
        nc_file = Path(os.environ.get("NO_CONTACT_CSV", HERE.parent.parent / "screening" / "no-contact.csv"))
        nc_names = [r["bedrijfsnaam"] for r in csv.DictReader(open(nc_file, encoding="utf-8-sig"))] if nc_file.exists() else []
    blocker = nocontact.NoContact(nc_names)
    log(f"No-contactlijst: {len(nc_names)} namen")
    anchors = judge.anchor_parts_from_dir(str(HERE / "anchors.csv"), str(HERE / "anchors"))
    cache = judge.create_cache(gem_key, model, anchors)
    log("Gemini-cache voor voorbeelden:", "actief" if cache else "niet beschikbaar")
    work = Path(a.workdir) / run_id
    work.mkdir(parents=True, exist_ok=True)
    counts = {k: 0 for k in ["zoekopdrachten", "gevonden", "al_gekend", "geen_email", "beoordeeld", "prospect", "twijfel", "niet_prospecteren", "buiten_niche", "ingepland", "no_contact", "fouten"]}
    per_sector = {n["sector"]: 0 for n in niches}
    examples = []
    stops = {}
    seen_ids = set()
    tok = {"prompt": 0, "cached": 0, "output": 0, "thinking": 0, "calls": 0}

    def record_candidate(c, decision, reasons, details=None, prospect_id=None):
        if db and not a.dry_run:
            try:
                db.log_candidate({"identity_keys": c["keys"], "place_id": c.get("place_id"), "company_name": c["company_name"],
                                  "website_url": c["website_url"], "sector": c["sector"], "decision": decision,
                                  "reasons": reasons[:2000], "details": details or {}, "prospect_id": prospect_id or c.get("prospect_id"), "run_id": run_id})
            except Exception as e:
                log("kandidaat loggen mislukt", e)

    def process(fresh, sector, niche, q, n_found, backlog=False):
        """Stap 2-4 voor een lijst nieuwe kandidaten: e-mail, screenshots, oordeel, inplannen."""
        # 2. e-mail
        with cf.ThreadPoolExecutor(8) as ex:
            for c, (email, src) in zip(fresh, ex.map(lambda c: email_finder.find_email(c["website_url"]), fresh)):
                c["email"], c["email_src"] = email, src
        with_mail = []
        for c in fresh:
            if not c["email"] and c.get("db_email"):
                c["email"], c["email_src"] = c["db_email"], None  # bestaand adres uit onze bron; de database controleert of het bruikbaar is
            if not c["email"]:
                counts["geen_email"] += 1
                record_candidate(c, "geen_email", "Geen publiek e-mailadres gevonden op de website")
            else:
                with_mail.append(c)
        # tweede controle nu het e-mailadres gekend is, opnieuw in één call
        if db and with_mail and not backlog:
            checked = db.check([{"website_url": c["website_url"], "phone": c["phone"], "company_name": c["company_name"],
                                 "municipality": c["municipality"] or "", "email": c["email"]} for c in with_mail])
            keep = []
            for c, chk in zip(with_mail, checked):
                c["keys"] = chk["keys"]
                if chk["reason"]:
                    counts["al_gekend"] += 1
                else:
                    keep.append(c)
            with_mail = keep
        else:
            for c in with_mail:
                c["keys"] = sorted(set(c["keys"]) | {"email:" + c["email"]})
        if not with_mail:
            return
        # 3. screenshots + feiten
        asyncio.run(capture_batch(with_mail, work))
        # 4. oordeel
        def do_judge(c):
            d = work / capture.slug(c["website_url"])
            f = json.loads((d / "facts.json").read_text()) if (d / "facts.json").exists() else {"loaded": False, "page_type": "laadt_niet"}
            try:
                return judge.judge_for_pilot(gem_key, model, d, f, niche["omschrijving"], anchors, cache)
            except Exception as e:
                return "fout", [], str(e)[:300], {}, {}
        with cf.ThreadPoolExecutor(4) as ex:
            results = list(ex.map(do_judge, with_mail))
        for c, (dec, codes, reden, mo, usage) in zip(with_mail, results):
            if usage:
                tok["calls"] += 1
                tok["prompt"] += int(usage.get("promptTokenCount") or 0)
                tok["cached"] += int(usage.get("cachedContentTokenCount") or 0)
                tok["output"] += int(usage.get("candidatesTokenCount") or 0)
                tok["thinking"] += int(usage.get("thoughtsTokenCount") or 0)
            if dec == "fout":
                counts["fouten"] += 1
                log("Oordeel mislukt", c["website_url"], reden)
                if "Spend cap" in reden or "PERMISSION_DENIED" in reden or "RESOURCE_EXHAUSTED" in reden:
                    log("Gemini-limiet bereikt; run stopt.")
                    if not stops.get("gemini"):
                        stops["gemini"] = True
                        notify("⚠️ Piloot: Gemini-limiet bereikt (spend cap). De run stopt; verhoog de limiet in AI Studio / Cloud Billing.")
                    a.max_judged = 0
                continue
            counts["beoordeeld"] += 1
            counts[dec] = counts.get(dec, 0) + 1
            pid = None
            if dec == "prospect" and per_sector[sector] < quota[sector]:
                rec = {"sector": sector, "company_name": c["company_name"], "website_url": c["website_url"], "email": c["email"],
                       "email_evidence_url": c["email_src"], "phone": c["phone"], "municipality": c["municipality"],
                       "source_url": "https://www.google.com/maps/place/?q=place_id:" + (c["place_id"] or ""),
                       "fit_reason": f"[{', '.join(codes)}] {reden}", "subniche": c["query"].split(" in ")[0],
                       "assessment": {"codes": codes, "design_score": mo.get("design_score"), "mailhaak": mo.get("mailhaak"), "model": model}}
                try:
                    if backlog:
                        pid = db.promote_prospect(c["prospect_id"], rec, run_id) if db else "geen-db"
                    else:
                        pid = db.insert_prospect(rec, run_id) if db else "geen-db"
                except Exception as e:
                    log("Inplannen mislukt", c["company_name"], e); counts["fouten"] += 1
                if pid:
                    counts["ingepland"] += 1
                    per_sector[sector] += 1
                    if len(examples) < 15:
                        examples.append(f"- {c['company_name']} ({c['municipality']}, {sector}): {', '.join(codes)} — {c['website_url']}")
                elif db and not a.dry_run:
                    log("Daglimiet bereikt of bedrijf intussen gekend.")
            record_candidate(c, dec, reden, {"codes": codes, "design_score": mo.get("design_score"), "bron": "database" if backlog else "places"},
                             (pid if pid not in ("droge-run", "geen-db") else None) or c.get("prospect_id"))
        log(f"{q}: {n_found} gevonden, {len(with_mail)} met e-mail beoordeeld — {sector} {per_sector[sector]}/{quota[sector]}")

    for niche in sorted(niches, key=lambda n: -n["gewicht"]):
        sector = niche["sector"]
        combo_list = combos(niche)
        pos = int(cursor.get(sector, 0))
        # 0. eerst bedrijven uit onze eigen database die nog nooit gemaild zijn en waarvan de website nog niet beoordeeld is
        if db and niche.get("database", True):
            while per_sector[sector] < quota[sector] and counts["beoordeeld"] < a.max_judged and time.time() - t0 < a.minutes * 60:
                rows = [r for r in db.backlog(sector, 40, sorted(seen_ids)) if r["id"] not in seen_ids]
                if not rows:
                    break
                seen_ids.update(r["id"] for r in rows)
                batch = []
                for r in rows:
                    c = {"company_name": r["company_name"], "website_url": r["website_url"], "phone": r.get("phone") or "",
                         "municipality": r.get("municipality") or "", "place_id": None, "sector": sector,
                         "query": f"{sector.lower()} uit database", "prospect_id": r["id"], "db_email": r.get("email"),
                         "keys": r.get("identity_keys") or []}
                    hit = blocker.match(c["company_name"], c["website_url"])
                    if hit:
                        counts["no_contact"] += 1
                        record_candidate(c, "no_contact", f"No-contactlijst ({hit})")
                        continue
                    batch.append(c)
                counts["uit_database"] = counts.get("uit_database", 0) + len(rows)
                if batch:
                    process(batch, sector, niche, f"{sector} uit database", len(rows), backlog=True)
        while per_sector[sector] < quota[sector]:
            if counts["zoekopdrachten"] >= a.max_queries or counts["beoordeeld"] >= a.max_judged or time.time() - t0 > a.minutes * 60:
                break
            term, gem = combo_list[pos % len(combo_list)]
            pos += 1
            q = f"{term} in {gem}"
            try:
                found = places.candidates(places_key, q)
            except Exception as e:
                log("Places-fout", q, e); counts["fouten"] += 1
                if ("403" in str(e) or "401" in str(e) or "429" in str(e)) and not stops.get("places"):
                    stops["places"] = True
                    notify(f"⚠️ Piloot: Google Places weigert ({str(e)[:120]}). Controleer sleutel/facturatie.")
                if "403" in str(e) or "401" in str(e) or "429" in str(e):
                    break
                continue
            counts["zoekopdrachten"] += 1
            counts["gevonden"] += len(found)
            # 1. dedup
            fresh = []
            todo = []
            for c in found:
                c["sector"] = sector
                hit = blocker.match(c["company_name"], c["website_url"])
                if hit:
                    counts["no_contact"] = counts.get("no_contact", 0) + 1
                    log(f"No-contact geblokkeerd: {c['company_name']} (lijst: {hit})")
                    continue
                todo.append(c)
            # één database-call voor het hele zoekresultaat (sleutels + al gekend?)
            if db:
                checked = db.check([{"website_url": c["website_url"], "phone": c["phone"], "company_name": c["company_name"],
                                     "municipality": c["municipality"] or "", "place_id": c["place_id"] or ""} for c in todo])
            else:
                checked = [{"keys": local_keys(c), "reason": None} for c in todo]
            for c, chk in zip(todo, checked):
                c["keys"] = chk["keys"]
                if chk["reason"]:
                    counts["al_gekend"] += 1
                    continue
                if any(set(c["keys"]) & set(f["keys"]) for f in fresh):
                    continue
                fresh.append(c)
            if not fresh:
                continue
            process(fresh, sector, niche, q, len(found))
        cursor[sector] = pos % len(combo_list)
        if db:
            db.save_cursor(cursor)

    mins = round((time.time() - t0) / 60)
    report = "\n".join([
        f"# Piloot {time.strftime('%d/%m/%Y')}{' (droge run)' if a.dry_run else ''}",
        f"Nieuw ingepland voor mail: **{counts['ingepland']}** van {target} (duur {mins} min).",
        "", "| Stap | Aantal |", "|---|---:|",
        *[f"| {k.replace('_', ' ')} | {v} |" for k, v in counts.items()],
        "", "Per sector: " + ", ".join(f"{s} {per_sector[s]}/{quota[s]}" for s in per_sector),
        "", gemini_cost_line(tok),
        "", "Voorbeelden:", *examples])
    log("\n" + report)
    per = ", ".join(f"{s} {per_sector[s]}/{quota[s]}" for s in per_sector)
    status = "🟢" if counts["ingepland"] >= target else "🟡"
    notify(f"{status} Piloot {time.strftime('%d/%m')}{' (droge run)' if a.dry_run else ''}: {counts['ingepland']} van {target} bedrijven klaar voor mail "
           f"({mins} min).\nBeoordeeld: {counts['beoordeeld']} · prospect {counts.get('prospect', 0)} · twijfel {counts.get('twijfel', 0)} · "
           f"goede site {counts.get('niet_prospecteren', 0)} · buiten niche {counts.get('buiten_niche', 0)} · fouten {counts['fouten']}\n"
           f"Per sector: {per}\n{gemini_cost_line(tok)}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        Path(os.environ["GITHUB_STEP_SUMMARY"]).write_text(report)
    if db and not a.dry_run:
        db.update("outreach_autopilot_runs", f"id=eq.{run_id}", {"finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "counts": counts, "report": report})
    return 0

if __name__ == "__main__":
    sys.exit(main())
