# Python bridge

For sites built on Flask, FastAPI, Django, or anything WSGI/ASGI.

## Install

```bash
cd FOR\ REAL\ IMPLEMENTATIONS/server/python
python -m venv .venv && source .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env       # then edit .env
set -a && . ./.env && set +a    # or use python-dotenv / your hosting's env panel
python app.py
```

Endpoint: `http://localhost:3000/api/book`. Put it behind your existing reverse
proxy / hosting so it's reachable as `https://your-site.com/api/book`.

## Production

Use `gunicorn` or `uvicorn` (with `flask[async]` upgraded to FastAPI) — `app.run`
is dev-only.

```bash
pip install gunicorn
gunicorn -w 2 -b 0.0.0.0:3000 app:app
```

## Embed into Django

Translate the three core functions (`get_token`, `dv`, `resolve_contact`,
`find_config`) into a `services/dataverse.py` module, then call them from a
Django view at `/api/book/`. ~30 lines.

## Embed into FastAPI

```python
from fastapi import FastAPI, Request, HTTPException
from app import resolve_contact, find_config, dv, rate_ok  # same functions
fastapi_app = FastAPI()
@fastapi_app.post("/api/book")
async def book(request: Request): ...
```
