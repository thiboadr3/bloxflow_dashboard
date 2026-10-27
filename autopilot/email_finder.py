"""Zoekt een exact, publiek zakelijk e-mailadres op de eigen website (homepage + contactpagina's).

Regels (uit de algemene ICP): nooit gokken; info@/contact@ is goed; het adres moet letterlijk
op een publieke pagina staan. Voorkeur: adres op het eigen domein, dan algemene adressen.
Geeft (email, bron_url) of (None, None).
"""
import html, re, ssl, urllib.parse, urllib.request

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,24}")
BAD_PARTS = ("example.", "sentry", "wixpress", "domain.", "yourdomain", "email.com", "@2x", ".png", ".jpg", ".jpeg", ".webp", ".svg", ".gif",
             "godaddy", "noreply", "no-reply", "privacy@", "gdpr@", "dpo@", "webmaster@", "postmaster@", "abuse@")
CONTACT_HINTS = ("contact", "over-ons", "overons", "about", "info", "offerte", "impressum", "privacy")
PREFER = ("info@", "contact@", "hallo@", "hello@", "offerte@", "sales@", "verkoop@", "administratie@", "office@", "kantoor@")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

def fetch(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "nl-BE,nl;q=0.9"})
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        ctype = r.headers.get("Content-Type", "")
        if "html" not in ctype and "text" not in ctype:
            return r.geturl(), ""
        return r.geturl(), r.read(1_500_000).decode("utf-8", "ignore")

def domain_of(url):
    return urllib.parse.urlparse(url if "://" in url else "http://" + url).netloc.lower().removeprefix("www.")

def extract(page):
    page = html.unescape(page).replace("[at]", "@").replace("(at)", "@").replace(" [@] ", "@")
    page = re.sub(r"%40", "@", page)
    found = set()
    for m in EMAIL_RE.findall(page):
        e = m.strip(".").lower()
        if any(b in e for b in BAD_PARTS) or len(e) > 80:
            continue
        found.add(e)
    return found

def contact_links(base, page):
    links = []
    for href in re.findall(r'href=["\']([^"\'#]+)["\']', page, re.I):
        try:
            u = urllib.parse.urljoin(base, href)
            same = domain_of(u) == domain_of(base)
        except ValueError:
            continue
        if not same or re.search(r"\.(pdf|jpg|png|zip)$", u, re.I):
            continue
        if any(h in u.lower() for h in CONTACT_HINTS) and u not in links:
            links.append(u)
    return links[:5]

def rank(email, site_domain):
    d = email.split("@", 1)[1]
    same = d == site_domain or d.endswith("." + site_domain) or site_domain.endswith("." + d)
    generic_host = d in ("gmail.com", "hotmail.com", "outlook.com", "telenet.be", "skynet.be", "proximus.be", "live.be", "hotmail.be", "yahoo.com", "icloud.com")
    score = 0 if same else (1 if generic_host else 3)
    if email.startswith(PREFER):
        score -= 0.5
    return score

def find_email(website):
    """Nooit een uitzondering: één rare website (bv. ongeldige link) mag de hele run niet laten crashen."""
    try:
        return _find_email(website)
    except Exception:
        return None, None

def _find_email(website):
    try:
        base, page = fetch(website)
    except Exception:
        return None, None
    site_domain = domain_of(base)
    pages = [(base, page)]
    for link in contact_links(base, page):
        try:
            pages.append(fetch(link))
        except Exception:
            pass
    best = None
    for url, p in pages:
        for e in extract(p):
            r = rank(e, site_domain)
            if r >= 3:  # adres van een ander bedrijf (bv. webbouwer) — niet gebruiken
                continue
            if best is None or r < best[0]:
                best = (r, e, url)
    return (best[1], best[2]) if best else (None, None)
