# Callback Scheduler — D365 Contact Center

A self-service callback scheduling page for Dynamics 365 Contact Center proactive outbound voice. Customers (or agents) pick a time window; the page calls `CCaaS_CreateProactiveVoiceDelivery` and the engagement service places the call.

This repo ships as a **Dataverse solution**: nothing is hardcoded for any specific tenant, environment, publisher, contact, or workstream. Import into any environment, point the env vars at your config, and it works.

## What's in the solution

| Component | Type | Purpose |
|---|---|---|
| `cbk_callback/app.html` | Web resource (HTML) | The customer-/agent-facing scheduling page |
| `cbk_callback/setup.html` | Web resource (HTML) | One-click admin setup: discovers proactive engagement configs in your env and writes the env vars |
| `cbk_ProactiveEngagementConfigId` | Env var (String) | GUID of the Proactive Engagement Configuration to use. Blank = auto-discover the first one. |
| `cbk_HourStart` | Env var (Number, default `9`) | First bookable hour (24h, local time) |
| `cbk_HourEnd` | Env var (Number, default `18`) | Last bookable hour |
| `cbk_SlotMinutes` | Env var (Number, default `30`) | Length of each window |
| `cbk_DaysAhead` | Env var (Number, default `14`) | How far in advance customers may book |
| `cbk_FlowTriggerUrl` | Env var (String, optional) | HTTP-trigger URL of a Power Automate flow for **customer-mode** (anonymous, outside D365) |

## Two runtime modes

The page detects its environment at startup:

- **Agent mode** — opened inside a model-driven app. Uses `parent.Xrm.WebApi` for everything: env-var lookup, contact resolve/create, action invocation, and (via in-page polling) auto-binding the contact onto the resulting outbound conversation. No backend, no proxy, no token handling.
- **Customer mode** — opened anonymously (e.g. embedded on a public site). POSTs the booking payload to `cbk_FlowTriggerUrl`. The flow is responsible for calling the action and binding the customer.

## Install (any tenant)

### Option A — Deploy from source (recommended for dev / first install)

Requires PowerShell 5.1+ and an active `az login` against the target tenant.

```powershell
cd solution
.\deploy.ps1 -EnvUrl https://YOUR-ORG.crm.dynamics.com -ExportZip
```

The script is **idempotent**:
1. Creates publisher `cbk` if missing
2. Creates solution `CallbackScheduler` if missing
3. Creates the 6 env vars (or leaves them alone)
4. Uploads / updates both web resources
5. Adds every component to the solution
6. `PublishAllXml`
7. Exports a managed `.zip` to `solution/dist/` (when `-ExportZip` is passed)

### Option B — Import the managed zip

Once produced by Option A, the `.zip` can be imported into any other environment via `make.powerapps.com → Solutions → Import` or `pac solution import --path ...`. After import:

1. Open the **Setup page**:  
   `https://YOUR-ORG.crm.dynamics.com/main.aspx?pagetype=webresource&webresourceName=cbk_callback/setup.html`
2. Pick a Proactive Engagement Configuration from the dropdown, click **Save**.
3. (Optional) tweak `cbk_HourStart` / `cbk_HourEnd` / `cbk_SlotMinutes` / `cbk_DaysAhead` directly in the solution.

### Open the scheduler

`https://YOUR-ORG.crm.dynamics.com/main.aspx?pagetype=webresource&webresourceName=cbk_callback/app.html`

Embed it anywhere in your model-driven app (sitemap subarea, dashboard iframe, session template, etc.).

## Architecture notes

- **Customer auto-bind**: the proactive engagement service writes `msdyn_contact_id` onto the `msdyn_proactive_delivery` row, but does NOT propagate it to `msdyn_ocliveworkitem._msdyn_customer_value` until the call physically connects with an unambiguous caller-ID match. Agent-mode bypasses that by polling matching conversations for ~15 minutes after submit and PATCHing the customer lookup directly.
- **Phone-first contact resolution**: the page filters `mobilephone` and `telephone1` on the exact E.164 input. If multiple candidates score equally, the most recently modified wins.
- **Idempotency**: an in-page guard prevents double-firing the action if the user double-clicks the submit button.
- **No CSP issues**: the page only talks to the parent Xrm context (same-origin) — no external network calls in agent mode.

## Dev mode (local proxy)

The original local-development setup is preserved at the repo root:

- `index.html` — same UI but POSTs to a local proxy
- `proxy.ps1` — `[System.Net.HttpListener]` on port 7071 that bridges browser ⇄ Dataverse using `az` for tokens

Use this when iterating on the UI without redeploying the web resource. Run `proxy.ps1`, open `index.html` in a browser. The proxy is **not** part of the solution and is not needed in production.

## Files

```
.
├── index.html             # dev-mode UI (talks to local proxy)
├── proxy.ps1              # dev-mode local HTTP-to-Dataverse bridge
├── README.md              # (you are here)
└── solution/
    ├── deploy.ps1         # idempotent any-tenant deployer + zip exporter
    ├── dist/              # output: CallbackScheduler_managed_X.Y.Z.zip
    └── src/
        └── WebResources/
            └── cbk_callback/
                ├── app.html
                ├── app.html.data.xml
                ├── setup.html
                └── setup.html.data.xml
```

## License

MIT (or your choice — adjust before distributing).
