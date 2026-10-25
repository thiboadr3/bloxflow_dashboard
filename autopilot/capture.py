#!/usr/bin/env python3
"""Fase 2 — screenshots en technische feiten per website (geen oordeel).

Gebruik:
  python3 capture.py --input sites.csv --out runs/<naam> [--concurrency 4]
sites.csv heeft minstens een kolom 'website' (optioneel 'id', 'bedrijf').
Hervatbaar: sites met een bestaande facts.json worden overgeslagen.
"""
import argparse, asyncio, csv, hashlib, json, re, sys, time
from pathlib import Path
from urllib.parse import urlparse
from playwright.async_api import async_playwright

DESKTOP = {"width": 1440, "height": 900}
MOBILE = {"width": 390, "height": 844}
UA_MOBILE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1")
CURRENT_YEAR = time.localtime().tm_year

PLACEHOLDER = [
    (r"domain (name )?is for sale|domeinnaam (is )?te koop|dit domein is te koop|is te koop|koop dit domein|buy this domain|sedo|dan\.com|nameshift", "domein_te_koop"),
    (r"under construction|in aanbouw|binnenkort online|coming soon|website wordt (momenteel )?(vernieuwd|gebouwd)|nieuwe website.{0,40}(binnenkort|in aanbouw)", "in_aanbouw"),
    (r"one\.com.{0,80}(welcome|welkom|website)|wordt door one\.com gehost|er wordt aan de website gewerkt|this domain is (registered|parked)|registered domain name|this is the placeholder for domain|deze domeinnaam werd geregistreerd|someone has already reserved this domain|deze server wordt gehost|upload your website into the public_html|combell.{0,60}(geregistreerd|placeholder)|default web page|index of /|plesk|cpanel|it works!", "hostingpagina"),
]
COOKIE_BUTTONS = r"^(alles accepteren|alle cookies accepteren|accepteer alle|accepteren|akkoord|ik ga akkoord|accept all|accept|allow all|alle toestaan|toestaan|ok|oké|begrepen|tout accepter)$"
CTA = r"offerte|contact|afspraak|bel |bel ons|bellen|aanvraag|aanvragen|vraag .* aan|prijs|gratis|maak een|plan|reserveer|bestel"

JS_FACTS = r"""
() => {
  const vis = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 4 && r.height > 4 && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.05; };
  const host = location.hostname.replace(/^www\./,'');
  const links = [...document.querySelectorAll('a[href]')];
  const internal = new Set();
  for (const a of links) { try { const u = new URL(a.href, location.href);
      if (u.hostname.replace(/^www\./,'') === host && !/\.(pdf|jpg|png|jpeg|webp|zip)$/i.test(u.pathname)) {
        const p = u.pathname.replace(/\/$/,''); if (p) internal.add(p.toLowerCase()); } } catch(e){} }
  const navLinks = [...document.querySelectorAll('nav a[href], header a[href]')].map(a => (a.innerText||'').trim()).filter(Boolean);
  const foldCta = [...document.querySelectorAll('a, button, input[type=submit]')].filter(el => {
      const r = el.getBoundingClientRect(); return vis(el) && r.top >= 0 && r.top < innerHeight && r.bottom > 0; })
    .map(el => (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().toLowerCase()).filter(t => t && t.length < 60);
  const text = (document.body ? document.body.innerText : '') || '';
  return {
    title: document.title || '',
    lang: document.documentElement.lang || '',
    generator: (document.querySelector('meta[name=generator]')||{}).content || '',
    has_viewport_meta: !!document.querySelector('meta[name=viewport]'),
    scroll_width: document.documentElement.scrollWidth, inner_width: innerWidth,
    page_height: document.documentElement.scrollHeight,
    internal_paths: [...internal].slice(0, 300),
    nav_texts: navLinks.slice(0, 60),
    fold_clickables: foldCta.slice(0, 40),
    has_form: !!document.querySelector('form input, form textarea'),
    has_tel: !!document.querySelector('a[href^="tel:"]'),
    has_mailto: !!document.querySelector('a[href^="mailto:"]'),
    iframe_count: document.querySelectorAll('iframe').length,
    img_count: document.images.length,
    text: text.slice(0, 20000),
  };
}
"""

def slug(url):
    host = urlparse(url if "://" in url else "http://" + url).netloc.replace("www.", "")
    return re.sub(r"[^a-z0-9.-]", "_", host.lower()) + "-" + hashlib.sha1(url.encode()).hexdigest()[:6]

async def dismiss_cookies(page):
    try:
        for frame in [page.main_frame] + page.frames[1:4]:
            btns = frame.get_by_role("button", name=re.compile(COOKIE_BUTTONS, re.I))
            if await btns.count():
                await btns.first.click(timeout=1500)
                await page.wait_for_timeout(600)
                return True
    except Exception:
        pass
    return False

async def load(page, url):
    resp = None
    for attempt in range(2):
        try:
            resp = await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            try:
                await page.wait_for_load_state("networkidle", timeout=12000)
            except Exception:
                pass
            await page.wait_for_timeout(1500)
            return resp, None
        except Exception as e:
            err = str(e).split("\n")[0][:200]
            if attempt == 0 and url.startswith("http://"):
                url = "https://" + url[len("http://"):]
            await page.wait_for_timeout(1500)
    return resp, err

async def autoscroll(page, max_px):
    """Scroll stapsgewijs zodat lazy-loaded afbeeldingen laden, dan terug naar boven."""
    try:
        await page.evaluate("""async (maxPx) => {
            const step = Math.max(300, Math.floor(innerHeight * 0.8));
            for (let y = 0; y < Math.min(document.documentElement.scrollHeight, maxPx); y += step) {
                window.scrollTo(0, y); await new Promise(r => setTimeout(r, 180)); }
            window.scrollTo(0, 0); }""", max_px)
        await page.wait_for_timeout(900)
    except Exception:
        pass

def footer_years(text):
    tail = text[-2500:]
    yrs = [int(y) for y in re.findall(r"(?:©|copyright|\(c\)|&copy;)[^\n]{0,40}?((?:19|20)\d\d)(?:\s*[-–]\s*((?:19|20)\d\d))?", tail, re.I) for y in y if y]
    if not yrs:
        yrs = [int(y) for y in re.findall(r"\b(20[0-2]\d)\b", tail)]
    return max(yrs) if yrs else None

async def capture_one(browser, row, outdir):
    url = row["website"].strip()
    if not re.match(r"https?://", url):
        url = "http://" + url
    d = outdir / slug(url)
    if (d / "facts.json").exists():
        return "skip"
    d.mkdir(parents=True, exist_ok=True)
    facts = {"input_url": url, "id": row.get("id", ""), "bedrijf": row.get("bedrijf", ""), "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    # Desktop
    ctx = await browser.new_context(viewport=DESKTOP, locale="nl-BE", ignore_https_errors=True)
    page = await ctx.new_page()
    resp, err = await load(page, url)
    facts["final_url"] = page.url
    facts["status"] = resp.status if resp else None
    facts["ssl"] = page.url.startswith("https://")
    if err and not resp:
        facts["loaded"] = False
        facts["error"] = err
        await ctx.close()
        facts["page_type"] = "laadt_niet"
        (d / "facts.json").write_text(json.dumps(facts, ensure_ascii=False, indent=1))
        return "fail"
    facts["loaded"] = True
    await dismiss_cookies(page)
    await autoscroll(page, 3200)
    dj = await page.evaluate(JS_FACTS)
    await page.screenshot(path=str(d / "desktop.jpg"), type="jpeg", quality=60,
                          clip={"x": 0, "y": 0, "width": DESKTOP["width"], "height": min(max(dj["page_height"], 900), 3200)}, full_page=True)
    await ctx.close()
    # Mobile
    ctx = await browser.new_context(viewport=MOBILE, user_agent=UA_MOBILE, is_mobile=True, has_touch=True,
                                    device_scale_factor=2, locale="nl-BE", ignore_https_errors=True)
    page = await ctx.new_page()
    mresp, merr = await load(page, facts["final_url"])
    mj = None
    if mresp or not merr:
        await dismiss_cookies(page)
        await autoscroll(page, 2500)
        mj = await page.evaluate(JS_FACTS)
        await page.screenshot(path=str(d / "mobile.jpg"), type="jpeg", quality=55,
                              clip={"x": 0, "y": 0, "width": MOBILE["width"], "height": min(max(mj["page_height"], 844), 2500)}, full_page=True)
    await ctx.close()

    text = dj.pop("text")
    low = text.lower()
    ptype = "website"
    for pat, name in PLACEHOLDER:
        if re.search(pat, low[:4000] + " " + dj["title"].lower()):
            ptype = name
            break
    if ptype == "website" and re.search(r"access denied|verify you are human|attention required|just a moment\.\.\.|checking your browser|error 15|request blocked", low[:1500] + " " + dj["title"].lower()) and len(text) < 2500:
        ptype = "bot_geblokkeerd"
    if ptype == "website" and len(text.strip()) < 150 and dj["iframe_count"] == 0 and len(dj["internal_paths"]) <= 1:
        ptype = "bijna_leeg"
    facts.update({
        "page_type": ptype,
        "title": dj["title"], "lang": dj["lang"], "generator": dj["generator"],
        "has_viewport_meta": dj["has_viewport_meta"],
        "text_chars": len(text),
        "footer_year": footer_years(text),
        "internal_page_count": len(dj["internal_paths"]),
        "internal_paths_sample": dj["internal_paths"][:60],
        "nav_texts": dj["nav_texts"],
        "has_form_home": dj["has_form"], "has_tel": dj["has_tel"], "has_mailto": dj["has_mailto"],
        "desktop_fold_cta": [t for t in dj["fold_clickables"] if re.search(CTA, t)],
        "text_excerpt": re.sub(r"\s+", " ", text)[:2500],
    })
    if mj:
        facts.update({
            "mobile_overflow_px": max(0, mj["scroll_width"] - mj["inner_width"]),
            "mobile_fold_cta": [t for t in mj["fold_clickables"] if re.search(CTA, t)],
            "mobile_fold_clickables": mj["fold_clickables"][:20],
        })
    else:
        facts["mobile_error"] = merr
    (d / "facts.json").write_text(json.dumps(facts, ensure_ascii=False, indent=1))
    return "ok"

async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    rows = list(csv.DictReader(open(a.input, encoding="utf-8")))
    if a.limit:
        rows = rows[: a.limit]
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(a.concurrency)
    stats = {}
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--disable-dev-shm-usage"])
        async def run(row):
            async with sem:
                try:
                    r = await asyncio.wait_for(capture_one(browser, row, out), timeout=150)
                except Exception as e:
                    r = "error"
                    d = out / slug(row["website"].strip())
                    d.mkdir(parents=True, exist_ok=True)
                    (d / "facts.json").write_text(json.dumps({"input_url": row["website"], "id": row.get("id", ""), "loaded": False,
                                                               "page_type": "laadt_niet", "error": str(e)[:200]}, ensure_ascii=False))
                stats[r] = stats.get(r, 0) + 1
                print(r, row["website"], flush=True)
        await asyncio.gather(*(run(r) for r in rows))
        await browser.close()
    print("KLAAR", stats)

if __name__ == "__main__":
    asyncio.run(main())
