# =============================================================================
#  D365 Callback Scheduler — Local Proxy
# =============================================================================
#  The browser cannot call the Dataverse Web API directly (CORS + auth).
#  This script runs a tiny HTTP listener on http://localhost:7071 that:
#    1. Accepts the JSON payload posted by index.html
#    2. Looks up or creates a Contact in Dataverse (by email or phone)
#    3. Invokes the bound action  CCaaS_CreateProactiveVoiceDelivery
#       https://learn.microsoft.com/dynamics365/contact-center/extend/api/ccaas_createproactivevoicedelivery
#    4. Returns the DeliveryId to the page
#
#  Auth: uses your already-signed-in `az` account (must have Omnichannel agent
#        or supervisor role on the org).
#
#  Run:    pwsh -File .\proxy.ps1     (or  powershell -File .\proxy.ps1 )
#  Stop:   Ctrl+C
# =============================================================================

$OrgUrl   = "https://mauriciomaster.crm.dynamics.com"
$ConfigId = "df129bb8-ea61-f011-bec2-00224826cb8a"   # Proactive Engagement Configuration "Outbound"
$Port     = 7071

$ApiBase = "$OrgUrl/api/data/v9.2"

function Get-Token {
  $t = az account get-access-token --resource $OrgUrl --query accessToken -o tsv 2>$null
  if (-not $t) { throw "Could not get an Azure AD token. Run 'az login --tenant 48ac8550-da32-403e-9d2c-d280efe32983' first." }
  return $t
}

function New-Headers {
  $tok = Get-Token
  return @{
    Authorization      = "Bearer $tok"
    Accept             = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    "Content-Type"     = "application/json; charset=utf-8"
    Prefer             = "return=representation"
  }
}

function Resolve-ContactId {
  param([Parameter(Mandatory)]$Body, [Parameter(Mandatory)]$Headers)

  $email = if ($Body.email)     { ([string]$Body.email).Trim() }     else { "" }
  $phone = if ($Body.phoneE164) { ([string]$Body.phoneE164).Trim() } else { "" }

  # Build OData filter. Values are wrapped in single quotes (escape any '),
  # then the WHOLE filter string is URI-escaped so characters like '+' in
  # E.164 phone numbers are not silently turned into spaces by URL parsing.
  $clauses = @()
  if ($email) { $clauses += "emailaddress1 eq '$($email.Replace("'","''"))'" }
  if ($phone) {
    $pq = $phone.Replace("'","''")
    $clauses += "mobilephone eq '$pq'"
    $clauses += "telephone1 eq '$pq'"
  }
  if ($clauses.Count -gt 0) {
    $filter = ($clauses -join " or ")
    $select = "contactid,firstname,lastname,fullname,emailaddress1,mobilephone,telephone1,modifiedon"
    $url = "$ApiBase/contacts?`$select=$select&`$filter=$([Uri]::EscapeDataString($filter))&`$top=25"
    $resp = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get
    $cands = @($resp.value)

    if ($cands.Count -gt 0) {
      $score = {
        param($c)
        $s = 0
        $emailHit = $email -and ($c.emailaddress1 -and $c.emailaddress1.ToLower() -eq $email.ToLower())
        $phoneHit = $phone -and (($c.mobilephone -eq $phone) -or ($c.telephone1 -eq $phone))
        if ($emailHit -and $phoneHit) { $s += 100 }   # perfect match wins
        elseif ($phoneHit)            { $s += 50 }    # phone alone beats email alone for voice callbacks
        elseif ($emailHit)            { $s += 25 }
        return $s
      }
      $best = $cands | Sort-Object -Property @{Expression = { & $score $_ }; Descending = $true}, modifiedon -Descending | Select-Object -First 1
      Write-Host ("  -> Matched contact: {0} (mobile={1}, email={2}, score={3}, id={4})" -f $best.fullname, $best.mobilephone, $best.emailaddress1, (& $score $best), $best.contactid) -ForegroundColor DarkGray
      return $best.contactid
    }
  }

  # No match — create
  $newContact = @{
    firstname     = $Body.firstName
    lastname      = $Body.lastName
    emailaddress1 = $Body.email
    mobilephone   = $Body.phoneE164
    telephone1    = $Body.phoneE164
  } | ConvertTo-Json -Depth 5

  $createResp = Invoke-RestMethod -Uri "$ApiBase/contacts" -Method Post -Headers $Headers -Body $newContact
  $contactId = $createResp.contactid
  if (-not $contactId) { throw "Contact creation succeeded but no contactid was returned." }
  Write-Host ("  -> Created new contact: {0} {1} ({2})" -f $Body.firstName, $Body.lastName, $contactId) -ForegroundColor DarkGray
  return $contactId
}

# Background job that waits for the engagement service to materialize a
# conversation (msdyn_ocliveworkitem) for the given delivery, then PATCHes the
# Customer lookup so the agent UI shows the right contact even when the call
# never connects (Teams Phone PSTN failure, voicemail, etc.).
#
# The proactive engagement service writes the contact_id we passed onto the
# msdyn_proactive_delivery row but does NOT propagate it to the conversation's
# customer lookup unless the call connects and the inbound caller-ID lookup
# finds an unambiguous match. This job closes that gap.
function Start-CustomerBindJob {
  param(
    [Parameter(Mandatory)][string]$DeliveryId,
    [Parameter(Mandatory)][string]$ContactId,
    [Parameter(Mandatory)][string]$DestinationPhone,
    [Parameter(Mandatory)][datetime]$SubmittedUtc
  )

  Start-Job -Name "bind-$DeliveryId" -ArgumentList $DeliveryId, $ContactId, $DestinationPhone, $SubmittedUtc, $OrgUrl, $ApiBase -ScriptBlock {
    param($DeliveryId, $ContactId, $DestinationPhone, $SubmittedUtc, $OrgUrl, $ApiBase)

    $log = Join-Path $env:TEMP "d365-bind-$DeliveryId.log"
    function W($m) { "$([DateTime]::UtcNow.ToString('o')) $m" | Out-File -FilePath $log -Append -Encoding utf8 }

    try {
      $tok = az account get-access-token --resource $OrgUrl --query accessToken -o tsv 2>$null
      if (-not $tok) { W "ERR: no token"; return }
      $h = @{
        Authorization      = "Bearer $tok"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        "Content-Type"     = "application/json; charset=utf-8"
        "If-Match"         = "*"
      }
      $sinceFilter = $SubmittedUtc.AddMinutes(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
      $deadline    = (Get-Date).AddMinutes(15)

      W "START delivery=$DeliveryId contact=$ContactId phone=$DestinationPhone since=$sinceFilter"

      while ((Get-Date) -lt $deadline) {
        $convoId = $null

        # Primary: find conversation by destination phone, created after submit
        try {
          $phoneEnc = [Uri]::EscapeDataString("msdyn_title eq '$($DestinationPhone): Proactive Outbound' and createdon ge $sinceFilter")
          $u = "$ApiBase/msdyn_ocliveworkitems?`$select=msdyn_ocliveworkitemid,_msdyn_customer_value,createdon&`$filter=$phoneEnc&`$orderby=createdon desc&`$top=5"
          $r = Invoke-RestMethod -Uri $u -Headers $h -Method Get
          $cands = @($r.value)
          if ($cands.Count -gt 0) {
            $target = $cands | Where-Object { -not $_._msdyn_customer_value } | Select-Object -First 1
            if (-not $target) { $target = $cands[0] }
            $convoId = $target.msdyn_ocliveworkitemid
            W "  found conversation $convoId (customerSet=$([bool]$target._msdyn_customer_value))"
          }
        } catch { W "  poll error: $($_.Exception.Message)" }

        if ($convoId) {
          try {
            $body = @{ 'msdyn_customer_msdyn_ocliveworkitem_contact@odata.bind' = "/contacts($ContactId)" } | ConvertTo-Json
            Invoke-RestMethod -Uri "$ApiBase/msdyn_ocliveworkitems($convoId)" -Method Patch -Headers $h -Body $body | Out-Null
            W "DONE PATCHed customer onto conversation $convoId"
            return
          } catch {
            W "  PATCH error: $($_.Exception.Message)"
          }
        }

        Start-Sleep -Seconds 8
      }
      W "TIMEOUT - no conversation found within 15 min"
    } catch {
      W "FATAL: $($_.Exception.Message)"
    }
  } | Out-Null
}

function Invoke-ProactiveDelivery {
  param([Parameter(Mandatory)]$Body, [Parameter(Mandatory)]$ContactId, [Parameter(Mandatory)]$Headers)

  # InputAttributes must be a flat string-string map per the API spec
  $inputAttrs = @{}
  foreach ($k in $Body.ccaas.InputAttributes.PSObject.Properties.Name) {
    $v = $Body.ccaas.InputAttributes.$k
    if ($null -ne $v) { $inputAttrs[$k] = "$v" }
  }
  # Add a few useful tracking values
  $inputAttrs["consentTimestampUtc"] = "$($Body.consentTimestampUtc)"
  $inputAttrs["customerEmail"]       = "$($Body.email)"
  $inputAttrs["customerLocale"]      = "$($Body.locale)"
  $inputAttrs["customerTimeZone"]    = "$($Body.timeZone)"

  # Build the Windows array, then serialize to a JSON STRING.
  # Per the docs the action's Windows / InputAttributes parameters are Edm.String
  # containing serialized JSON, NOT native OData arrays/objects.
  $windowsArr = @($Body.ccaas.Windows | ForEach-Object { @{ Start = $_.Start; End = $_.End } })
  $windowsJson = ConvertTo-Json -InputObject $windowsArr -Depth 5 -Compress
  $inputAttrsJson = ConvertTo-Json -InputObject $inputAttrs -Depth 5 -Compress

  $payload = @{
    ApiVersion                  = "1.0"
    ProactiveEngagementConfigId = $ConfigId
    DestinationPhoneNumber      = $Body.phoneE164
    ContactId                   = $ContactId
    Windows                     = $windowsJson
    InputAttributes             = $inputAttrsJson
  } | ConvertTo-Json -Depth 10 -Compress

  Write-Host "  -> POST CCaaS_CreateProactiveVoiceDelivery" -ForegroundColor DarkGray
  Write-Host "     $payload" -ForegroundColor DarkGray

  return Invoke-RestMethod -Uri "$ApiBase/CCaaS_CreateProactiveVoiceDelivery" -Method Post -Headers $Headers -Body $payload
}

# -----------------------------------------------------------------------------
#  HTTP listener
# -----------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
  Write-Host "ERROR: could not bind $prefix. Is another process using port $Port?" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " D365 Callback proxy listening on $prefix" -ForegroundColor Cyan
Write-Host " Org      : $OrgUrl" -ForegroundColor Cyan
Write-Host " Config   : $ConfigId" -ForegroundColor Cyan
Write-Host " Stop     : Ctrl+C" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
  } catch { break }

  $req = $ctx.Request
  $res = $ctx.Response

  # CORS — allow any origin (dev only)
  $res.Headers.Add("Access-Control-Allow-Origin",  "*")
  $res.Headers.Add("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
  $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

  if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode = 204; $res.Close(); continue }

  if ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -eq "/health") {
    $b = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
    $res.ContentType = "application/json"
    $res.OutputStream.Write($b, 0, $b.Length); $res.Close(); continue
  }

  # GET /metrics/wait  -> { ok, avgWaitSec, sampleSize, windowHours, asOf }
  # Averages msdyn_conversationfirstwaittimeinseconds across recent live work items.
  if ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -eq "/metrics/wait") {
    try {
      $windowHours = 24
      $sinceUtc    = (Get-Date).ToUniversalTime().AddHours(-$windowHours).ToString("yyyy-MM-ddTHH:mm:ssZ")
      $headers     = New-Headers
      $u = "$ApiBase/msdyn_ocliveworkitems?`$select=msdyn_conversationfirstwaittimeinseconds,createdon&`$filter=createdon ge $sinceUtc and msdyn_conversationfirstwaittimeinseconds ne null&`$top=200"
      $r = Invoke-RestMethod -Uri $u -Headers $headers -Method Get
      $vals = @($r.value | ForEach-Object { [int]$_.msdyn_conversationfirstwaittimeinseconds } | Where-Object { $_ -ge 0 })
      $avg  = if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Average).Average, 1) } else { $null }
      $out  = @{
        ok          = $true
        avgWaitSec  = $avg
        sampleSize  = $vals.Count
        windowHours = $windowHours
        asOf        = (Get-Date).ToUniversalTime().ToString("o")
      } | ConvertTo-Json -Depth 5
      $b = [Text.Encoding]::UTF8.GetBytes($out)
      $res.ContentType = "application/json"; $res.StatusCode = 200
      $res.OutputStream.Write($b, 0, $b.Length); $res.Close(); continue
    } catch {
      $err = @{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json
      $b = [Text.Encoding]::UTF8.GetBytes($err)
      $res.ContentType = "application/json"; $res.StatusCode = 500
      $res.OutputStream.Write($b, 0, $b.Length); $res.Close(); continue
    }
  }

  if (-not ($req.HttpMethod -eq "POST" -and $req.Url.AbsolutePath -eq "/callback")) {
    $res.StatusCode = 404; $res.Close(); continue
  }

  $stamp = Get-Date -Format "HH:mm:ss"
  Write-Host "[$stamp] POST /callback from $($req.RemoteEndPoint)" -ForegroundColor Yellow

  try {
    $reader = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
    $raw = $reader.ReadToEnd()
    $body = $raw | ConvertFrom-Json

    if (-not $body.consent) { throw "Consent flag is missing or false." }
    if (-not $body.phoneE164) { throw "phoneE164 is required." }
    if (-not $body.ccaas.Windows -or $body.ccaas.Windows.Count -lt 1) { throw "At least one Window is required." }

    $headers   = New-Headers
    $contactId = Resolve-ContactId -Body $body -Headers $headers
    $result    = Invoke-ProactiveDelivery -Body $body -ContactId $contactId -Headers $headers

    # Engagement service won't bind the Customer lookup on the resulting
    # conversation unless the call connects with an unambiguous caller-ID
    # match. Spawn a background poller that PATCHes it for us so the agent
    # always sees the right contact, even on failed/dropped calls.
    if ($result.DeliveryId -and $contactId) {
      Start-CustomerBindJob -DeliveryId $result.DeliveryId -ContactId $contactId -DestinationPhone $body.phoneE164 -SubmittedUtc ([DateTime]::UtcNow)
      # Reap completed jobs so they don't accumulate in the runspace
      Get-Job | Where-Object { $_.State -in 'Completed','Failed','Stopped' } | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    $out = @{
      ok         = $true
      DeliveryId = $result.DeliveryId
      ContactId  = $contactId
    } | ConvertTo-Json -Depth 5

    Write-Host "  -> SUCCESS DeliveryId = $($result.DeliveryId)" -ForegroundColor Green

    $res.ContentType = "application/json"
    $res.StatusCode  = 200
    $b = [Text.Encoding]::UTF8.GetBytes($out)
    $res.OutputStream.Write($b, 0, $b.Length)
  }
  catch {
    $msg = $_.Exception.Message
    $detail = ""
    # Invoke-RestMethod stashes the response body in ErrorDetails.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $detail = $_.ErrorDetails.Message
    }
    elseif ($_.Exception.Response) {
      try {
        $stream = $_.Exception.Response.GetResponseStream()
        $sr = [IO.StreamReader]::new($stream)
        $detail = $sr.ReadToEnd()
      } catch {}
    }
    Write-Host "  -> ERROR: $msg" -ForegroundColor Red
    if ($detail) { Write-Host "     $detail" -ForegroundColor DarkRed }

    $err = @{ ok = $false; error = $msg; detail = $detail } | ConvertTo-Json -Depth 5
    $res.StatusCode  = 500
    $res.ContentType = "application/json"
    $b = [Text.Encoding]::UTF8.GetBytes($err)
    $res.OutputStream.Write($b, 0, $b.Length)
  }
  finally {
    $res.Close()
  }
}

$listener.Stop()
