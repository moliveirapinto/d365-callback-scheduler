"""
app.py — Callback Scheduler public booking bridge (Python 3.10+)

Tiny Flask app. Drop into any Python-based site (Flask, FastAPI, Django via WSGI,
plain gunicorn). Only dependency: flask + httpx.

ENV VARS:
    DV_ORG_URL              https://yourorg.crm.dynamics.com
    AAD_TENANT_ID           ...
    AAD_CLIENT_ID           ...
    AAD_CLIENT_SECRET       ...
    DV_PROACTIVE_CONFIG_ID  (optional)
    ALLOWED_ORIGIN          (optional)
    PORT                    default 3000

Run:
    pip install -r requirements.txt
    python app.py
"""
from __future__ import annotations

import json
import os
import re
import time
from collections import defaultdict, deque
from datetime import datetime, timezone

import httpx
from flask import Flask, jsonify, request

DV_ORG_URL = os.environ["DV_ORG_URL"].rstrip("/")
AAD_TENANT_ID = os.environ["AAD_TENANT_ID"]
AAD_CLIENT_ID = os.environ["AAD_CLIENT_ID"]
AAD_CLIENT_SECRET = os.environ["AAD_CLIENT_SECRET"]
DV_PROACTIVE_CONFIG_ID = os.environ.get("DV_PROACTIVE_CONFIG_ID", "").strip() or None
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "").strip() or None
PORT = int(os.environ.get("PORT", "3000"))

app = Flask(__name__)

# ---------- token cache ----------
_token: dict[str, float | str] = {"value": "", "exp": 0.0}

def get_token() -> str:
    if _token["value"] and time.time() < float(_token["exp"]):
        return str(_token["value"])
    r = httpx.post(
        f"https://login.microsoftonline.com/{AAD_TENANT_ID}/oauth2/v2.0/token",
        data={
            "client_id": AAD_CLIENT_ID,
            "client_secret": AAD_CLIENT_SECRET,
            "grant_type": "client_credentials",
            "scope": f"{DV_ORG_URL}/.default",
        },
        timeout=15,
    )
    r.raise_for_status()
    j = r.json()
    _token["value"] = j["access_token"]
    _token["exp"] = time.time() + j["expires_in"] - 300
    return j["access_token"]

def dv(method: str, path: str, body=None):
    r = httpx.request(
        method,
        f"{DV_ORG_URL}/api/data/v9.2/{path}",
        headers={
            "Authorization": f"Bearer {get_token()}",
            "Accept": "application/json",
            "OData-MaxVersion": "4.0",
            "OData-Version": "4.0",
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        },
        json=body,
        timeout=20,
    )
    if r.status_code >= 300:
        raise RuntimeError(f"Dataverse {method} {path} -> {r.status_code}: {r.text}")
    return r.json() if r.text else None

# ---------- rate limit (per-IP, in-process; swap for Redis in prod) ----------
_hits: dict[str, deque[float]] = defaultdict(deque)

def rate_ok(ip: str, n: int = 5) -> bool:
    now = time.time()
    q = _hits[ip]
    while q and now - q[0] > 60:
        q.popleft()
    q.append(now)
    return len(q) <= n

# ---------- core ----------
EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
PHONE_RE = re.compile(r"^\+?[0-9]{6,16}$")

def resolve_contact(p: dict) -> str:
    if p.get("email"):
        e = p["email"].replace("'", "''")
        r = dv("GET", f"contacts?$filter=emailaddress1 eq '{e}'&$select=contactid&$top=1")
        if r and r.get("value"):
            return r["value"][0]["contactid"]
    if p.get("phoneE164"):
        from urllib.parse import quote
        f = quote(f"mobilephone eq '{p['phoneE164']}'", safe="")
        r = dv("GET", f"contacts?$filter={f}&$select=contactid&$top=1")
        if r and r.get("value"):
            return r["value"][0]["contactid"]
    created = dv("POST", "contacts", {
        "firstname": p["firstName"],
        "lastname": p["lastName"],
        "emailaddress1": p.get("email"),
        "mobilephone": p.get("phoneE164"),
    })
    return created["contactid"]

def find_config() -> str:
    if DV_PROACTIVE_CONFIG_ID:
        return DV_PROACTIVE_CONFIG_ID
    r = dv("GET", "msdyn_proactive_engagement_configs?$select=msdyn_proactive_engagement_configid&$top=1")
    if not r or not r.get("value"):
        raise RuntimeError("No Proactive Engagement Configuration found.")
    return r["value"][0]["msdyn_proactive_engagement_configid"]

# ---------- HTTP ----------
@app.after_request
def cors(resp):
    if ALLOWED_ORIGIN:
        resp.headers["Access-Control-Allow-Origin"] = ALLOWED_ORIGIN
        resp.headers["Vary"] = "Origin"
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return resp

@app.route("/api/book", methods=["OPTIONS"])
def book_preflight():
    return ("", 204)

@app.post("/api/book")
def book():
    ip = (request.headers.get("X-Forwarded-For") or request.remote_addr or "na").split(",")[0].strip()
    if not rate_ok(ip):
        return jsonify(error="Too many requests"), 429

    p = request.get_json(silent=True) or {}
    if p.get("website"):
        return ("", 204)  # honeypot

    if not p.get("firstName") or not p.get("lastName"):
        return jsonify(error="name required"), 400
    if not p.get("email") or not EMAIL_RE.match(p["email"]):
        return jsonify(error="valid email required"), 400
    if not p.get("phoneE164") or not PHONE_RE.match(p["phoneE164"]):
        return jsonify(error="valid phone required"), 400
    if not p.get("consent"):
        return jsonify(error="consent required"), 400
    if not p.get("windowStartIso") or not p.get("windowEndIso"):
        return jsonify(error="time window required"), 400

    try:
        contact_id = resolve_contact(p)
        config_id = find_config()
        windows = json.dumps([{
            "StartTime": p["windowStartIso"],
            "EndTime":   p["windowEndIso"],
            "TimeZone":  p.get("timeZone", "UTC"),
        }])
        input_attrs = json.dumps({
            "Topic": p.get("topic", ""),
            "Notes": p.get("notes", ""),
            "Locale": p.get("locale", "en"),
            "ConsentTimestampUtc": p.get("consentTimestampUtc") or datetime.now(timezone.utc).isoformat(),
        })
        resp = dv("POST", "CCaaS_CreateProactiveVoiceDelivery", {
            "ProactiveEngagementConfigId": config_id,
            "ContactId": contact_id,
            "Windows": windows,
            "InputAttributes": input_attrs,
        })
        delivery_id = resp.get("DeliveryId")
        app.logger.info("book ok contact=%s delivery=%s email=%s", contact_id, delivery_id, p.get("email"))
        return jsonify(ok=True, deliveryId=delivery_id)
    except Exception as e:
        app.logger.exception("book failed: %s", e)
        return jsonify(error="Booking failed. Try again in a moment."), 502

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
