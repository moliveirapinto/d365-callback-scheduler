<#
.SYNOPSIS
  Deploys the Callback Scheduler solution into ANY Dataverse environment.

.DESCRIPTION
  - Creates publisher (cbk) and solution (CallbackScheduler) if they don't exist
  - Creates 6 cbk_ environment variable definitions with sensible defaults
  - Uploads cbk_callback1..6.html (6 UI variants) and cbk_callback/setup.html as web resources
  - Adds all components to the solution
  - Publishes customizations
  - (Optional) Exports the solution as a managed .zip for distribution

  Auth: uses your active `az` login. Run `az login` first if needed.

.PARAMETER EnvUrl
  The Dataverse environment URL, e.g. https://contoso.crm.dynamics.com

.PARAMETER ExportZip
  If set, exports the solution as a managed zip into ./dist/ after deployment.

.EXAMPLE
  .\deploy.ps1 -EnvUrl https://mauriciomaster.crm.dynamics.com -ExportZip
#>
param(
  [Parameter(Mandatory=$true)][string]$EnvUrl,
  [switch]$ExportZip,
  [string]$Version = "1.0.0.0"
)

$ErrorActionPreference = "Stop"
$EnvUrl = $EnvUrl.TrimEnd("/")

# --- constants -------------------------------------------------------------
$PublisherUniqueName     = "cbk"
$PublisherDisplayName    = "Callback Scheduler"
$PublisherCustomization  = "cbk"
$PublisherOptionPrefix   = 10000
$SolutionUniqueName      = "CallbackScheduler"
$SolutionDisplayName     = "Callback Scheduler for D365 Contact Center"
$SolutionDescription     = "Self-service callback scheduling for D365 Contact Center proactive outbound voice."

# Env var definitions (schemaName, displayName, type, default, description)
# type: 100000000=String, 100000001=Number, 100000002=Boolean, 100000003=JSON
$EnvVars = @(
  @{ name="cbk_ProactiveEngagementConfigId"; display="Proactive Engagement Config Id"; type=100000000; default=""; desc="GUID of the Proactive Engagement Configuration to use for outbound calls. Leave blank to auto-discover the first one." },
  @{ name="cbk_HourStart";                   display="Business Hours Start";              type=100000001; default="9";  desc="First hour of the day callbacks can be scheduled (24h, local time)." },
  @{ name="cbk_HourEnd";                     display="Business Hours End";                type=100000001; default="18"; desc="Last hour of the day callbacks can be scheduled (24h, local time)." },
  @{ name="cbk_SlotMinutes";                 display="Slot Length (minutes)";             type=100000001; default="30"; desc="Length of each bookable callback window." },
  @{ name="cbk_DaysAhead";                   display="Booking Horizon (days)";            type=100000001; default="14"; desc="How many days in advance customers may book a callback." },
  @{ name="cbk_FlowTriggerUrl";              display="Customer-Mode Flow URL";            type=100000000; default="";   desc="Optional. HTTP-trigger URL of a Power Automate flow that handles submissions when the page is opened anonymously (outside D365)." }
)

# Web resources to upload (local relative path - resource name)
$WebResources = @(
  @{ name="cbk_callback1.html";      file="src/WebResources/callback1.html"; display="Callback Scheduler 1";       type=1 },
  @{ name="cbk_callback2.html";      file="src/WebResources/callback2.html"; display="Callback Scheduler 2";       type=1 },
  @{ name="cbk_callback3.html";      file="src/WebResources/callback3.html"; display="Callback Scheduler 3";       type=1 },
  @{ name="cbk_callback4.html";      file="src/WebResources/callback4.html"; display="Callback Scheduler 4";       type=1 },
  @{ name="cbk_callback5.html";      file="src/WebResources/callback5.html"; display="Callback Scheduler 5";       type=1 },
  @{ name="cbk_callback6.html";      file="src/WebResources/callback6.html"; display="Callback Scheduler 6";       type=1 },
  @{ name="cbk_callback/setup.html"; file="src/WebResources/setup.html";     display="Callback Scheduler - Setup"; type=1 },
  @{ name="cbk_callback/admin.html"; file="src/WebResources/admin.html";     display="Callback Scheduler - Admin"; type=1 },

  # ---- Portuguese (Brazil) ----
  @{ name="cbk_ptbr/callback1.html"; file="src/WebResources/ptbr/callback1.html"; display="Callback Scheduler 1 (pt-BR)"; type=1 },
  @{ name="cbk_ptbr/callback2.html"; file="src/WebResources/ptbr/callback2.html"; display="Callback Scheduler 2 (pt-BR)"; type=1 },
  @{ name="cbk_ptbr/callback3.html"; file="src/WebResources/ptbr/callback3.html"; display="Callback Scheduler 3 (pt-BR)"; type=1 },
  @{ name="cbk_ptbr/callback4.html"; file="src/WebResources/ptbr/callback4.html"; display="Callback Scheduler 4 (pt-BR)"; type=1 },
  @{ name="cbk_ptbr/callback5.html"; file="src/WebResources/ptbr/callback5.html"; display="Callback Scheduler 5 (pt-BR)"; type=1 },
  @{ name="cbk_ptbr/callback6.html"; file="src/WebResources/ptbr/callback6.html"; display="Callback Scheduler 6 (pt-BR)"; type=1 },
  @{ name="cbk_ptbr/admin.html";     file="src/WebResources/ptbr/admin.html";     display="Callback Scheduler - Admin (pt-BR)"; type=1 },

  # ---- Spanish ----
  @{ name="cbk_es/callback1.html";   file="src/WebResources/es/callback1.html";   display="Callback Scheduler 1 (es)"; type=1 },
  @{ name="cbk_es/callback2.html";   file="src/WebResources/es/callback2.html";   display="Callback Scheduler 2 (es)"; type=1 },
  @{ name="cbk_es/callback3.html";   file="src/WebResources/es/callback3.html";   display="Callback Scheduler 3 (es)"; type=1 },
  @{ name="cbk_es/callback4.html";   file="src/WebResources/es/callback4.html";   display="Callback Scheduler 4 (es)"; type=1 },
  @{ name="cbk_es/callback5.html";   file="src/WebResources/es/callback5.html";   display="Callback Scheduler 5 (es)"; type=1 },
  @{ name="cbk_es/callback6.html";   file="src/WebResources/es/callback6.html";   display="Callback Scheduler 6 (es)"; type=1 },
  @{ name="cbk_es/admin.html";       file="src/WebResources/es/admin.html";       display="Callback Scheduler - Admin (es)"; type=1 }
)

# --- auth ------------------------------------------------------------------
function Get-Token {
  $r = & az account get-access-token --resource $EnvUrl --query accessToken -o tsv 2>$null
  if (-not $r) { throw "Could not get access token. Run: az login --tenant <yours> ; az account set ; then retry." }
  return $r.Trim()
}
$tok = Get-Token
$headers = @{
  Authorization      = "Bearer $tok"
  "OData-MaxVersion" = "4.0"
  "OData-Version"    = "4.0"
  Accept             = "application/json"
  "Content-Type"     = "application/json; charset=utf-8"
}
$apiBase = "$EnvUrl/api/data/v9.2"

function Inv {
  param([string]$Method, [string]$Url, $Body=$null, [hashtable]$ExtraHeaders=@{})
  $h = @{}; foreach ($k in $headers.Keys) { $h[$k] = $headers[$k] }
  foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] }
  $args = @{ Method=$Method; Uri=$Url; Headers=$h; UseBasicParsing=$true }
  if ($Body) {
    $json = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 20 -Compress) }
    $args.Body = $json
  }
  return Invoke-WebRequest @args
}

function Get-One {
  param([string]$EntitySet, [string]$Filter, [string]$Select="")
  $u = "$apiBase/$EntitySet" + "?" + "`$filter=$([uri]::EscapeDataString($Filter))" + "&`$top=1"
  if ($Select) { $u += "&`$select=$Select" }
  $r = Inv GET $u
  $j = $r.Content | ConvertFrom-Json
  if ($j.value.Count -gt 0) { return $j.value[0] } else { return $null }
}

# --- 1. publisher ----------------------------------------------------------
Write-Host "[1/6] Publisher..." -ForegroundColor Cyan
$pub = Get-One "publishers" "uniquename eq '$PublisherUniqueName'" "publisherid,uniquename"
if ($pub) {
  Write-Host "      exists: $($pub.publisherid)"
} else {
  $r = Inv POST "$apiBase/publishers" @{
    uniquename                   = $PublisherUniqueName
    friendlyname                 = $PublisherDisplayName
    customizationprefix          = $PublisherCustomization
    customizationoptionvalueprefix = $PublisherOptionPrefix
    description                  = "Publisher for the Callback Scheduler solution."
  } @{ Prefer="return=representation" }
  $pub = $r.Content | ConvertFrom-Json
  Write-Host "      created: $($pub.publisherid)"
}
$publisherId = $pub.publisherid

# --- 2. solution -----------------------------------------------------------
Write-Host "[2/6] Solution..." -ForegroundColor Cyan
$sol = Get-One "solutions" "uniquename eq '$SolutionUniqueName'" "solutionid,uniquename,version"
if ($sol) {
  Write-Host "      exists: $($sol.solutionid) (v$($sol.version))"
} else {
  $r = Inv POST "$apiBase/solutions" @{
    uniquename                   = $SolutionUniqueName
    friendlyname                 = $SolutionDisplayName
    description                  = $SolutionDescription
    version                      = $Version
    "publisherid@odata.bind"     = "/publishers($publisherId)"
  } @{ Prefer="return=representation" }
  $sol = $r.Content | ConvertFrom-Json
  Write-Host "      created: $($sol.solutionid)"
}
$solutionId = $sol.solutionid

function Add-Component {
  param([guid]$ComponentId, [int]$ComponentType)
  # 1=Entity, 61=WebResource, 380=EnvironmentVariableDefinition, 381=EnvironmentVariableValue
  $body = @{
    ComponentId         = $ComponentId.Guid
    ComponentType       = $ComponentType
    SolutionUniqueName  = $SolutionUniqueName
    AddRequiredComponents = $false
    DoNotIncludeSubcomponents = $false
  }
  try {
    Inv POST "$apiBase/AddSolutionComponent" $body | Out-Null
  } catch {
    $msg = $_.Exception.Message
    if ($msg -notmatch "already exists|0x80048408|already a member") { throw }
  }
}

# --- 3. env var definitions + default values -------------------------------
Write-Host "[3/6] Environment variables..." -ForegroundColor Cyan
foreach ($e in $EnvVars) {
  $existing = Get-One "environmentvariabledefinitions" "schemaname eq '$($e.name)'" "environmentvariabledefinitionid"
  if ($existing) {
    Write-Host "      [$($e.name)] exists"
    $defId = $existing.environmentvariabledefinitionid
  } else {
    # We MUST set the SolutionUniqueName header on create so it lands in our solution
    $r = Inv POST "$apiBase/environmentvariabledefinitions" @{
      schemaname    = $e.name
      displayname   = $e.display
      description   = $e.desc
      type          = $e.type
      defaultvalue  = $e.default
      iscustomizable = @{ Value = $true }
    } @{ Prefer="return=representation"; "MSCRM.SolutionUniqueName"=$SolutionUniqueName }
    $defId = ($r.Content | ConvertFrom-Json).environmentvariabledefinitionid
    Write-Host "      [$($e.name)] created"
  }
  Add-Component $defId 380
}

# --- 4. web resources ------------------------------------------------------
Write-Host "[4/6] Web resources..." -ForegroundColor Cyan
$repoRoot = Split-Path -Parent $PSCommandPath
foreach ($w in $WebResources) {
  $path = Join-Path $repoRoot $w.file
  if (-not (Test-Path $path)) { throw "Missing file: $path" }
  $bytes = [IO.File]::ReadAllBytes($path)
  $b64 = [Convert]::ToBase64String($bytes)
  $existing = Get-One "webresourceset" "name eq '$($w.name)'" "webresourceid,name"
  if ($existing) {
    Inv PATCH "$apiBase/webresourceset($($existing.webresourceid))" @{
      content = $b64; displayname = $w.display
    } @{ "MSCRM.SolutionUniqueName"=$SolutionUniqueName } | Out-Null
    $wrId = $existing.webresourceid
    Write-Host "      [$($w.name)] updated"
  } else {
    $r = Inv POST "$apiBase/webresourceset" @{
      name           = $w.name
      displayname    = $w.display
      content        = $b64
      webresourcetype = $w.type
    } @{ Prefer="return=representation"; "MSCRM.SolutionUniqueName"=$SolutionUniqueName }
    $wrId = ($r.Content | ConvertFrom-Json).webresourceid
    Write-Host "      [$($w.name)] created"
  }
  Add-Component $wrId 61
}

# --- 5. publish ------------------------------------------------------------
Write-Host "[5/6] Publishing..." -ForegroundColor Cyan
Inv POST "$apiBase/PublishAllXml" $null | Out-Null
Write-Host "      published"

# --- 6. (optional) export managed zip --------------------------------------
if ($ExportZip) {
  Write-Host "[6/6] Exporting managed zip..." -ForegroundColor Cyan
  $distDir = Join-Path $repoRoot "dist"
  if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }
  $r = Inv POST "$apiBase/ExportSolution" @{
    SolutionName = $SolutionUniqueName
    Managed = $true
    ExportAutoNumberingSettings = $false
    ExportCalendarSettings = $false
    ExportCustomizationSettings = $false
    ExportEmailTrackingSettings = $false
    ExportGeneralSettings = $false
    ExportMarketingSettings = $false
    ExportOutlookSynchronizationSettings = $false
    ExportRelationshipRoles = $false
    ExportIsvConfig = $false
    ExportSales = $false
  }
  $j = $r.Content | ConvertFrom-Json
  $zipBytes = [Convert]::FromBase64String($j.ExportSolutionFile)
  $outPath = Join-Path $distDir ("{0}_managed_{1}.zip" -f $SolutionUniqueName, $Version)
  [IO.File]::WriteAllBytes($outPath, $zipBytes)
  Write-Host "      wrote $outPath ($($zipBytes.Length) bytes)" -ForegroundColor Green
} else {
  Write-Host "[6/6] Skipping zip export (pass -ExportZip to write dist\*.zip)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Open the setup page in your environment:" -ForegroundColor Yellow
Write-Host "  $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_callback/setup.html"
Write-Host "Open the admin page (new dashboard):"
Write-Host "  $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_callback/admin.html"
Write-Host "Open the scheduler page (variant 1; replace 1 with 2-6 for other variants):"
Write-Host "  $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_callback1.html"
Write-Host ""
Write-Host "Localized URLs:" -ForegroundColor Yellow
Write-Host "  pt-BR:  $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_ptbr/callback1.html"
Write-Host "  pt-BR admin: $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_ptbr/admin.html"
Write-Host "  es:     $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_es/callback1.html"
Write-Host "  es admin:    $EnvUrl/main.aspx?pagetype=webresource&webresourceName=cbk_es/admin.html"
