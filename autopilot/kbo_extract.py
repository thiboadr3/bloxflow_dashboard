"""KBO Open Data -> kbo_bedrijven.csv voor de piloot.

Per sector de actieve ondernemingen in Vlaanderen met een eigen bedrijfsdomein
(website of e-mail op eigen domein; geen gmail/telenet/...). Gebruik:
    python3 extract.py <map met KBO-csv's> <uitvoer.csv>
"""
import csv, re, sys, collections

D, OUT = sys.argv[1], sys.argv[2]

# (versie, prefix) per sector; volgorde = voorrang als een bedrijf in meerdere sectoren valt
SECTORS = {
    "HVAC": [("2008", "4322"), ("2025", "4322")],
    "DAK & GEVEL": [("2008", "4391"), ("2008", "43992"), ("2008", "4399111"), ("2025", "4341"), ("2025", "8122011"), ("2025", "4342101")],
    "SCHRIJNWERK": [("2008", "4332"), ("2025", "4332"), ("2008", "1623"), ("2025", "1623")],
    "TUINAANLEG": [("2008", "8130"), ("2025", "8130")],
    "METAALWERK": [("2008", "2511"), ("2025", "2511"), ("2008", "2512"), ("2025", "2512")],
    "SOLAR": [("2025", "43213")],
    "RENOVATIE": [("2008", "43291"), ("2025", "4323"), ("2008", "4339"), ("2025", "4339")],
}
ORDER = list(SECTORS)

def sector_of(ver, code):
    for s, rules in SECTORS.items():
        for v, p in rules:
            if v == ver and code.startswith(p):
                return s
    return None

FREE = re.compile(r"^(gmail|googlemail|hotmail|outlook|live|telenet|skynet|proximus|belgacom|yahoo|icloud|me|msn|pandora|scarlet|base|t-online|email|mail|gmx|ukr|pm|protonmail|proton|orange|voo|edpnet|online|web|aol|zonnet|planet|hotmail\.co|wanadoo|free|laposte|onet|wp|o2|seznam|mac)\.", re.I)

def domain(v):
    v = v.strip().lower()
    if "@" in v:
        d = v.rsplit("@", 1)[1]
    else:
        d = re.sub(r"^https?://", "", v); d = re.sub(r"^www\.", "", d).split("/")[0]
    d = d.strip(". ")
    if "." not in d or FREE.match(d) or " " in d:
        return None
    return d

def flemish(z):
    try:
        z = int(z)
    except Exception:
        return False
    return 1500 <= z <= 3999 or 8000 <= z <= 9999

# 1. activiteiten -> sector per entiteit (hoofdactiviteit telt eerst)
hits = collections.defaultdict(lambda: {"main": set(), "any": set()})
with open(f"{D}/activity.csv", encoding="utf-8") as f:
    r = csv.reader(f); next(r)
    for num, grp, ver, code, cls in r:
        s = sector_of(ver, code)
        if s:
            hits[num]["any"].add(s)
            if cls == "MAIN":
                hits[num]["main"].add(s)

est2ent = {}
with open(f"{D}/establishment.csv", encoding="utf-8") as f:
    r = csv.reader(f); next(r)
    for est, start, ent in r:
        est2ent[est] = ent

ents = {}
with open(f"{D}/enterprise.csv", encoding="utf-8") as f:
    r = csv.reader(f); next(r)
    for num, *_ in r:
        ents[num] = True

def ent_of(num):
    return est2ent.get(num) if num.startswith("2.") else num

agg = collections.defaultdict(lambda: {"main": set(), "any": set()})
for num, h in hits.items():
    e = ent_of(num)
    if e in ents:
        agg[e]["main"] |= h["main"]; agg[e]["any"] |= h["any"]

def pick(h):
    pool = h["main"] or h["any"]
    return next(s for s in ORDER if s in pool), bool(h["main"])

keep = {e: pick(h) for e, h in agg.items()}

addr, names = {}, {}
with open(f"{D}/address.csv", encoding="utf-8") as f:
    r = csv.reader(f); next(r)
    for row in r:
        e = ent_of(row[0])
        if e in keep and flemish(row[4]) and (e not in addr or row[0] == e):
            addr[e] = (row[4], row[5])
with open(f"{D}/denomination.csv", encoding="utf-8") as f:
    r = csv.reader(f); next(r)
    for num, lang, typ, den in r:
        e = ent_of(num)
        if e in keep and (e not in names or (num == e and typ == "001")):
            names[e] = den

con = collections.defaultdict(lambda: {"EMAIL": [], "WEB": [], "TEL": []})
with open(f"{D}/contact.csv", encoding="utf-8") as f:
    r = csv.reader(f); next(r)
    for num, ec, typ, val in r:
        e = ent_of(num)
        if e in keep and typ in con[e]:
            con[e][typ].append(val.strip())

seen, rows = set(), []
stats = collections.Counter()
for e, (sector, main) in keep.items():
    if e not in addr:
        continue
    stats[sector + "|vlaanderen"] += 1
    c = con.get(e)
    if not c:
        continue
    webs = [w for w in c["WEB"] if domain(w)]
    mails = [m for m in c["EMAIL"] if "@" in m and domain(m)]
    d = domain(webs[0]) if webs else (domain(mails[0]) if mails else None)
    if not d or d in seen:
        continue
    seen.add(d)
    site = webs[0] if webs else "https://" + d
    if not site.lower().startswith("http"):
        site = "https://" + site.lstrip("/")
    mail = next((m.lower() for m in mails if domain(m) == d), mails[0].lower() if mails else "")
    stats[sector + "|met_domein"] += 1
    rows.append({"sector": sector, "kbo": e, "naam": names.get(e, ""), "website_url": site, "email": mail,
                 "telefoon": c["TEL"][0] if c["TEL"] else "", "postcode": addr[e][0], "gemeente": addr[e][1],
                 "hoofdactiviteit": "1" if main else "0"})

# hoofdactiviteit eerst
rows.sort(key=lambda x: (ORDER.index(x["sector"]), x["hoofdactiviteit"] != "1", x["kbo"]))
with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]))
    w.writeheader(); w.writerows(rows)
for s in ORDER:
    print(f"{s:12} Vlaanderen {stats[s+'|vlaanderen']:6}  met eigen domein {stats[s+'|met_domein']:5}")
print("totaal rijen:", len(rows))
