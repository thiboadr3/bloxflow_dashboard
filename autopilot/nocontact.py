"""Naamgebaseerde no-contactcontrole (agency-klanten). Liever te streng dan te los.

Een kandidaat wordt geblokkeerd als:
- de genormaliseerde naam gelijk is aan een lijstnaam, of
- een lijstnaam van ≥6 tekens voorkomt in de bedrijfsnaam of in het websitedomein, of
- een korte lijstnaam (<6 tekens) als los woord in de bedrijfsnaam staat of exact het domeinlabel is.
"""
import re, unicodedata

LEGAL = r"\b(bv|bvba|nv|vof|cv|cvba|commv|comm v|srl|sprl|sa|bvbа|vzw|group|groep)\b"

def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(LEGAL, " ", s)
    return re.sub(r"[^a-z0-9]", "", s)

def words(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", s)

def domain_label(url):
    host = re.sub(r"^https?://", "", (url or "").lower()).split("/")[0].removeprefix("www.")
    return host.rsplit(".", 1)[0].replace(".", "").replace("-", "") if "." in host else host

class NoContact:
    def __init__(self, names):
        self.entries = []
        for n in names:
            k = norm(n)
            if k:
                self.entries.append((n, k, words(n)))

    def match(self, company_name, website=""):
        cn, cw, dl = norm(company_name), words(company_name), domain_label(website)
        for orig, k, w in self.entries:
            if cn == k or dl == k:
                return orig
            if len(k) >= 6 and (k in cn or k in dl):
                return orig
            if len(k) < 6 and w and any(cw[i:i + len(w)] == w for i in range(len(cw) - len(w) + 1)):
                return orig
        return None
