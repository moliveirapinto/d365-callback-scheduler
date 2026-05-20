# Node.js bridge

For websites running on Node (Express, Next.js, Nuxt, Fastify, plain `http`).

## Standalone server (simplest)

```bash
cd FOR\ REAL\ IMPLEMENTATIONS/server/nodejs
cp .env.example .env          # then edit .env with your values
npm install
node --env-file=.env server.js
```

You now have:
```
http://localhost:3000/api/book
```

Put the bridge behind your existing reverse proxy (nginx, Caddy, IIS, your hosting provider's edge) so it's reachable at `https://your-site.com/api/book`.

## Embed in an existing Express app

```js
import { bookingRouter } from './path/to/server.js';
import express from 'express';
const app = express();
app.use('/api', bookingRouter);   // POST /api/book
```

## Embed in a Next.js app (Pages Router)

Create `pages/api/book.js`:

```js
import { bookingRouter } from '../../path/to/server.js';
import { createServer } from 'http';
// Or use the router pattern of your framework. For Next.js App Router,
// translate the handler into a Route Handler (app/api/book/route.js).
```

For Next.js App Router, the cleanest port is to copy the `resolveContact` / `createDelivery` / `getToken` functions into a `lib/dataverse.js` and call them from `app/api/book/route.js`. ~30 lines.

## Pointing the HTML at this bridge

Open any template from `../../templates/` in a browser with `?api=` set:

```
https://your-site.com/book-a-call.html?api=https://your-site.com/api/book
```

Or hard-code by editing the HTML once (find `flowTriggerUrl` near the top of the `<script>` block and set it to your URL — see HOW-IT-WORKS.md).

## Hosting

This file runs anywhere Node 18+ runs:
- Your existing VPS / dedicated server
- Whatever your website is already deployed on (Vercel, Netlify, Render, Fly, Railway, your own Kubernetes, IIS via iisnode, ...)
- A `systemd` service on a bare Linux box

The bridge is stateless — run as many copies as you like behind a load balancer. Token cache will simply repopulate per instance.
