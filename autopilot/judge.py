#!/usr/bin/env python3
"""Fase 3 — oordeel per website met omgekeerde bewijslast.

Het model beoordeelt per criterium (ok / mist / onzeker) met een concreet bewijs.
De eindbeslissing wordt in code genomen (niet door het model), zodat ze voorspelbaar is.

Gebruik:
  python3 judge.py --run runs/<naam> [--anchors anchors.csv] [--model gemini-3.8-flash]
Sleutel: omgevingsvariabele GEMINI_API_KEY of --env pad/naar/.env
Hervatbaar: sites met een bestaande judgment.json worden overgeslagen (tenzij --force).
"""
import argparse, base64, concurrent.futures as cf, csv, io, json, os, re, sys, time, urllib.request
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None

CURRENT_YEAR = time.localtime().tm_year
PLACEHOLDER_TYPES = {"hostingpagina", "in_aanbouw", "domein_te_koop", "bijna_leeg"}

CRITERIA = """Je beoordeelt de website van een lokaal Vlaams KMO-bedrijf voor Bloxflow, een webbureau dat nieuwe,
conversiegerichte websites verkoopt. Je oordeelt zoals Thibo (de eigenaar). Je krijgt eerst voorbeelden van Thibo's
eigen oordelen: kalibreer je smaak op die voorbeelden, niet op een abstract ideaal. Een site hoeft niet perfect of
trendy te zijn om voor Thibo "goed" te zijn; ze moet verzorgd en professioneel overkomen en bezoekers naar een aanvraag leiden.

Geef design_score op deze schaal (vergelijk met de voorbeelden):
1 = duidelijk verouderd of amateuristisch (oude template, slordig, 2010-gevoel, lage beeldkwaliteit)
2 = gedateerd, rommelig of zwak ingedeeld; merkbaar onder het niveau van een hedendaagse vakmanssite
3 = degelijk en verzorgd, ook al is het geen topdesign
4 = modern en verzorgd
5 = uitstekend, agency-niveau

Beoordeel daarnaast elk kenmerk apart (ok / mist / onzeker) met concreet bewijs:
- design: "mist" alleen als design_score 1 of 2 is.
- dienstpaginas: "mist" als diensten enkel als opsomming of kort blokje staan zonder echte uitleg (ook geen uitgebreide
  sectie per dienst). Een one-pager met een degelijke sectie per dienst is "ok".
- conversie: "mist" als er geen duidelijke offerte-/contact-/afspraakknop of volgende stap in beeld is (desktop of mobiel).
- techniek: "mist" alleen bij zichtbare fouten: kapotte of half geladen layout, tekst over de rand, horizontaal scrollen,
  placeholders zoals "photo in the making", foutmeldingen. Lege ruimte door een animatie die nog niet startte is geen fout.

Regels:
- Cookievensters en laadschermen zijn geen reden voor "mist".
- Je screenshots komen van een serveromgeving. Foutmeldingen van ingesloten video's/kaarten of beveiligingsdiensten
  ("We couldn't verify the security of your connection", "Access denied", reCAPTCHA-meldingen) ziet een echte bezoeker
  niet: negeer ze volledig en beoordeel de rest van de pagina.
- Elk bewijs is SPECIFIEK voor deze site (wat zie je, waar). Geen standaardzinnen.
- Doe geen claims over wat je niet kunt zien.
- Gebruik "onzeker" alleen als je het echt niet kunt beoordelen.
"""

SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "nichefit_opmerking": {"type": "STRING", "description": "Kort: wat is de hoofdactiviteit volgens de site? Leeg als duidelijk."},
        "design": {"type": "OBJECT", "properties": {"status": {"type": "STRING", "enum": ["ok", "mist", "onzeker"]}, "bewijs": {"type": "STRING"}}, "required": ["status", "bewijs"]},
        "dienstpaginas": {"type": "OBJECT", "properties": {"status": {"type": "STRING", "enum": ["ok", "mist", "onzeker"]}, "bewijs": {"type": "STRING"}}, "required": ["status", "bewijs"]},
        "conversie": {"type": "OBJECT", "properties": {"status": {"type": "STRING", "enum": ["ok", "mist", "onzeker"]}, "bewijs": {"type": "STRING"}}, "required": ["status", "bewijs"]},
        "techniek": {"type": "OBJECT", "properties": {"status": {"type": "STRING", "enum": ["ok", "mist", "onzeker"]}, "bewijs": {"type": "STRING"}}, "required": ["status", "bewijs"]},
        "design_score": {"type": "INTEGER", "description": "1 = zeer gedateerd/amateuristisch ... 5 = top, modern agency-niveau"},
        "mailhaak": {"type": "STRING", "description": "Eén concrete, beleefde observatie (NL) die Thibo in een mail kan gebruiken."},
        "hoofdactiviteit_past": {"type": "STRING", "enum": ["ja", "nee", "onzeker"], "description": "Past de HOOFDactiviteit op de site bij de opgegeven niche? 'nee' bij een ander hoofdberoep, groothandel, fabrikant, multinational of franchiseketen."},
        "taal": {"type": "STRING", "enum": ["nl", "fr", "en", "andere"], "description": "Hoofdtaal van de website."},
        "lokaal_kmo": {"type": "BOOLEAN", "description": "true als het een lokaal Vlaams bedrijf of kmo is (geen groot concern, geen landelijke keten)."},
    },
    "required": ["design", "dienstpaginas", "conversie", "techniek", "design_score", "mailhaak", "hoofdactiviteit_past", "taal", "lokaal_kmo"],
}

def load_key(env_path):
    if os.environ.get("GEMINI_API_KEY"):
        return os.environ["GEMINI_API_KEY"]
    if env_path and Path(env_path).exists():
        for line in Path(env_path).read_text().splitlines():
            if line.startswith("GEMINI_API_KEY="):
                return line.split("=", 1)[1].strip()
    sys.exit("Geen GEMINI_API_KEY gevonden")

def img_part(path, max_h=2400, max_w=1000):
    data = Path(path).read_bytes()
    if Image:
        im = Image.open(io.BytesIO(data)).convert("RGB")
        scale = min(1.0, max_w / im.width)
        im = im.resize((int(im.width * scale), int(im.height * scale)))
        im = im.crop((0, 0, im.width, min(im.height, max_h)))
        buf = io.BytesIO(); im.save(buf, "JPEG", quality=70); data = buf.getvalue()
    return {"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(data).decode()}}

def facts_summary(f):
    keep = ["final_url", "status", "ssl", "page_type", "title", "lang", "generator", "footer_year", "internal_page_count",
            "nav_texts", "has_form_home", "has_tel", "desktop_fold_cta", "mobile_fold_cta", "mobile_overflow_px", "text_chars"]
    s = {k: f.get(k) for k in keep if k in f}
    s["tekstfragment"] = (f.get("text_excerpt") or "")[:1500]
    return json.dumps(s, ensure_ascii=False)

def site_parts(d, f, label=None):
    parts = []
    if (d / "desktop.jpg").exists():
        parts += [{"text": "Desktop-screenshot (1440 breed, bovenkant pagina):"}, img_part(d / "desktop.jpg", max_h=2200, max_w=900)]
    if (d / "mobile.jpg").exists():
        parts += [{"text": "Mobiele screenshot (390 breed, eerste schermen):"}, img_part(d / "mobile.jpg", max_h=2400, max_w=500)]
    parts.append({"text": "Gemeten feiten: " + facts_summary(f)})
    if label:
        parts.append({"text": label})
    return parts

THINKING = {"thinkingLevel": "low"}

def _post(key, url, body, timeout=180):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"x-goog-api-key": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def create_cache(key, model, anchor_parts, ttl_seconds=21600):
    """Zet systeeminstructie + Thibo's voorbeelden één keer in de Gemini-cache. Geeft cache-naam of None."""
    try:
        r = _post(key, "https://generativelanguage.googleapis.com/v1beta/cachedContents", {
            "model": f"models/{model}", "systemInstruction": {"parts": [{"text": CRITERIA}]},
            "contents": [{"role": "user", "parts": anchor_parts}], "ttl": f"{ttl_seconds}s"})
        return r.get("name")
    except Exception as e:
        print("Cache aanmaken mislukt, verder zonder cache:", (e.read().decode()[:200] if hasattr(e, "read") else str(e)), flush=True)
        return None

def call_gemini(key, model, parts, retries=4, cache=None):
    gen = {"temperature": 0, "responseMimeType": "application/json", "responseSchema": SCHEMA}
    if THINKING:
        gen["thinkingConfig"] = THINKING
    if cache:
        body = {"cachedContent": cache, "contents": [{"role": "user", "parts": parts}], "generationConfig": gen}
    else:
        body = {"systemInstruction": {"parts": [{"text": CRITERIA}]}, "contents": [{"role": "user", "parts": parts}], "generationConfig": gen}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    for i in range(retries):
        try:
            out = _post(key, url, body)
            txt = out["candidates"][0]["content"]["parts"][0]["text"]
            return json.loads(txt), out.get("usageMetadata", {})
        except Exception as e:
            err = e.read().decode()[:300] if hasattr(e, "read") else str(e)
            if "thinking" in err.lower() and "thinkingConfig" in gen:
                gen.pop("thinkingConfig"); continue
            if "Spend cap" in err or "PERMISSION_DENIED" in err or i == retries - 1:
                raise RuntimeError(err)
            time.sleep(4 * (i + 1))

def decide(f, j):
    """Eindbeslissing in code (regel 'D', gemeten op Thibo's oordelen 23/10/2026).
    Geeft (beslissing, codes, reden)."""
    pt = f.get("page_type")
    if not f.get("loaded", True) or pt in ("laadt_niet", "bot_geblokkeerd"):
        return "twijfel", ["laadt_niet"], "Website laadt niet of blokkeert de scan. Handmatig controleren."
    if pt in PLACEHOLDER_TYPES:
        return "prospect", ["hostingpagina"], f"Geen echte website online ({pt}). Eerst bevestigen dat het bedrijf actief is."
    st = lambda k: (j.get(k) or {}).get("status")
    bew = lambda k: (j.get(k) or {}).get("bewijs", "")
    ds = j.get("design_score") or 3
    fy = f.get("footer_year")
    codes, reasons = [], []
    if fy and fy <= CURRENT_YEAR - 2:
        codes.append("footerjaar_oud"); reasons.append(f"Footer vermeldt {fy}.")
    if ds <= 2:
        codes.append("oud_design"); reasons.append(bew("design"))
    for k, code in (("dienstpaginas", "geen_dienstpaginas"), ("conversie", "geen_cta"), ("techniek", "technisch_zwak")):
        if st(k) == "mist":
            codes.append(code); reasons.append(bew(k))
    reden = " ".join(r for r in reasons if r)
    if "footerjaar_oud" in codes or ds <= 1:
        return "prospect", codes, reden
    if ds == 2:
        if st("conversie") == "mist" or (fy and fy == CURRENT_YEAR - 1):
            if fy and fy == CURRENT_YEAR - 1:
                codes.append("footerjaar_vorig_jaar")
            return "prospect", codes, reden
        return "twijfel", codes, "Design gedateerd (2/5) maar verder in orde. " + reden
    return "niet_prospecteren", codes, f"Design {ds}/5, verzorgd. " + bew("design")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--model", default="gemini-3.8-flash")
    ap.add_argument("--env", default="")
    ap.add_argument("--anchors", default="", help="CSV met website,thibo,toelichting om als voorbeelden mee te geven")
    ap.add_argument("--anchor-run", default="", help="run-map waar de screenshots van de ankers staan")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--tag", default="judgment")
    a = ap.parse_args()
    key = load_key(a.env)
    run = Path(a.run)
    sys.path.insert(0, str(Path(__file__).parent))
    from capture import slug

    anchor_parts, anchor_urls = [], set()
    if a.anchors:
        ar = Path(a.anchor_run or a.run)
        anchor_parts.append({"text": "VOORBEELDEN van Thibo's eigen oordelen, ter kalibratie van zijn smaak:"})
        for r in csv.DictReader(open(a.anchors, encoding="utf-8")):
            d = ar / slug(r["website"].strip() if re.match(r"https?://", r["website"].strip()) else "http://" + r["website"].strip())
            if not (d / "facts.json").exists():
                continue
            f = json.loads((d / "facts.json").read_text())
            lab = f"→ Thibo's oordeel over {r['website']}: {r['thibo'].upper()}." + (f" Zijn toelichting: {r['toelichting']}" if r.get("toelichting") else "")
            anchor_parts += site_parts(d, f, lab)
            anchor_urls.add(r["website"].strip())
        anchor_parts.append({"text": "EINDE VOORBEELDEN. Beoordeel nu de volgende site op dezelfde manier:"})

    dirs = sorted(p.parent for p in run.glob("*/facts.json"))
    def work(d):
        out = d / f"{a.tag}.json"
        if out.exists() and not a.force:
            return "skip"
        f = json.loads((d / "facts.json").read_text())
        if f.get("input_url", "").strip() in anchor_urls:
            return "anker"
        j, usage = {}, {}
        if f.get("loaded", True) and f.get("page_type") not in PLACEHOLDER_TYPES and f.get("page_type") != "laadt_niet":
            j, usage = call_gemini(key, a.model, anchor_parts + site_parts(d, f))
        dec, codes, reason = decide(f, j)
        out.write_text(json.dumps({"url": f.get("input_url"), "id": f.get("id"), "beslissing": dec, "codes": codes, "reden": reason,
                                   "model": a.model, "model_output": j, "usage": usage}, ensure_ascii=False, indent=1))
        return dec
    stats = {}
    with cf.ThreadPoolExecutor(a.workers) as ex:
        def safe(d):
            try:
                return work(d)
            except Exception as e:
                print("FOUT", d.name, str(e)[:200], flush=True)
                return "fout"
        for d, r in zip(dirs, ex.map(safe, dirs)):
            stats[r] = stats.get(r, 0) + 1
            print(r, d.name, flush=True)
    print("KLAAR", stats)

if __name__ == "__main__":
    main()


# ---------- Gebruik door de piloot ----------
_ANCHOR_CACHE = {}

def anchor_parts_from_dir(anchor_csv, anchor_dir):
    key = (anchor_csv, anchor_dir)
    if key in _ANCHOR_CACHE:
        return _ANCHOR_CACHE[key]
    from capture import slug
    parts = [{"text": "VOORBEELDEN van Thibo's eigen oordelen, ter kalibratie van zijn smaak:"}]
    for r in csv.DictReader(open(anchor_csv, encoding="utf-8")):
        d = Path(anchor_dir) / slug(r["website"].strip())
        if not (d / "facts.json").exists():
            continue
        f = json.loads((d / "facts.json").read_text())
        lab = f"→ Thibo's oordeel over {r['website']}: {r['thibo'].upper()}." + (f" Zijn toelichting: {r['toelichting']}" if r.get("toelichting") else "")
        parts += site_parts(d, f, lab)
    parts.append({"text": "EINDE VOORBEELDEN. Beoordeel nu de volgende site op dezelfde manier:"})
    _ANCHOR_CACHE[key] = parts
    return parts

def judge_for_pilot(key, model, site_dir, facts, niche_omschrijving, anchor_parts, cache=None):
    """Geeft (beslissing, codes, reden, model_output, usage). Beslissing: prospect / twijfel / niet_prospecteren / buiten_niche."""
    pt = facts.get("page_type")
    if not facts.get("loaded", True) or pt in ("laadt_niet", "bot_geblokkeerd"):
        return "twijfel", ["laadt_niet"], "Website laadt niet.", {}, {}
    if pt in PLACEHOLDER_TYPES:
        return "twijfel", ["hostingpagina"], f"Geen echte website ({pt}); niet automatisch mailen.", {}, {}
    extra = {"text": f"De opgegeven niche voor dit bedrijf is: {niche_omschrijving}."}
    prefix = [] if cache else anchor_parts
    j, usage = call_gemini(key, model, prefix + site_parts(Path(site_dir), facts) + [extra], cache=cache)
    if j.get("hoofdactiviteit_past") != "ja" or j.get("taal") != "nl" or j.get("lokaal_kmo") is False:
        return "buiten_niche", [], f"Niche/taal/lokaal: {j.get('hoofdactiviteit_past')}/{j.get('taal')}/{j.get('lokaal_kmo')}. {j.get('nichefit_opmerking','')}", j, usage
    dec, codes, reden = decide(facts, j)
    return dec, codes, reden, j, usage
