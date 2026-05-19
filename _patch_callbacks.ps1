# Patch all 5 callback HTML pages:
#   - Strip workstream picker (moved to admin page)
#   - Add cbk_MaxCallsPerSlot + cbk_AllowMultipleBookings env vars
#   - Wire operating-hours window into slot building
#   - Wire slot capacity limit + duplicate-booking modal
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\maoliveira\Desktop\d365-callback-scheduler\solution\src\WebResources'
$files = @('callback1.html','callback2.html','callback3.html','callback4.html','callback5.html')
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$newHelpers = @'
/* ============================================================================
   Enforcement: operating hours, slot capacity, duplicate-booking guard.
   The workstream picker was moved to /WebResources/cbk_admin.html.
   ============================================================================ */
const DOW = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];

function _apiBase(){
  return (CONFIG.orgUrl || window.location.origin).replace(/\/+$/, "") + "/api/data/v9.2";
}
async function _apiGet(rel){
  const r = await fetch(_apiBase() + rel, {
    credentials: "include",
    headers: { Accept: "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0" }
  });
  if (!r.ok) throw new Error("HTTP " + r.status);
  return r.json();
}
function _hhmmToMin(s){ const p = String(s||"").split(":"); return (+p[0]||0)*60 + (+p[1]||0); }
function _bucketKey(iso){
  const t = new Date(iso).getTime();
  const step = (CONFIG.slotMinutes || 30) * 60000;
  return String(Math.floor(t / step) * step);
}

async function loadOperatingHours(){
  CONFIG.opHours = { schedule: null, alwaysOpen: true };
  try {
    const cfgId = CONFIG.proactiveEngagementConfigId; if (!cfgId) return;
    const cfg = await _apiGet("/msdyn_proactive_engagement_configs(" + cfgId + ")?$select=_msdyn_queue_value");
    const qId = cfg && cfg._msdyn_queue_value; if (!qId) return;
    const q = await _apiGet("/queues(" + qId + ")?$select=_msdyn_operatinghourid_value");
    const ohId = q && q._msdyn_operatinghourid_value; if (!ohId) return;
    const oh = await _apiGet("/msdyn_operatinghours(" + ohId + ")?$select=msdyn_enablealldays,msdyn_starttimestring,msdyn_endtimestring,msdyn_calendarid");
    const sched = {};
    if (oh.msdyn_enablealldays){
      const win = { openMin: _hhmmToMin(oh.msdyn_starttimestring || "00:00"), closeMin: _hhmmToMin(oh.msdyn_endtimestring || "24:00") };
      for (let i=0;i<7;i++) sched[i] = win;
      CONFIG.opHours = { schedule: sched, alwaysOpen: false }; return;
    }
    if (oh.msdyn_calendarid){
      const cal = await _apiGet("/calendars(" + oh.msdyn_calendarid + ")?$expand=calendar_calendar_rules($select=duration,starttime,pattern)");
      const rules = (cal && cal.calendar_calendar_rules) || [];
      const map = { SU:0,MO:1,TU:2,WE:3,TH:4,FR:5,SA:6 };
      for (const r of rules){
        if (!r.pattern || !r.starttime || !r.duration) continue;
        const open = _hhmmToMin(r.starttime), close = open + r.duration;
        const m = /BYDAY=([A-Z,]+)/.exec(r.pattern);
        const days = m ? m[1].split(",") : ["SU","MO","TU","WE","TH","FR","SA"];
        for (const d of days){ const i = map[d]; if (i != null) sched[i] = { openMin: open, closeMin: close }; }
      }
      if (Object.keys(sched).length){ CONFIG.opHours = { schedule: sched, alwaysOpen: false }; return; }
    }
    if (oh.msdyn_starttimestring && oh.msdyn_endtimestring){
      const win = { openMin: _hhmmToMin(oh.msdyn_starttimestring), closeMin: _hhmmToMin(oh.msdyn_endtimestring) };
      for (let i=1;i<=5;i++) sched[i] = win;
      CONFIG.opHours = { schedule: sched, alwaysOpen: false };
    }
  } catch(e){ console.warn("[cbk] loadOperatingHours failed", e); }
}
function getDayWindow(d){
  if (!CONFIG.opHours || CONFIG.opHours.alwaysOpen) return { openMin: 0, closeMin: 24*60 };
  return (CONFIG.opHours.schedule && CONFIG.opHours.schedule[d.getDay()]) || null;
}

async function loadBookedCounts(){
  CONFIG.bookedCounts = new Map();
  try {
    const cfgId = CONFIG.proactiveEngagementConfigId; if (!cfgId) return;
    const fromIso = new Date(Date.now() - 60000).toISOString();
    const f = "msdyn_proactive_engagement_config_id eq '" + cfgId + "' and statecode eq 0 and msdyn_window_start_date ge " + fromIso;
    const r = await _apiGet("/msdyn_proactive_deliveries?$select=msdyn_window_start_date&$filter=" + encodeURIComponent(f) + "&$top=500");
    for (const d of (r.value || [])){
      const k = _bucketKey(d.msdyn_window_start_date);
      CONFIG.bookedCounts.set(k, (CONFIG.bookedCounts.get(k) || 0) + 1);
    }
  } catch(e){ console.warn("[cbk] loadBookedCounts failed", e); }
}
function slotIsFull(startDate){
  if (!CONFIG.maxCallsPerSlot || CONFIG.maxCallsPerSlot <= 0) return false;
  if (!CONFIG.bookedCounts) return false;
  const k = _bucketKey(startDate.toISOString());
  return (CONFIG.bookedCounts.get(k) || 0) >= CONFIG.maxCallsPerSlot;
}

async function findCustomerActiveDelivery(phoneE164){
  try {
    const cfgId = CONFIG.proactiveEngagementConfigId;
    const fromIso = new Date(Date.now() - 60000).toISOString();
    const phoneEsc = String(phoneE164).replace(/'/g, "''");
    let f = "msdyn_to_address eq '" + phoneEsc + "' and statecode eq 0 and msdyn_window_start_date ge " + fromIso;
    if (cfgId) f += " and msdyn_proactive_engagement_config_id eq '" + cfgId + "'";
    const r = await _apiGet("/msdyn_proactive_deliveries?$select=msdyn_proactive_deliveryid,msdyn_window_start_date,msdyn_window_end_date,msdyn_to_address&$filter=" + encodeURIComponent(f) + "&$orderby=msdyn_window_start_date asc&$top=1");
    if (r.value && r.value.length){
      const d = r.value[0];
      return { id: d.msdyn_proactive_deliveryid, start: new Date(d.msdyn_window_start_date), end: new Date(d.msdyn_window_end_date), phone: d.msdyn_to_address };
    }
  } catch(e){ console.warn("[cbk] findCustomerActiveDelivery failed", e); }
  return null;
}
async function cancelDelivery(id){
  const r = await fetch(_apiBase() + "/msdyn_proactive_deliveries(" + id + ")", {
    method: "PATCH", credentials: "include",
    headers: { "Content-Type": "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0" },
    body: JSON.stringify({ statecode: 1, statuscode: 2 })
  });
  if (!r.ok) throw new Error("Cancel HTTP " + r.status);
}
function showExistingBookingModal(existing){
  return new Promise(function(resolve){
    const back = document.createElement("div"); back.className = "cbk-modal-back";
    const dateF = new Intl.DateTimeFormat(undefined, { weekday: "long", month: "long", day: "numeric" });
    const timeF = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
    back.innerHTML =
      '<div class="cbk-modal" role="dialog" aria-modal="true">' +
        '<h3>You already have a callback scheduled</h3>' +
        '<p>We found an existing callback booked for <b>' + existing.phone + '</b>:</p>' +
        '<div class="cbk-modal-summary">' +
          '<div><b>' + dateF.format(existing.start) + '</b></div>' +
          '<div>' + timeF.format(existing.start) + ' &ndash; ' + timeF.format(existing.end) + '</div>' +
        '</div>' +
        '<p>Cancel the existing one and book this new time, or keep the existing callback?</p>' +
        '<div class="cbk-modal-actions">' +
          '<button type="button" class="cbk-btn cbk-btn-ghost" data-act="keep">Keep existing</button>' +
          '<button type="button" class="cbk-btn cbk-btn-danger" data-act="cancel">Cancel existing &amp; rebook</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(back);
    back.addEventListener("click", function(e){
      const b = e.target.closest("button[data-act]");
      if (!b && e.target !== back) return;
      const act = b ? b.dataset.act : "keep";
      back.remove();
      resolve(act);
    });
  });
}
'@

# CSS to inject for modal
$modalCss = @'
/* cbk modal (duplicate-booking guard) */
.cbk-modal-back{position:fixed;inset:0;background:rgba(11,16,32,.55);display:flex;align-items:center;justify-content:center;z-index:9999;animation:cbkfade .15s ease-out}
.cbk-modal{background:#fff;max-width:480px;width:calc(100% - 32px);padding:28px;border-radius:18px;box-shadow:0 30px 80px -20px rgba(11,16,32,.4);font-family:inherit;color:#0b1020}
.cbk-modal h3{margin:0 0 10px;font-size:22px;font-weight:800;letter-spacing:-.01em}
.cbk-modal p{margin:0 0 12px;line-height:1.55;color:#5b6075}
.cbk-modal-summary{background:#f5f7fb;padding:14px;border-radius:12px;margin:0 0 16px;font-size:14px;line-height:1.5}
.cbk-modal-actions{display:flex;gap:10px;justify-content:flex-end;flex-wrap:wrap;margin-top:18px}
.cbk-btn{padding:10px 16px;border-radius:10px;border:0;cursor:pointer;font-weight:700;font-size:14px;font-family:inherit}
.cbk-btn-ghost{background:#fff;border:1px solid rgba(11,16,32,.18);color:#0b1020}
.cbk-btn-danger{background:linear-gradient(135deg,#c43054,#7a1f37);color:#fff}
.cbk-slot-full{position:relative}
.cbk-slot-full::after{content:"full";position:absolute;top:-6px;right:-6px;background:#c43054;color:#fff;font-size:9px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;padding:2px 6px;border-radius:8px;box-shadow:0 2px 6px rgba(196,48,84,.4)}
@keyframes cbkfade{from{opacity:0}to{opacity:1}}
'@

foreach ($file in $files) {
  $path = Join-Path $root $file
  Write-Host "=== Patching $file ==="
  $t = [System.IO.File]::ReadAllText($path, $utf8NoBom)
  $orig = $t

  # ---- 1. Strip ws-pill HTML markup ----
  $rxPill = [regex]'(?s)\s*<div class="ws-pill"[^>]*>.*?</div>\s*</div>\s*</div>'
  $m = $rxPill.Match($t)
  if (-not $m.Success) { Write-Host "  ! ws-pill markup not matched"; } else { $t = $t.Remove($m.Index, $m.Length); Write-Host "  - stripped ws-pill markup ($($m.Length) chars)" }

  # ---- 2. Replace workstream JS block with new helpers ----
  $rxWs = [regex]'(?s)/\*[- =]+\r?\n\s*Workstream picker.*?initWorkstreamPicker\(\)\s*\{.*?\n\}\r?\n'
  $m = $rxWs.Match($t)
  if (-not $m.Success) { Write-Host "  ! workstream JS not matched" } else { $t = $t.Substring(0, $m.Index) + $newHelpers + "`r`n" + $t.Substring($m.Index + $m.Length); Write-Host "  - replaced workstream JS with helpers" }

  # ---- 3. Add new env vars to loadConfigFromXrm ----
  $oldXrmEnvLoad = '  CONFIG.daysAhead                   = num("cbk_DaysAhead",  DEFAULTS.daysAhead);'
  $newXrmEnvLoad = $oldXrmEnvLoad + "`r`n" + `
    '  CONFIG.maxCallsPerSlot             = num("cbk_MaxCallsPerSlot", 5);' + "`r`n" + `
    '  CONFIG.allowMultipleBookings       = String(map["cbk_AllowMultipleBookings"] || "Yes").toLowerCase() !== "no";'
  if ($t.Contains($oldXrmEnvLoad)) { $t = $t.Replace($oldXrmEnvLoad, $newXrmEnvLoad); Write-Host "  - added env vars to loadConfigFromXrm" } else { Write-Host "  ! daysAhead anchor not found in loadConfigFromXrm" }

  # ---- 4. Add new env vars to loadConfigStandalone ----
  $oldStdLoad = '  CONFIG.daysAhead                   = parseInt(url.searchParams.get("days"), 10) || DEFAULTS.daysAhead;'
  $newStdLoad = $oldStdLoad + "`r`n" + `
    '  CONFIG.maxCallsPerSlot             = parseInt(url.searchParams.get("max"), 10) || 5;' + "`r`n" + `
    '  CONFIG.allowMultipleBookings       = (url.searchParams.get("multi") || "yes").toLowerCase() !== "no";'
  if ($t.Contains($oldStdLoad)) { $t = $t.Replace($oldStdLoad, $newStdLoad); Write-Host "  - added env vars to loadConfigStandalone" } else { Write-Host "  ! daysAhead anchor not found in loadConfigStandalone" }

  # ---- 5. Rewrite dayHasAvailableSlot to respect op hours ----
  $rxDayHas = [regex]'(?s)function dayHasAvailableSlot\(d\)\{[^}]*\}'
  $newDayHas = @'
function dayHasAvailableSlot(d){
  const minTime = new Date();
  const stepMs = CONFIG.slotMinutes*60000;
  const win = getDayWindow(d);
  if (!win) return false;
  const dayStart = new Date(d); dayStart.setHours(0,0,0,0); dayStart.setTime(dayStart.getTime() + win.openMin*60000);
  const dayEnd   = new Date(d); dayEnd.setHours(0,0,0,0);   dayEnd.setTime(dayEnd.getTime()   + win.closeMin*60000);
  for (let t = dayStart.getTime(); t < dayEnd.getTime(); t += stepMs) {
    if (new Date(t + stepMs) > minTime) return true;
  }
  return false;
}
'@
  $m = $rxDayHas.Match($t)
  if ($m.Success) { $t = $t.Substring(0, $m.Index) + $newDayHas + $t.Substring($m.Index + $m.Length); Write-Host "  - rewrote dayHasAvailableSlot" } else { Write-Host "  ! dayHasAvailableSlot not matched" }

  # ---- 6. Rewrite buildSlots to respect op hours + full-slot disable ----
  $rxBuildSlots = [regex]'(?s)function buildSlots\(\)\{.*?\n\}'
  $newBuildSlots = @'
function buildSlots(){
  slotsHost.innerHTML = "";
  const minTime = new Date();
  const stepMs = CONFIG.slotMinutes*60000;
  const win = getDayWindow(state.date);
  if (!win) {
    const empty = document.createElement("div");
    empty.className = "slot-section";
    empty.innerHTML = '<div class="slot-label">Closed</div><p style="color:var(--muted,#5b6075);font-size:14px;margin:8px 0 0">We are closed on this day. Please pick another date.</p>';
    slotsHost.appendChild(empty); return;
  }
  const noonMin = 12*60;
  const groups = [
    { label: "Morning",   from: win.openMin,                 to: Math.min(noonMin, win.closeMin) },
    { label: "Afternoon", from: Math.max(noonMin, win.openMin), to: win.closeMin }
  ].filter(g => g.from < g.to);
  for (const g of groups){
    const section = document.createElement("div"); section.className = "slot-section";
    const label = document.createElement("div"); label.className = "slot-label"; label.textContent = g.label; section.appendChild(label);
    const grid = document.createElement("div"); grid.className = "slots";
    const a = new Date(state.date); a.setHours(0,0,0,0); a.setTime(a.getTime() + g.from*60000);
    const b = new Date(state.date); b.setHours(0,0,0,0); b.setTime(b.getTime() + g.to*60000);
    for (let t = a.getTime(); t < b.getTime(); t += stepMs){
      const start = new Date(t), end = new Date(t+stepMs);
      const btn = document.createElement("button"); btn.type = "button"; btn.className = "slot";
      btn.innerHTML = `${timeFmt.format(start)}<small>to ${timeFmt.format(end)}</small>`;
      if (end <= minTime) { btn.disabled = true; }
      else if (slotIsFull(start)) { btn.disabled = true; btn.classList.add("cbk-slot-full"); btn.title = "Fully booked"; }
      else btn.addEventListener("click", () => {
        state.slot = {start,end};
        for (const s of slotsHost.querySelectorAll(".slot")) s.classList.remove("is-selected");
        btn.classList.add("is-selected"); updatePass();
      });
      grid.appendChild(btn);
    }
    section.appendChild(grid); slotsHost.appendChild(section);
  }
}
'@
  $m = $rxBuildSlots.Match($t)
  if ($m.Success) { $t = $t.Substring(0, $m.Index) + $newBuildSlots + $t.Substring($m.Index + $m.Length); Write-Host "  - rewrote buildSlots" } else { Write-Host "  ! buildSlots not matched" }

  # ---- 7. Inject duplicate-check before the AGENT-mode booking call ----
  $oldGuard = '    if (MODE === "AGENT") {' + "`r`n" + '      if (!CONFIG.proactiveEngagementConfigId) throw new Error("No Proactive Engagement Config available in this environment.");' + "`r`n" + '      const contactId = await resolveContactXrm(payload);'
  $newGuard = '    if (MODE === "AGENT") {' + "`r`n" + `
    '      if (!CONFIG.proactiveEngagementConfigId) throw new Error("No Proactive Engagement Config available in this environment.");' + "`r`n" + `
    '      if (CONFIG.allowMultipleBookings === false) {' + "`r`n" + `
    '        const existing = await findCustomerActiveDelivery(phoneE164);' + "`r`n" + `
    '        if (existing) {' + "`r`n" + `
    '          const act = await showExistingBookingModal(existing);' + "`r`n" + `
    '          if (act !== "cancel") { fail("Existing callback kept. Nothing changed."); submitBtn.disabled = false; submitBtn.querySelector("span").textContent = "Schedule my callback"; submitting = false; return; }' + "`r`n" + `
    '          await cancelDelivery(existing.id);' + "`r`n" + `
    '        }' + "`r`n" + `
    '      }' + "`r`n" + `
    '      const contactId = await resolveContactXrm(payload);'
  if ($t.Contains($oldGuard)) { $t = $t.Replace($oldGuard, $newGuard); Write-Host "  - injected duplicate-booking guard" } else { Write-Host "  ! duplicate-guard anchor not found" }

  # ---- 8. Replace initWorkstreamPicker(); with op-hours + booked-counts loaders ----
  $oldInit = '  initWorkstreamPicker();'
  $newInit = '  await loadOperatingHours();' + "`r`n" + '  await loadBookedCounts();' + "`r`n" + '  buildDays(); updatePass();'
  if ($t.Contains($oldInit)) {
    # The init currently does: buildDays(); updatePass(); initWorkstreamPicker(); tickLiveWait...
    # Replace the trio "buildDays(); updatePass();\n  initWorkstreamPicker();" with op-hours-then-buildDays
    $oldTrio = '  buildDays(); updatePass();' + "`r`n" + '  initWorkstreamPicker();'
    if ($t.Contains($oldTrio)) { $t = $t.Replace($oldTrio, $newInit); Write-Host "  - rewired init (op-hours -> buildDays)" }
    else { $t = $t.Replace($oldInit, ''); Write-Host "  - removed initWorkstreamPicker() (trio anchor missing)" }
  } else { Write-Host "  ! initWorkstreamPicker() call not found" }

  # ---- 9. Inject modal CSS just before </style> (first occurrence) ----
  $styleClose = '</style>'
  $idxStyle = $t.IndexOf($styleClose)
  if ($idxStyle -ge 0 -and -not $t.Contains('cbk-modal-back')) {
    $t = $t.Substring(0, $idxStyle) + $modalCss + "`r`n" + $t.Substring($idxStyle)
    Write-Host "  - injected modal CSS"
  } elseif ($t.Contains('cbk-modal-back')) {
    Write-Host "  = modal CSS already present"
  }

  if ($t -eq $orig) { Write-Host "  ! NO CHANGES" } else {
    [System.IO.File]::WriteAllText($path, $t, $utf8NoBom)
    Write-Host "  + wrote $($t.Length) bytes"
  }
}
Write-Host "Done."
