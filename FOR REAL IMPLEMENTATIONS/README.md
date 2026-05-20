# For Real Implementations

> ⚠️ This folder is for **customers who want to publish the booking page on their own public website** so their visitors can book a callback that lands directly in their own Dataverse / D365 Contact Center.
>
> The rest of this repository (the managed solution, the HTML web resources living inside D365, the admin page) **remains the supported install path for using the templates inside D365**. Nothing in this folder replaces or changes any of that. If you only want to use the booking page inside your D365 model-driven app, **stop here and go back to the main README at the repo root**.

---

## What's in this folder

```
FOR REAL IMPLEMENTATIONS/
├── README.md                  ← you are here
├── SETUP-DATAVERSE.md         ← ONE-TIME: create an Entra app + Application User in your tenant
├── HOW-IT-WORKS.md            ← the architecture, plain English, in one page
├── templates/                 ← exact copies of callback1.html ... callback6.html
└── server/                    ← tiny "bridge" code in 4 flavours. Pick ONE.
    ├── nodejs/                ← if your website runs on Node (Express, Next.js, Nuxt, ...)
    ├── php/                   ← if your website runs on PHP (WordPress, Drupal, plain cPanel, ...)
    ├── dotnet/                ← if your website runs on ASP.NET / .NET 8+
    └── python/                ← if your website runs on Flask, FastAPI, Django, ...
```

---

## Why a "bridge" is needed (read this once, then stop worrying about it)

Dataverse **does not accept anonymous writes**. If a random visitor on your website could POST straight to Dataverse from JavaScript, anyone could spam your CRM with junk records. That's a Microsoft restriction shared by every CRM on the market — it's not specific to this project.

So when a visitor clicks **Schedule my callback** on your public page, the booking has to go through a tiny server-side endpoint **on your own website** that holds the Dataverse credential safely and forwards the validated payload. That endpoint is what we call the "bridge."

You already have a server — that's what your website runs on. The bridge is **30–40 lines of code** in whatever language your site is already written in. We provide it as a copy-paste snippet. No new server, no new hosting, no new vendor, no new licence.

---

## The 4-step install (high level)

1. **One-time, in your Microsoft tenant** — follow [SETUP-DATAVERSE.md](./SETUP-DATAVERSE.md) to create an Entra app registration and a Dataverse Application User. You get 4 values out of it: `DV_ORG_URL`, `AAD_TENANT_ID`, `AAD_CLIENT_ID`, `AAD_CLIENT_SECRET`. **Takes about 5 minutes.**

2. **Pick the language your website uses** and open the matching folder in [`server/`](./server/). Each folder has its own README with copy-paste instructions tailored to that stack.

3. **Drop the bridge endpoint** into your existing site. After this step you'll have a URL like `https://your-website.com/api/book` (or `/wp-json/callback/v1/book`, or whatever your stack uses).

4. **Publish the HTML** — copy any file from [`templates/`](./templates/) (e.g. `callback1.html`) onto your site, then open it with `?api=` pointing at the URL from step 3. Example:
   ```
   https://your-website.com/book-a-call.html?api=https://your-website.com/api/book
   ```
   Or hard-code the URL by editing one line in the HTML (see the snippet README for which line).

That's the entire install. **No Azure subscription required. No extra Microsoft product required. No third-party SaaS.** Just an Entra app reg in the tenant you already have, and one endpoint on the website you already run.

---

## What ends up in your Dataverse

Each public booking creates:

| Record | Where | Why |
|---|---|---|
| **Contact** (or matched existing one by email/phone) | `contacts` table | So the callback has a customer attached. |
| **Proactive Voice Delivery** | `msdyn_proactive_delivery` table | This is what the Customer Service / Contact Center engine reads to dispatch the call to an agent during the chosen time window. |

These are the **exact same records** the in-D365 page creates today. Same tables, same fields, same downstream automation. The bridge is just a thin, secure entry point for the public web.

---

## What this folder does *not* do

- ❌ Does not change anything in the main repository — the managed solution, the embedded admin page, the in-D365 booking experience all keep working as they do today.
- ❌ Does not require you to host the bridge anywhere new — it runs on the same server as your existing website.
- ❌ Does not require Power Pages, Power Automate Premium, an Azure subscription, or any additional Microsoft licence beyond the D365 Customer Service / Contact Center licence you're already using.
- ❌ Does not store any data outside your tenant. The bridge is a pass-through; bookings go straight to your Dataverse and only your Dataverse.

---

## Security checklist before going live

The bridge sits on the public internet, so treat it like any other public form on your site:

- [ ] Bridge runs over **HTTPS** (your hosting provider handles this — Let's Encrypt, Cloudflare, etc.).
- [ ] The Dataverse client secret is stored as a **server-side environment variable**, never committed to git, never present in HTML.
- [ ] The bridge enforces **rate limiting** (the snippets include a simple in-memory limiter — replace with Redis / your hosting platform's limiter for high-traffic sites).
- [ ] The bridge validates the **honeypot field** and rejects bots (already wired in the snippets).
- [ ] Consider adding **CAPTCHA** (Cloudflare Turnstile is free; hCaptcha and reCAPTCHA work too). Each snippet README shows the 3-line addition.
- [ ] The Entra app reg has the **minimum privilege** Dataverse security role (`Callback Public Booking` — see SETUP-DATAVERSE.md for the role definition). It should be able to read/write contacts and create proactive deliveries, **nothing else**.
- [ ] **Rotate the client secret** every 6–12 months. Set a calendar reminder.

---

## Support

This folder is community-supported. Open a GitHub issue on the main repo if you run into problems, and include:
- Which snippet you used (Node / PHP / .NET / Python)
- The HTTP status code returned by the bridge (open the browser DevTools → Network tab → click the failed `/api/book` request)
- The bridge's server log line for that request (the snippets log every request to stdout by default)

Do **not** post your client secret in an issue. Ever.
