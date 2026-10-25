"""Bedrijven zoeken via Google Places API (New) — Text Search.

Elke zoekopdracht is '<zoekterm> in <gemeente>'. De piloot onthoudt in Supabase welke
combinaties al gedaan zijn (cursor), zodat elke dag nieuwe combinaties aan bod komen.
Enkel bedrijven met een Vlaamse postcode (1500-3999, 8000-9999), een website en
status OPERATIONAL komen door.
"""
import json, re, time, urllib.request

GEMEENTEN = """Aalst Aalter Aarschot Aartselaar Affligem Alken Alveringem Antwerpen Anzegem Ardooie Arendonk As Asse Assenede Avelgem
Baarle-Hertog Balen Beernem Beerse Beersel Begijnendijk Bekkevoort Beringen Berlaar Berlare Bertem Bever Beveren Bierbeek Bilzen Blankenberge
Bocholt Boechout Bonheiden Boom Boortmeerbeek Bornem Borsbeek Bouwel Brakel Brasschaat Brecht Bredene Bree Brugge Buggenhout Damme Deerlijk
Deinze Denderleeuw Dendermonde Dentergem Dessel Destelbergen Diepenbeek Diest Diksmuide Dilbeek Dilsen-Stokkem Drogenbos Duffel Edegem Eeklo
Erpe-Mere Essen Evergem Galmaarden Gavere Geel Geetbets Genk Gent Geraardsbergen Gingelom Gistel Glabbeek Gooik Grimbergen Grobbendonk
Haacht Haaltert Halen Halle Hamme Hamont-Achel Harelbeke Hasselt Hechtel-Eksel Heers Heist-op-den-Berg Hemiksem Herent Herentals Herenthout
Herk-de-Stad Herne Herselt Herzele Heusden-Zolder Heuvelland Hoegaarden Hoeilaart Hoeselt Holsbeek Hooglede Hoogstraten Horebeke Houthalen-Helchteren
Houthulst Hove Huldenberg Hulshout Ichtegem Ieper Ingelmunster Izegem Jabbeke Kalmthout Kampenhout Kapelle-op-den-Bos Kapellen Kaprijke Kasterlee
Keerbergen Kinrooi Kluisbergen Knokke-Heist Koekelare Koksijde Kontich Kortemark Kortenaken Kortenberg Kortrijk Kruibeke Kruisem Kuurne Laakdal
Laarne Lanaken Landen Lebbeke Lede Ledegem Lendelede Lennik Leopoldsburg Leuven Lichtervelde Liedekerke Lier Lierde Lille Linkebeek Lint Linter
Lochristi Lokeren Lommel Londerzeel Lubbeek Lummen Maarkedal Maaseik Maasmechelen Machelen Maldegem Malle Mechelen Meerhout Meise Melle Menen
Merchtem Merelbeke Merksplas Mesen Meulebeke Middelkerke Moerbeke Mol Moorslede Mortsel Nazareth Niel Nieuwerkerken Nieuwpoort Nijlen Ninove
Olen Oostende Oosterzele Oostkamp Oostrozebeke Opwijk Oudenaarde Oudenburg Oud-Heverlee Oud-Turnhout Overijse Peer Pelt Pittem Poperinge Putte
Puurs-Sint-Amands Ranst Ravels Retie Riemst Rijkevorsel Roeselare Ronse Roosdaal Rotselaar Ruiselede Rumst Schelle Scherpenheuvel-Zichem Schilde
Schoten Sint-Genesius-Rode Sint-Gillis-Waas Sint-Katelijne-Waver Sint-Laureins Sint-Lievens-Houtem Sint-Martens-Latem Sint-Niklaas Sint-Pieters-Leeuw
Sint-Truiden Spiere-Helkijn Stabroek Staden Steenokkerzeel Stekene Temse Ternat Tervuren Tessenderlo Tielt Tielt-Winge Tienen Tongeren Torhout
Tremelo Turnhout Veurne Vilvoorde Vleteren Voeren Vorselaar Vosselaar Waasmunster Wachtebeke Waregem Wellen Wemmel Wervik Westerlo Wetteren
Wevelgem Wezembeek-Oppem Wichelen Wielsbeke Wijnegem Willebroek Wingene Wommelgem Wortegem-Petegem Wuustwezel Zandhoven Zaventem Zedelgem
Zele Zelzate Zemst Zingem Zoersel Zomergem Zonhoven Zonnebeke Zottegem Zoutleeuw Zuienkerke Zulte Zutendaal Zwalm Zwevegem Zwijndrecht""".split()

FIELDS = ",".join(["places.id", "places.displayName", "places.formattedAddress", "places.addressComponents",
                   "places.websiteUri", "places.nationalPhoneNumber", "places.businessStatus",
                   "places.primaryTypeDisplayName", "nextPageToken"])

def flemish_postcode(place):
    pc = None
    for c in place.get("addressComponents", []):
        if "postal_code" in c.get("types", []):
            pc = c.get("longText") or c.get("shortText")
    if not pc:
        m = re.search(r"\b(\d{4})\b", place.get("formattedAddress", ""))
        pc = m.group(1) if m else None
    if not pc or not pc.isdigit():
        return None
    n = int(pc)
    return pc if (1500 <= n <= 3999 or 8000 <= n <= 9999) else None

def municipality(place):
    for c in place.get("addressComponents", []):
        if "locality" in c.get("types", []):
            return c.get("longText")
    return None

def search(api_key, query, max_pages=3):
    """Geeft een lijst ruwe Places terug (max 60 per zoekopdracht)."""
    out, token = [], None
    for _ in range(max_pages):
        body = {"textQuery": query, "languageCode": "nl", "regionCode": "BE", "pageSize": 20}
        if token:
            body["pageToken"] = token
        req = urllib.request.Request("https://places.googleapis.com/v1/places:searchText",
                                     data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "X-Goog-Api-Key": api_key,
                                              "X-Goog-FieldMask": FIELDS})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
        out += data.get("places", [])
        token = data.get("nextPageToken")
        if not token:
            break
        time.sleep(2)
    return out

def candidates(api_key, query):
    """Filtert op Vlaanderen, actief en met website."""
    res = []
    for p in search(api_key, query):
        if p.get("businessStatus") not in (None, "OPERATIONAL"):
            continue
        site = p.get("websiteUri")
        pc = flemish_postcode(p)
        if not site or not pc:
            continue
        res.append({
            "place_id": p.get("id"),
            "company_name": (p.get("displayName") or {}).get("text", ""),
            "website_url": site,
            "phone": p.get("nationalPhoneNumber"),
            "address": p.get("formattedAddress"),
            "postcode": pc,
            "municipality": municipality(p),
            "google_type": (p.get("primaryTypeDisplayName") or {}).get("text"),
            "query": query,
        })
    return res
