# SETUP-DATAVERSE.md — one-time prep in your Microsoft tenant

You only do this **once per Dataverse environment**. After this, every snippet in `server/` just reads the four values you produce here.

You'll need:
- A user account with **Global Administrator** (or at least **Application Administrator** + **Privileged Role Administrator**) in your Entra tenant.
- A user account with **System Administrator** role in the target Dataverse environment.
- About **5 minutes**.

---

## Step 1 — Find your Dataverse URL

1. Go to [`https://admin.powerplatform.microsoft.com`](https://admin.powerplatform.microsoft.com).
2. Click **Environments** in the left nav.
3. Pick the environment where Contact Center / Customer Service is installed.
4. Copy the **Environment URL** — looks like `https://yourorg.crm.dynamics.com` (the region suffix may differ: `crm4`, `crm.dynamics.com`, etc.).

> **Save this as `DV_ORG_URL`.**

---

## Step 2 — Create an Entra App Registration

1. Go to [`https://entra.microsoft.com`](https://entra.microsoft.com) → **Applications** → **App registrations** → **+ New registration**.
2. **Name**: `Callback Scheduler — Public Web Bridge`.
3. **Supported account types**: *Accounts in this organizational directory only (Single tenant)*.
4. **Redirect URI**: leave empty.
5. Click **Register**.

You land on the new app's Overview page. Copy:
- **Application (client) ID** → save as `AAD_CLIENT_ID`.
- **Directory (tenant) ID** → save as `AAD_TENANT_ID`.

---

## Step 3 — Create a client secret

1. Still on the app's page → **Certificates & secrets** → **+ New client secret**.
2. **Description**: `Callback bridge — rotate yearly`.
3. **Expires**: 12 months (set a calendar reminder to rotate before this date).
4. Click **Add**.
5. **Copy the `Value` column immediately.** You will not be able to see it again.

> **Save this as `AAD_CLIENT_SECRET`.** Treat it like a password — never commit to git, never paste in chat or email.

---

## Step 4 — Grant the app access to Dataverse

The app reg by itself can't talk to Dataverse yet — it needs a corresponding **Application User** inside the Dataverse environment, mapped to a security role.

### 4a — Create the Application User

1. Open [`https://admin.powerplatform.microsoft.com`](https://admin.powerplatform.microsoft.com) → **Environments** → click your environment.
2. Click **Settings** (top bar) → **Users + permissions** → **Application users**.
3. Click **+ New app user**.
4. **App**: click *+ Add an app* and search for `Callback Scheduler — Public Web Bridge` → **Add**.
5. **Business unit**: pick the root business unit (usually the same name as your org).
6. **Security roles**: see Step 4b below. For the quickest start, assign the built-in **Customer Service Representative** role *temporarily* (you'll narrow it in 4b).
7. Click **Create**.

### 4b — Tighten the security role (recommended)

The built-in role grants more than the bridge needs. Create a least-privilege custom role:

1. In the same environment → **Settings** → **Users + permissions** → **Security roles** → **+ New role**.
2. **Role name**: `Callback Public Booking`.
3. On the tabs, grant only the following (everything else stays at *None*):

| Table | Read | Create | Write | Append | Append To |
|---|---|---|---|---|---|
| Contact | Organization | Organization | Organization | Organization | Organization |
| Proactive Voice Delivery (`msdyn_proactive_delivery`) | Organization | Organization | – | Organization | Organization |
| Proactive Engagement Configuration (`msdyn_proactive_engagement_config`) | Organization | – | – | – | – |
| OmniChannel Live Work Item (`msdyn_ocliveworkitem`) | Organization | – | Organization | – | – |

4. **Save and close**.
5. Go back to **Application users**, open your bridge user, **Manage roles**, uncheck Customer Service Representative, check `Callback Public Booking`, **Save**.

---

## Step 5 — Note your Proactive Engagement Configuration ID

The booking action needs to know which Proactive Engagement Configuration to attach the call to. You only have to look this up once:

1. Inside the D365 model-driven **Customer Service Admin Center** or **Contact Center Admin Center**, go to **Customer support** → **Proactive engagement** (or wherever your environment exposes it).
2. Open the configuration row you want public bookings to attach to.
3. Copy the GUID from the URL — looks like `id=00000000-0000-0000-0000-000000000000`.

> **Save this as `DV_PROACTIVE_CONFIG_ID`.**

If you don't see Proactive Engagement in your env, you can either:
- Enable it via the Contact Center admin center (it's a built-in capability of Customer Service Voice channel), or
- Skip this value — the bridge will auto-discover the first available config (slightly slower, one extra round-trip per request).

---

## Step 6 — Summary: the 5 values you now have

```
DV_ORG_URL                = https://yourorg.crm.dynamics.com
AAD_TENANT_ID             = 00000000-0000-0000-0000-000000000000
AAD_CLIENT_ID             = 00000000-0000-0000-0000-000000000000
AAD_CLIENT_SECRET         = <the value from Step 3>
DV_PROACTIVE_CONFIG_ID    = 00000000-0000-0000-0000-000000000000   (optional)
```

Put these into the `.env` (or equivalent config file) for whichever bridge snippet you picked from [`server/`](./server/). Each snippet's README shows exactly where.

---

## Troubleshooting

**`401 Unauthorized` from Dataverse**
→ The Application User was created but has no security role, or the secret expired. Re-check Step 4 + Step 3.

**`403 Forbidden` from Dataverse**
→ The role lacks privileges on the table the bridge is trying to touch. Open the failed request log line (the snippets log the failed table), and add that table to your `Callback Public Booking` role.

**`AADSTS7000215: Invalid client secret`**
→ The secret value was truncated or you pasted the secret *ID* instead of the *value*. Generate a new secret in Step 3 and replace.

**`The user is not a member of the organization`**
→ Step 4a never ran or used the wrong app. Confirm under **Application users** that an entry exists whose **Application ID** matches your `AAD_CLIENT_ID`.

**No proactive delivery shows up after a booking**
→ Deliveries are written **asynchronously** by Dataverse after the action returns. Give it 10–30 seconds and refresh the dashboard. If still nothing after a minute, check the bridge log for the `DeliveryId` the action returned, then look up that exact id in `msdyn_proactive_delivery`.
