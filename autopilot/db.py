"""Kleine Supabase-client (PostgREST) met de service-role sleutel. Geen externe pakketten."""
import json, os, urllib.request, urllib.error

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
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"Supabase {method} {path}: {e.code} {e.read().decode()[:400]}")

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

    def identity_keys(self, record):
        return self.rpc("bloxflow_identity_keys", d=record)

    def known(self, keys, name, place_id):
        return self.rpc("bloxflow_autopilot_known", p_keys=keys, p_name=name, p_place=place_id)

    def insert_prospect(self, record, run_id):
        if self.dry_run:
            return "droge-run"
        return self.rpc("bloxflow_autopilot_insert", p=record, p_run=run_id)

    def save_cursor(self, cursor):
        if not self.dry_run:
            self.rpc("bloxflow_autopilot_save_cursor", p_cursor=cursor)

    def log_candidate(self, row):
        return self.insert("outreach_autopilot_candidates", row)
