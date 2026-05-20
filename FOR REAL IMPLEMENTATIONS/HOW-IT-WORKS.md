# HOW-IT-WORKS.md — the bridge architecture, in one page

```
   ┌────────────────────┐    1. Visitor opens
   │ Anonymous visitor  │       https://your-site.com/book-a-call.html?api=/api/book
   │  (their browser)   │
   └─────────┬──────────┘
             │
             │ 2. JavaScript in the page
             │    POST  /api/book
             │    body:  { firstName, lastName, email, phoneE164,
             │             topic, notes, consent, consentTimestampUtc,
             │             locale, timeZone, windowStartIso, windowEndIso }
             ▼
   ┌────────────────────────────────────────┐
   │ Your existing web server               │
   │ (Node / PHP / .NET / Python)           │
   │                                        │
   │  Bridge endpoint  (≈40 lines):         │
   │    • Rate-limit + honeypot check       │
   │    • Acquire Dataverse access token    │
   │      (OAuth2 client_credentials, using │
   │       AAD_CLIENT_ID + AAD_CLIENT_SECRET│
   │       cached in memory for ~55 min)    │
   │    • Resolve-or-create Contact         │
   │    • Call Dataverse action:            │
   │      CCaaS_CreateProactiveVoiceDelivery│
   │    • Return { ok: true, deliveryId }   │
   └─────────┬──────────────────────────────┘
             │
             │ 3. HTTPS to your Dataverse env
             │    Authorization: Bearer <token>
             ▼
   ┌────────────────────────────────────────┐
   │ Your Dataverse environment             │
   │ https://yourorg.crm.dynamics.com       │
   │                                        │
   │  Contacts table         ◄──── upserted │
   │  msdyn_proactive_       ◄──── created  │
   │     delivery table           (async)   │
   │                                        │
   │  Existing automation / agent routing   │
   │  picks up the new delivery and queues  │
   │  the outbound call.                    │
   └────────────────────────────────────────┘
```

## Why this shape

- **The browser never sees the Dataverse secret.** It only sees your bridge URL. The secret lives in the bridge's environment variables, which only your server process can read.
- **The bridge is stateless** beyond a short-lived token cache. You can run multiple instances behind a load balancer with zero coordination.
- **Token caching matters.** Without it, every booking request would do a full OAuth round-trip — adds ~300ms and risks rate-limiting your tenant. The snippets cache the access token in process memory until ~55 minutes after issuance (tokens live 60 min by default).
- **The action `CCaaS_CreateProactiveVoiceDelivery`** is the same one used by the in-D365 booking page. Same downstream behavior, same automation triggers.

## Failure modes you'll encounter

| Symptom | Likely cause | Fix |
|---|---|---|
| 401 from bridge | Bad/expired secret | Rotate in Entra, update env var |
| 403 from bridge | Application User missing security role | Re-check SETUP step 4 |
| 400 with `0x80048d19` | Action payload field sent as array/object instead of JSON string | Snippets handle this — only happens if you modify them |
| 200 from bridge, no record in Dataverse | Async write — wait 10–30 s | Check `msdyn_proactive_delivery` by the returned `DeliveryId` |
| Visitor sees CORS error | Bridge endpoint is on a different origin than the HTML | Either serve both from the same origin or add CORS allowlist in the bridge (snippet shows the 3-line addition) |

## Capacity

- Dataverse Web API quota: **6000 requests per 5 minutes per user** (your Application User is one user). Each booking is roughly 3–4 requests. → ~500 bookings per 5 minutes per environment without hitting limits.
- If you need more, deploy a second Application User with the same role and round-robin between them in the bridge. Or upgrade the request limit via support.

## What the bridge does NOT do

- ❌ Does not send confirmation emails / SMS. Wire that into your Dataverse workflow / Power Automate **after** the delivery is created — same as in-D365 bookings.
- ❌ Does not handle reschedule / cancel from the public side. Out of scope for the public form.
- ❌ Does not validate phone number format beyond E.164 shape. Add a CAPTCHA + a phone-lookup vendor if you receive lots of bot traffic.
