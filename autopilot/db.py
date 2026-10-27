"""Kleine Supabase-client (PostgREST) met de service-role sleutel. Geen externe pakketten."""
import json, os, time, urllib.request, urllib.error

class DB:
    def __init__(self, url=None, key=None, dry_run=False):
        self.url = (url or os.environ["SUPABASE_URL"]).rstrip("/")
        self.key = key or os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        self.dry_run = dry_run

    def _req(self, method, path, body=None, prefer=None):
        headers = {"apikey": self.key, "Authorization": "Bearer " + self.key, "Content-Type": "application/json"}
        if prefer:
            headers["Prefer"] = prefer
        req = urllib.request.Request(self.url + path, method=method, headers=headers,
                                     data=json.dumps(body).encode() if body is not None else None)
        # Tijdelijke fouten (time-out, 5xx, netwerk) tot 3 keer opnieuw proberen i.p.v. de run te laten crashen.
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    txt = r.read().decode()
                    return json.loads(txt) if txt else None
            except urllib.error.HTTPError as e:
                body = e.read().decode()[:400]
                if attempt < 3 and (e.code >= 500 or e.code == 429 or "57014" in body):
                    time.sleep(2 * (attempt + 1)); continue
                raise RuntimeError(f"Supabase {method} {path}: {e.code} {body}")
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt < 3:
                    time.sleep(2 * (attempt + 1)); continue
                raise RuntimeError(f"Supabase {method} {path}: {e}")

    def rpc(self, fn, **args):
        return self._req("POST", f"/rest/v1/rpc/{fn}", args)

    def select(self, table, query):
        return self._req("GET", f"/rest/v1/{table}?{query}")

    def insert(self, table, row):
        if self.dry_run:
            return None
        return self._req("POST", f"/rest/v1/{table}", row, prefer="return=representation")

    def update(self, table, query, row):
        if self.dry_run:
            return None
        return self._req("PATCH", f"/rest/v1/{table}?{query}", row)

    # --- piloot ---
    def settings(self):
        return self.select("outreach_autopilot_settings", "id=eq.true&select=*")[0]

    def planned_today(self):
        """Aantal prospects dat de piloot vandaag (Belgische tijd) al inplande."""
        return int(self.rpc("bloxflow_autopilot_planned_today") or 0)

    def identity_keys(self, record):
        return self.rpc("bloxflow_identity_keys", d=record)

    def check(self, items):
        """Eén call voor een hele lijst: [{website_url, phone, company_name, municipality, email?, place_id?}] -> [{keys, reason}]."""
        if not items:
            return []
        return self.rpc("bloxflow_autopilot_check", p_items=items)

    def known(self, keys, name, place_id):
        return self.rpc("bloxflow_autopilot_known", p_keys=keys, p_name=name, p_place=place_id)

    def backlog(self, sector, limit=40, exclude=()):
        """Nog nooit gemailde bedrijven uit onze database (met website) die de piloot nog niet beoordeelde."""
        return self.rpc("bloxflow_autopilot_backlog", p_sector=sector, p_limit=limit, p_exclude=list(exclude)) or []

    def promote_prospect(self, prospect_id, record, run_id):
        if self.dry_run:
            return "droge-run"
        return self.rpc("bloxflow_autopilot_promote", p_id=prospect_id, p=record, p_run=run_id)

    def insert_prospect(self, record, run_id):
        if self.dry_run:
            return "droge-run"
        return self.rpc("bloxflow_autopilot_insert", p=record, p_run=run_id)

    def save_cursor(self, cursor):
        if not self.dry_run:
            self.rpc("bloxflow_autopilot_save_cursor", p_cursor=cursor)

    def log_candidate(self, row):
        return self.insert("outreach_autopilot_candidates", row)
