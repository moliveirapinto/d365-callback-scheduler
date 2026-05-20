# .NET bridge

For sites built on ASP.NET Core / .NET 8+.

## Standalone

```powershell
cd 'FOR REAL IMPLEMENTATIONS\server\dotnet'
# Set env vars (PowerShell)
$env:DV_ORG_URL            = "https://yourorg.crm.dynamics.com"
$env:AAD_TENANT_ID         = "..."
$env:AAD_CLIENT_ID         = "..."
$env:AAD_CLIENT_SECRET     = "..."
$env:DV_PROACTIVE_CONFIG_ID = ""
$env:ALLOWED_ORIGIN        = "https://www.your-site.com"
dotnet run
```

Endpoint: `http://localhost:5000/api/book` (port depends on launchSettings).

## Embed into an existing ASP.NET app

Copy the `TokenProvider` class + the `app.MapPost("/api/book", ...)` block
into your existing `Program.cs`. The booking endpoint is otherwise
self-contained — no DI registration beyond `IHttpClientFactory` and the
provided singleton.

## Hosting

- IIS / IIS Express on Windows
- Linux + `dotnet publish` + systemd unit
- Whatever your existing ASP.NET site runs on

Set the 4 env vars wherever your platform stores config (IIS application
settings, systemd `Environment=` lines, Azure App Service config, etc.).
