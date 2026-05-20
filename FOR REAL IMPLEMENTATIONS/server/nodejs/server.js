// server.js — Callback Scheduler public booking bridge (Node.js)
// Drop-in for any Node-based site (Express, plain http, Next.js custom server).
// Requires Node 18+ (for native fetch). No external deps beyond express.
//
// Run standalone:   node server.js
// Or import the `bookingRouter` into an existing Express app.
//
// ENV VARS (set in your hosting platform's secret store, NOT in code):
//   DV_ORG_URL              https://yourorg.crm.dynamics.com
//   AAD_TENANT_ID           00000000-0000-0000-0000-000000000000
//   AAD_CLIENT_ID           00000000-0000-0000-0000-000000000000
//   AAD_CLIENT_SECRET       <secret from Entra app reg>
//   DV_PROACTIVE_CONFIG_ID  00000000-0000-0000-0000-000000000000   (optional)
//   PORT                    3000                                    (optional)
//   ALLOWED_ORIGIN          https://your-public-site.com            (optional, recommended)

import express from 'express';

const {
  DV_ORG_URL,
  AAD_TENANT_ID,
  AAD_CLIENT_ID,
  AAD_CLIENT_SECRET,
  DV_PROACTIVE_CONFIG_ID,
  ALLOWED_ORIGIN,
  PORT = 3000,
} = process.env;

for (const k of ['DV_ORG_URL', 'AAD_TENANT_ID', 'AAD_CLIENT_ID', 'AAD_CLIENT_SECRET']) {
  if (!process.env[k]) { console.error(`Missing env var ${k}`); process.exit(1); }
}

// ---------- token cache ----------
let tokenCache = { value: null, expiresAt: 0 };
async function getToken() {
  if (tokenCache.value && Date.now() < tokenCache.expiresAt) return tokenCache.value;
  const body = new URLSearchParams({
    client_id: AAD_CLIENT_ID,
    client_secret: AAD_CLIENT_SECRET,
    grant_type: 'client_credentials',
    scope: `${DV_ORG_URL}/.default`,
  });
  const r = await fetch(`https://login.microsoftonline.com/${AAD_TENANT_ID}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!r.ok) throw new Error(`Token endpoint ${r.status}: ${await r.text()}`);
  const j = await r.json();
  tokenCache = { value: j.access_token, expiresAt: Date.now() + (j.expires_in - 300) * 1000 };
  return tokenCache.value;
}

// ---------- Dataverse helper ----------
async function dv(method, path, body) {
  const token = await getToken();
  const r = await fetch(`${DV_ORG_URL}/api/data/v9.2/${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      'OData-MaxVersion': '4.0',
      'OData-Version': '4.0',
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Dataverse ${method} ${path} → ${r.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

// ---------- rate limit (in-memory, replace with Redis for multi-instance) ----------
const hits = new Map();
function rateLimit(ip, maxPerMin = 5) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < 60_000);
  arr.push(now);
  hits.set(ip, arr);
  return arr.length <= maxPerMin;
}

// ---------- core booking logic ----------
async function resolveContact({ firstName, lastName, email, phoneE164 }) {
  // Try email first
  if (email) {
    const e = email.replace(/'/g, "''");
    const r = await dv('GET', `contacts?$filter=emailaddress1 eq '${e}'&$select=contactid&$top=1`);
    if (r.value && r.value.length) return r.value[0].contactid;
  }
  // Then mobile (E.164 may contain +, encode it)
  if (phoneE164) {
    const filter = encodeURIComponent(`mobilephone eq '${phoneE164}'`);
    const r = await dv('GET', `contacts?$filter=${filter}&$select=contactid&$top=1`);
    if (r.value && r.value.length) return r.value[0].contactid;
  }
  // Create
  const created = await dv('POST', 'contacts', {
    firstname: firstName,
    lastname: lastName,
    emailaddress1: email,
    mobilephone: phoneE164,
  });
  return created.contactid;
}

async function findProactiveConfig() {
  if (DV_PROACTIVE_CONFIG_ID) return DV_PROACTIVE_CONFIG_ID;
  const r = await dv('GET', `msdyn_proactive_engagement_configs?$select=msdyn_proactive_engagement_configid&$top=1`);
  if (!r.value || !r.value.length) throw new Error('No Proactive Engagement Configuration found in this environment.');
  return r.value[0].msdyn_proactive_engagement_configid;
}

async function createDelivery(contactId, payload) {
  const configId = await findProactiveConfig();
  // Windows + InputAttributes are stringly-typed on the action — JSON-stringify them
  const windows = JSON.stringify([{
    StartTime: payload.windowStartIso,
    EndTime: payload.windowEndIso,
    TimeZone: payload.timeZone || 'UTC',
  }]);
  const inputAttributes = JSON.stringify({
    Topic: payload.topic,
    Notes: payload.notes || '',
    Locale: payload.locale || 'en',
    ConsentTimestampUtc: payload.consentTimestampUtc,
  });
  const body = {
    ProactiveEngagementConfigId: configId,
    ContactId: contactId,
    Windows: windows,
    InputAttributes: inputAttributes,
  };
  const r = await dv('POST', 'CCaaS_CreateProactiveVoiceDelivery', body);
  return r && r.DeliveryId;
}

// ---------- HTTP routes ----------
export const bookingRouter = express.Router();
bookingRouter.use(express.json({ limit: '32kb' }));

bookingRouter.use((req, res, next) => {
  if (ALLOWED_ORIGIN) {
    res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  }
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

bookingRouter.post('/book', async (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0].trim() || req.socket.remoteAddress || 'unknown';
  if (!rateLimit(ip)) return res.status(429).json({ error: 'Too many requests' });

  const p = req.body || {};
  // Honeypot (if your HTML adds a hidden field "website", bots fill it, humans don't)
  if (p.website) return res.status(204).end();

  // Minimal server-side validation — DO NOT TRUST the client
  if (!p.firstName || !p.lastName) return res.status(400).json({ error: 'name required' });
  if (!p.email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(p.email)) return res.status(400).json({ error: 'valid email required' });
  if (!p.phoneE164 || !/^\+?[0-9]{6,16}$/.test(p.phoneE164)) return res.status(400).json({ error: 'valid phone required' });
  if (!p.consent) return res.status(400).json({ error: 'consent required' });
  if (!p.windowStartIso || !p.windowEndIso) return res.status(400).json({ error: 'time window required' });

  try {
    const contactId = await resolveContact(p);
    const deliveryId = await createDelivery(contactId, p);
    console.log(`[book] ok contact=${contactId} delivery=${deliveryId} email=${p.email}`);
    res.json({ ok: true, deliveryId });
  } catch (e) {
    console.error('[book] FAIL', e.message);
    res.status(502).json({ error: 'Booking failed. Try again in a moment.' });
  }
});

// Stand-alone runner (skip if you import the router into your own app)
if (import.meta.url === `file://${process.argv[1]}`) {
  const app = express();
  app.use('/api', bookingRouter);
  app.listen(PORT, () => console.log(`Bridge listening on :${PORT}/api/book`));
}
