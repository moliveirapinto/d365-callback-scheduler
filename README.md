# Schedule a Callback — D365 Contact Center Proactive Engagement

A modern, responsive single-page customer-facing site that lets visitors pick a date and one-hour window to be called back. On submit, the page POSTs a JSON payload to a Power Automate HTTP-trigger flow that invokes the official Dynamics 365 Contact Center API **`CCaaS_CreateProactiveVoiceDelivery`** to enqueue an outbound voice call.

> No new Dataverse tables required. The API writes the delivery record into the OOB `msdyn_proactive_delivery` table.

Live preview: open `index.html` in a browser (or host the folder on Vercel / Netlify / Azure Static Web Apps / GitHub Pages — it's pure static).

---

## 1. What the page does

- Customer picks a **day** (next 14 days) and a **1-hour window** in their local timezone.
- Customer fills in **first/last name, mobile (with country code), email, topic, optional notes**.
- Customer **must consent** to be called (mandatory per Microsoft docs — your org is responsible for consent).
- On submit the page sends a single JSON `POST` to your Power Automate flow.

The boarding-pass-style summary on the right updates live as the user fills the form. On mobile it stacks under the form and a sticky "Schedule my callback" CTA pins to the bottom.

No frameworks, no build step, no dependencies — one HTML file (`index.html`).

---

## 2. Configure

Open `index.html` and edit the `CONFIG` block near the bottom of the `<script>`:

```js
const CONFIG = {
  apiUrl: "https://prod-XX.westus.logic.azure.com:443/workflows/.../triggers/manual/paths/invoke?...",
  proactiveEngagementConfigId: "cbbac510-3e66-ef11-a671-6045bd03d9d8",
  hourStart: 9,
  hourEnd: 18,
  daysAhead: 14,
  minLeadMinutes: 30
};
```

Or override at runtime via query string (handy for staging vs. prod):
```
https://yoursite.com/?api=https://prod-XX...&cfg=<GUID>
```

If `apiUrl` is empty the page runs in **DEMO mode**: submission is logged to the browser console and the success screen is shown without hitting any backend.

### Where to find the `ProactiveEngagementConfigId`
Power Apps → choose your environment → **Tables** → search **Proactive Engagement Configuration** → open the record you want to use → copy its `Id` (GUID). [Source](https://learn.microsoft.com/dynamics365/contact-center/extend/api/ccaas_createproactivevoicedelivery#request-headers).

---

## 3. The Power Automate flow (the only thing you need to build)

Create an HTTP-trigger Power Automate cloud flow with these steps. The page does the rest.

### Trigger — **When an HTTP request is received**
Sample request body schema — paste this into the trigger to auto-generate the schema:
```json
{
  "firstName": "Ada",
  "lastName": "Lovelace",
  "email": "ada@example.com",
  "phoneE164": "+15550123",
  "countryCode": "+1",
  "phoneLocal": "5550123",
  "topic": "Billing question",
  "notes": "Order #12345",
  "consent": true,
  "consentTimestampUtc": "2026-05-13T15:00:00.000Z",
  "locale": "en-GB",
  "timeZone": "Europe/London",
  "ccaas": {
    "ApiVersion": "1.0",
    "ProactiveEngagementConfigId": "00000000-0000-0000-0000-000000000000",
    "DestinationPhoneNumber": "+15550123",
    "Windows": [{ "Start": "2026-05-14T13:00:00.000Z", "End": "2026-05-14T14:00:00.000Z" }],
    "InputAttributes": {
      "type": "callback",
      "topic": "Billing question",
      "firstName": "Ada",
      "lastName": "Lovelace",
      "notes": "Order #12345",
      "sourceUrl": "https://your-site/"
    }
  }
}
```

### Step 1 — Find or create the Contact (Dataverse connector)
1. **List rows** on `Contacts`, filter:
   `emailaddress1 eq '@{triggerBody()?['email']}' or mobilephone eq '@{triggerBody()?['phoneE164']}'`
2. **Condition**: if `length(outputs('List_rows')?['body/value'])` is `0` → **Add a new row** to `Contacts` with:
   - `firstname` ← `firstName`
   - `lastname`  ← `lastName`
   - `emailaddress1` ← `email`
   - `mobilephone`   ← `phoneE164`
   - else use the first existing record.
3. Set a variable `ContactId` from whichever branch ran.

### Step 2 — Call `CCaaS_CreateProactiveVoiceDelivery`
Use the Dataverse connector action **Perform an unbound action** (or invoke via HTTP with Dataverse — Web API):

- **Action name**: `CCaaS_CreateProactiveVoiceDelivery`
- **Parameters (JSON)**:
```json
{
  "ApiVersion": "1.0",
  "ProactiveEngagementConfigId": "@{triggerBody()?['ccaas']?['ProactiveEngagementConfigId']}",
  "DestinationPhoneNumber":      "@{triggerBody()?['ccaas']?['DestinationPhoneNumber']}",
  "ContactId":                   "@{variables('ContactId')}",
  "Windows":                     "@{triggerBody()?['ccaas']?['Windows']}",
  "InputAttributes":             "@{triggerBody()?['ccaas']?['InputAttributes']}"
}
```
> Some HTTP/Dataverse tooling requires `Windows` as a **string** of escaped JSON rather than a JSON array. If you see an error, wrap it: `"Windows": "@{string(triggerBody()?['ccaas']?['Windows'])}"`. See the "Important" note in [the docs](https://learn.microsoft.com/dynamics365/contact-center/extend/api/ccaas_createproactivevoicedelivery#windows-object).

### Step 3 — Respond 200
Return the `DeliveryId` returned by the action so the page can log it (the page currently doesn't read the body — feel free to extend).

### Optional — Send confirmation email
Use the Office 365 Outlook connector to email `triggerBody()?['email']` a confirmation with the chosen window.

---

## 4. Prerequisites in your D365 environment

From [the official docs](https://learn.microsoft.com/dynamics365/contact-center/administer/configure-proactive-engagement):
1. Dynamics 365 Contact Center licence (or Customer Service with the Contact Center add-on).
2. Voice channel and an outbound calling number provisioned.
3. **Proactive Engagement Configuration** record created (Workstream + Outbound Profile + Dial Mode = `Preview`, `Progressive`, or `Copilot`). Copy its `Id`.
4. The Flow runs as a user with the **Omnichannel agent** or **Omnichannel supervisor** role (required by the API).
5. Consent — your responsibility. The page already enforces a consent checkbox. Maintain do-not-call lists and quiet hours per local regulation.

---

## 5. Where the data ends up

| Artefact | Table | Notes |
|---|---|---|
| Customer record | `contact` | Created/looked up by your Flow |
| Delivery request | `msdyn_proactive_delivery` | Written by the API. Status flows `Pending → InProcess → Complete / Expired / Cancelled / Error` |
| Per-call attributes | `msdyn_proactive_delivery_attribute` | Each `InputAttributes` key/value is stored here for reporting |
| Conversation | `conversation` (Omnichannel) | Linked when the call connects |

Reporting reference: [Use proactive engagement tables for reporting](https://learn.microsoft.com/dynamics365/contact-center/extend/proactive-engagement-tables).

---

## 6. Brand it

Quick edits in `index.html`:

| Element | Where |
|---|---|
| Brand name | `<div class="brand">…Contoso Care</div>` |
| Logo dot colours | CSS vars `--accent` and `--accent-2` |
| Background colours | `body { background: …` |
| Business hours | `CONFIG.hourStart` / `CONFIG.hourEnd` |
| Country dropdown | `<select id="country">` |
| Topic list | `<select id="topic">` |
| Privacy / Terms links | footer `<a>` tags |

---

## 7. Hosting

Pure static — pick whatever you like:
- Drop `index.html` into an **Azure Storage** static website container.
- `vercel deploy --prod` from this folder.
- Push the repo to GitHub and enable **GitHub Pages**.
- Drag the folder into **Netlify**.

No server, no build, no env vars. The only secret (the Power Automate flow URL) is intended to be public — Power Automate HTTP triggers are protected by a SAS in the URL itself; the flow should still validate the request body and apply rate limiting.

---

## 8. References

- [Overview of proactive engagement](https://learn.microsoft.com/dynamics365/contact-center/administer/overview-proactive-engagement)
- [Use `CCaaS_CreateProactiveVoiceDelivery` API](https://learn.microsoft.com/dynamics365/contact-center/extend/api/ccaas_createproactivevoicedelivery)
- [Use proactive engagement tables for reporting](https://learn.microsoft.com/dynamics365/contact-center/extend/proactive-engagement-tables)
- [Configure proactive engagement](https://learn.microsoft.com/dynamics365/contact-center/administer/configure-proactive-engagement)
