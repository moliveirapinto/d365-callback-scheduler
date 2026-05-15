# Callback Scheduler for Dynamics 365 Contact Center

A customer-facing self-service callback booking page for Microsoft Dynamics 365 Contact Center (Omnichannel / CCaaS). Customers pick a date and time window, fill in their details, and the system schedules a proactive outbound call. Agents see the callback topic and notes directly on the Active Conversation form when the call connects.

---

## Table of Contents

1. [What It Does](#what-it-does)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Accessing the Booking Page](#accessing-the-booking-page)
5. [Creating Workstream Context Variables](#creating-workstream-context-variables)
6. [Adding Fields to the Active Conversation Form](#adding-fields-to-the-active-conversation-form)
7. [Topic Options](#topic-options)
8. [Uninstalling](#uninstalling)

---

## What It Does

The solution deploys a polished booking page as an HTML web resource inside Dynamics 365. Customers can:

- Select a day and time window from a live availability calendar
- Specify what their call is about (loaded dynamically from your topic choices)
- Leave optional notes for the agent

Once submitted, the system:

1. Resolves or creates the customer Contact record in Dataverse
2. Calls `CCaaS_CreateProactiveVoiceDelivery` to schedule the outbound callback
3. A Power Automate flow writes the booking context (topic, notes) to the Conversation record so agents see it immediately when the call connects

**What agents see** when a callback conversation opens:

| Label on Form | Column | Type |
|---|---|---|
| What is it about? | `cbk_whatsitabout_` | Choice |
| Anything we should know? | `maulabs_anythingweshouldknow` | Text |

---

## Prerequisites

Before installing, confirm you have:

- A Dynamics 365 Contact Center (or Customer Service workspace with voice / CCaaS) environment
- **System Administrator** role in the target environment
- A configured **Proactive Engagement Configuration** (voice channel already set up in Omnichannel / CCaaS)
- Power Automate (flows run from the Default environment - no additional license required for D365 customers)

---

## Installation

### Step 1 - Download the solution

1. Go to the [**Releases page**](../../releases/latest) of this repository
2. Download `CallbackScheduler_x_x_x_x_managed.zip` from the **Assets** section

### Step 2 - Import into Dynamics 365

1. Go to [make.powerapps.com](https://make.powerapps.com) and **select your D365 environment** from the top-right environment picker
2. In the left navigation, click **Solutions**
3. Click **Import solution** (top toolbar)
4. Click **Browse**, select the `.zip` you downloaded, then click **Next**
5. Review the solution details and click **Import**
6. Wait for the import to complete (may take 1-3 minutes). A green checkmark confirms success.
7. Click **Publish all customizations** to activate everything

---

## Accessing the Booking Page

The booking page is deployed as the HTML web resource `cbk_cbk/callback_app.html`. It is designed to run inside the **Dynamics 365 Customer Service Workspace**, embedded as an application tab on the voice session.

### For testing - direct URL

Navigate to:

```
https://<your-org>.crm.dynamics.com/WebResources/cbk_cbk_callback_app.html
```

Replace `<your-org>` with your org subdomain (e.g. `contoso`).

> When opened directly in the browser while logged in to Dynamics 365, the page uses your session cookies to authenticate. This is the quickest way to verify the setup.

### Embedding in a voice session (recommended)

To surface the booking page automatically when a voice callback session opens:

1. In **Customer Service Admin Center > Workstreams**, open your voice workstream
2. Navigate to **Session templates** and open (or create) the session template used for callbacks
3. Under **Application tabs**, click **Add** and create a new Application Tab Template:
   - **Name:** e.g. `Callback Booking`
   - **Page type:** Web Resource
   - **Web resource name:** `cbk_cbk/callback_app`
4. Link this tab template to the session template
5. Save and publish

The booking tab will appear automatically in the tab strip whenever an agent handles a callback session.

---

## Creating Workstream Context Variables

The booking page submits the customer's topic and notes as context attributes inside `CCaaS_CreateProactiveVoiceDelivery`. The included Power Automate flow **"CBK - Populate Conversation columns from context"** reads those attributes and writes them to the Conversation record.

For this mapping to work, the matching context variables must exist in the workstream.

### Steps

1. In **Customer Service Admin Center > Workstreams**, open the workstream used for voice callbacks
2. Scroll to the **Context variables** section and click **Add**
3. Create the following two variables exactly as shown:

| Context Variable Name | Type | Description |
|---|---|---|
| `cbk_whatsitabout_` | Number | The option-set integer value of the callback topic |
| `anything_we_should_know` | Text | Free-text notes the customer entered on the booking page |

4. Click **Save**

> **Important:** The variable names must match exactly, including the trailing underscore in `cbk_whatsitabout_`. Dynamics 365 Omnichannel filters out context keys matching certain reserved keywords - the trailing underscore works around this restriction.

---

## Adding Fields to the Active Conversation Form

After installation, add the callback fields to the **Active Conversation** form so agents can see the customer's topic and notes when the call connects.

### Steps

1. Go to [make.powerapps.com](https://make.powerapps.com) > **Solutions** > open the **Default Solution**
2. Navigate to **Tables > Conversation (`msdyn_ocliveworkitem`) > Forms**
3. Open the **Active Conversation** form (type: **Main**)
4. In the form editor, find a suitable section (or create a new one, e.g. **Callback request**)
5. In the **Table columns** panel on the left, search for and drag these columns onto the form:
   - **What is it about?** (`cbk_whatsitabout_`) - callback topic as a dropdown
   - **Anything we should know?** (`maulabs_anythingweshouldknow`) - customer free-text notes
6. Click **Save** then **Publish**

Example of what agents will see:

| Label | Value |
|---|---|
| What is it about? | Technical support |
| Anything we should know? | My order has not arrived yet |

---

## Topic Options

The "What's it about?" dropdown on the booking page is populated dynamically from the `maulabs_whatsitabout` global Choice (option set). To add, rename, or reorder topics:

1. In [make.powerapps.com](https://make.powerapps.com) > **Solutions**, open **Callback Scheduler for D365 Contact Center**
2. Navigate to **Choices** in the left panel
3. Open **maulabs_whatsitabout**
4. Add or rename options as needed
5. Click **Save** and **Publish**

The booking page reflects changes immediately - it reads option labels live from the Dataverse metadata API.

---

## Uninstalling

1. **Remove the callback fields from the Active Conversation form** (reverse of the steps above) and publish the form
2. In **make.powerapps.com > Solutions**, select **Callback Scheduler for D365 Contact Center**
3. Click **Delete** and confirm

This removes all solution components: web resource, Power Automate flow, columns, and environment variable definitions.

---

## Architecture Overview

```
Customer (booking page in browser or D365 app tab)
        |
        |  CCaaS_CreateProactiveVoiceDelivery (Dataverse action)
        v
D365 CCaaS schedules outbound call within the booked window
        |
        |  call connects, Conversation record is created
        v
Power Automate flow "CBK - Populate Conversation columns from context"
        |
        |  writes topic + notes from workstream context variables
        v
Active Conversation form -> agent sees "What is it about?" + notes
```

---

## Support

For questions or issues, open a GitHub Issue on this repository.