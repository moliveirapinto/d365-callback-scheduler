// Program.cs — Callback Scheduler public booking bridge (.NET 8 minimal API)
//
// Build:  dotnet new web -n CallbackBridge   then replace Program.cs with this file
// Run:    dotnet run
//
// Config — via environment variables OR appsettings.json (both work):
//   DV_ORG_URL              https://yourorg.crm.dynamics.com
//   AAD_TENANT_ID           ...
//   AAD_CLIENT_ID           ...
//   AAD_CLIENT_SECRET       ...
//   DV_PROACTIVE_CONFIG_ID  (optional)
//   ALLOWED_ORIGIN          (optional)

using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<TokenProvider>();
builder.Services.AddHttpClient("dv");
builder.Services.AddHttpClient("login");
var app = builder.Build();

var dvOrg     = Get("DV_ORG_URL").TrimEnd('/');
var tenantId  = Get("AAD_TENANT_ID");
var clientId  = Get("AAD_CLIENT_ID");
var secret    = Get("AAD_CLIENT_SECRET");
var configId  = Environment.GetEnvironmentVariable("DV_PROACTIVE_CONFIG_ID");
var allowedOrigin = Environment.GetEnvironmentVariable("ALLOWED_ORIGIN");

string Get(string k) => Environment.GetEnvironmentVariable(k)
    ?? throw new InvalidOperationException($"Missing env var {k}");

var hits = new ConcurrentDictionary<string, Queue<DateTime>>();
bool RateOk(string ip, int max = 5)
{
    var q = hits.GetOrAdd(ip, _ => new Queue<DateTime>());
    lock (q)
    {
        var now = DateTime.UtcNow;
        while (q.Count > 0 && (now - q.Peek()).TotalSeconds > 60) q.Dequeue();
        q.Enqueue(now);
        return q.Count <= max;
    }
}

app.Use(async (ctx, next) =>
{
    if (allowedOrigin is not null)
    {
        ctx.Response.Headers["Access-Control-Allow-Origin"] = allowedOrigin;
        ctx.Response.Headers["Vary"] = "Origin";
        ctx.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type";
    }
    if (ctx.Request.Method == "OPTIONS") { ctx.Response.StatusCode = 204; return; }
    await next();
});

var emailRe = new Regex(@"^[^\s@]+@[^\s@]+\.[^\s@]+$", RegexOptions.Compiled);
var phoneRe = new Regex(@"^\+?[0-9]{6,16}$", RegexOptions.Compiled);

app.MapPost("/api/book", async (HttpContext ctx, IHttpClientFactory hcf, TokenProvider tp) =>
{
    var ip = (ctx.Request.Headers["X-Forwarded-For"].ToString().Split(',').FirstOrDefault()
              ?? ctx.Connection.RemoteIpAddress?.ToString() ?? "na").Trim();
    if (!RateOk(ip)) return Results.Json(new { error = "Too many requests" }, statusCode: 429);

    BookingPayload? p;
    try { p = await ctx.Request.ReadFromJsonAsync<BookingPayload>(); }
    catch { return Results.Json(new { error = "invalid JSON" }, statusCode: 400); }
    if (p is null) return Results.Json(new { error = "invalid JSON" }, statusCode: 400);

    if (!string.IsNullOrEmpty(p.Website)) return Results.NoContent(); // honeypot

    if (string.IsNullOrWhiteSpace(p.FirstName) || string.IsNullOrWhiteSpace(p.LastName))
        return Results.Json(new { error = "name required" }, statusCode: 400);
    if (string.IsNullOrWhiteSpace(p.Email) || !emailRe.IsMatch(p.Email))
        return Results.Json(new { error = "valid email required" }, statusCode: 400);
    if (string.IsNullOrWhiteSpace(p.PhoneE164) || !phoneRe.IsMatch(p.PhoneE164))
        return Results.Json(new { error = "valid phone required" }, statusCode: 400);
    if (!p.Consent) return Results.Json(new { error = "consent required" }, statusCode: 400);
    if (string.IsNullOrWhiteSpace(p.WindowStartIso) || string.IsNullOrWhiteSpace(p.WindowEndIso))
        return Results.Json(new { error = "time window required" }, statusCode: 400);

    var dv = hcf.CreateClient("dv");

    async Task<JsonElement?> DV(HttpMethod method, string path, object? body = null)
    {
        var token = await tp.GetAsync(hcf, tenantId, clientId, secret, dvOrg);
        using var req = new HttpRequestMessage(method, $"{dvOrg}/api/data/v9.2/{path}");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        req.Headers.Add("OData-MaxVersion", "4.0");
        req.Headers.Add("OData-Version", "4.0");
        req.Headers.Add("Prefer", "return=representation");
        if (body is not null) req.Content = JsonContent.Create(body);
        using var resp = await dv.SendAsync(req);
        var text = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode) throw new Exception($"Dataverse {method} {path} -> {(int)resp.StatusCode}: {text}");
        return string.IsNullOrEmpty(text) ? null : JsonDocument.Parse(text).RootElement.Clone();
    }

    try
    {
        // resolve-or-create contact
        string? contactId = null;
        var r1 = await DV(HttpMethod.Get, $"contacts?$filter=emailaddress1 eq '{p.Email!.Replace("'", "''")}'&$select=contactid&$top=1");
        if (r1?.GetProperty("value") is { ValueKind: JsonValueKind.Array } arr1 && arr1.GetArrayLength() > 0)
            contactId = arr1[0].GetProperty("contactid").GetString();
        if (contactId is null && !string.IsNullOrEmpty(p.PhoneE164))
        {
            var f = Uri.EscapeDataString($"mobilephone eq '{p.PhoneE164}'");
            var r2 = await DV(HttpMethod.Get, $"contacts?$filter={f}&$select=contactid&$top=1");
            if (r2?.GetProperty("value") is { ValueKind: JsonValueKind.Array } arr2 && arr2.GetArrayLength() > 0)
                contactId = arr2[0].GetProperty("contactid").GetString();
        }
        if (contactId is null)
        {
            var created = await DV(HttpMethod.Post, "contacts", new
            {
                firstname = p.FirstName,
                lastname = p.LastName,
                emailaddress1 = p.Email,
                mobilephone = p.PhoneE164,
            });
            contactId = created!.Value.GetProperty("contactid").GetString();
        }

        // resolve config
        var cfgId = configId;
        if (string.IsNullOrEmpty(cfgId))
        {
            var r = await DV(HttpMethod.Get, "msdyn_proactive_engagement_configs?$select=msdyn_proactive_engagement_configid&$top=1");
            cfgId = r!.Value.GetProperty("value")[0].GetProperty("msdyn_proactive_engagement_configid").GetString();
        }

        // create delivery
        var windows = JsonSerializer.Serialize(new[] { new {
            StartTime = p.WindowStartIso, EndTime = p.WindowEndIso, TimeZone = p.TimeZone ?? "UTC"
        }});
        var inputAttrs = JsonSerializer.Serialize(new {
            Topic = p.Topic ?? "",
            Notes = p.Notes ?? "",
            Locale = p.Locale ?? "en",
            ConsentTimestampUtc = p.ConsentTimestampUtc ?? DateTime.UtcNow.ToString("o"),
        });
        var resp = await DV(HttpMethod.Post, "CCaaS_CreateProactiveVoiceDelivery", new
        {
            ProactiveEngagementConfigId = cfgId,
            ContactId = contactId,
            Windows = windows,
            InputAttributes = inputAttrs,
        });
        var deliveryId = resp!.Value.GetProperty("DeliveryId").GetString();
        Console.WriteLine($"[book] ok contact={contactId} delivery={deliveryId} email={p.Email}");
        return Results.Ok(new { ok = true, deliveryId });
    }
    catch (Exception e)
    {
        Console.Error.WriteLine($"[book] FAIL {e.Message}");
        return Results.Json(new { error = "Booking failed. Try again in a moment." }, statusCode: 502);
    }
});

app.Run();

record BookingPayload(
    string? FirstName, string? LastName, string? Email, string? PhoneE164,
    string? Topic, string? Notes, bool Consent, string? ConsentTimestampUtc,
    string? Locale, string? TimeZone, string? WindowStartIso, string? WindowEndIso,
    string? Website);

class TokenProvider
{
    string? _val; DateTime _exp;
    readonly SemaphoreSlim _gate = new(1, 1);
    public async Task<string> GetAsync(IHttpClientFactory hcf, string tenant, string client, string secret, string org)
    {
        if (_val is not null && DateTime.UtcNow < _exp) return _val;
        await _gate.WaitAsync();
        try
        {
            if (_val is not null && DateTime.UtcNow < _exp) return _val;
            var http = hcf.CreateClient("login");
            var form = new FormUrlEncodedContent(new Dictionary<string, string> {
                ["client_id"] = client, ["client_secret"] = secret,
                ["grant_type"] = "client_credentials", ["scope"] = $"{org}/.default"
            });
            var r = await http.PostAsync($"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", form);
            var t = await r.Content.ReadAsStringAsync();
            if (!r.IsSuccessStatusCode) throw new Exception($"Token {r.StatusCode}: {t}");
            var j = JsonDocument.Parse(t).RootElement;
            _val = j.GetProperty("access_token").GetString();
            _exp = DateTime.UtcNow.AddSeconds(j.GetProperty("expires_in").GetInt32() - 300);
            return _val!;
        }
        finally { _gate.Release(); }
    }
}
