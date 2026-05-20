<?php
/**
 * book.php — Callback Scheduler public booking bridge (PHP 7.4+)
 *
 * Drop this single file anywhere on your PHP webserver. Visitors POST here from
 * the booking HTML; the file forwards the booking to Dataverse and returns JSON.
 *
 * NO frameworks required. Works on plain LAMP, cPanel, shared hosting,
 * WordPress (drop in /wp-content/ and reference via plain URL), Drupal, etc.
 *
 * ENV VARS (set in your hosting panel / .htaccess / php-fpm pool config —
 *  NOT in this file):
 *
 *   DV_ORG_URL              https://yourorg.crm.dynamics.com
 *   AAD_TENANT_ID           00000000-0000-0000-0000-000000000000
 *   AAD_CLIENT_ID           00000000-0000-0000-0000-000000000000
 *   AAD_CLIENT_SECRET       <secret>
 *   DV_PROACTIVE_CONFIG_ID  <guid> (optional, auto-discovered if blank)
 *   ALLOWED_ORIGIN          https://www.your-site.com (optional)
 *
 * Endpoint URL (after install):
 *   https://your-site.com/book.php
 */

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

$allowedOrigin = getenv('ALLOWED_ORIGIN') ?: '';
if ($allowedOrigin !== '') {
    header('Access-Control-Allow-Origin: ' . $allowedOrigin);
    header('Vary: Origin');
    header('Access-Control-Allow-Headers: Content-Type');
}
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405); echo json_encode(['error' => 'POST only']); exit;
}

// ---------- env ----------
$DV_ORG_URL  = rtrim((string)getenv('DV_ORG_URL'), '/');
$AAD_TENANT  = (string)getenv('AAD_TENANT_ID');
$AAD_CLIENT  = (string)getenv('AAD_CLIENT_ID');
$AAD_SECRET  = (string)getenv('AAD_CLIENT_SECRET');
$CFG_ID      = (string)getenv('DV_PROACTIVE_CONFIG_ID');

foreach (['DV_ORG_URL', 'AAD_TENANT_ID', 'AAD_CLIENT_ID', 'AAD_CLIENT_SECRET'] as $k) {
    if (getenv($k) === false || getenv($k) === '') {
        http_response_code(500); echo json_encode(['error' => "Server missing env var $k"]); exit;
    }
}

// ---------- naive in-process rate limit (per-IP, 5/min). For multi-process
// hosting (php-fpm), replace with APCu / Redis / your hosting provider's rate limiter. ----------
$rlFile = sys_get_temp_dir() . '/cbk_rl_' . md5($_SERVER['REMOTE_ADDR'] ?? 'na') . '.json';
$now = time();
$hits = [];
if (is_file($rlFile)) {
    $raw = file_get_contents($rlFile);
    $hits = $raw ? array_values(array_filter(json_decode($raw, true) ?: [], fn($t) => $now - (int)$t < 60)) : [];
}
$hits[] = $now;
@file_put_contents($rlFile, json_encode($hits));
if (count($hits) > 5) { http_response_code(429); echo json_encode(['error' => 'Too many requests']); exit; }

// ---------- body ----------
$raw = file_get_contents('php://input');
$p = json_decode($raw, true);
if (!is_array($p)) { http_response_code(400); echo json_encode(['error' => 'invalid JSON']); exit; }

// Honeypot
if (!empty($p['website'])) { http_response_code(204); exit; }

// Server-side validation
$err = null;
if (empty($p['firstName']) || empty($p['lastName'])) $err = 'name required';
elseif (empty($p['email']) || !filter_var($p['email'], FILTER_VALIDATE_EMAIL)) $err = 'valid email required';
elseif (empty($p['phoneE164']) || !preg_match('/^\+?[0-9]{6,16}$/', $p['phoneE164'])) $err = 'valid phone required';
elseif (empty($p['consent'])) $err = 'consent required';
elseif (empty($p['windowStartIso']) || empty($p['windowEndIso'])) $err = 'time window required';
if ($err) { http_response_code(400); echo json_encode(['error' => $err]); exit; }

// ---------- token cache (file-based, survives across requests) ----------
function get_token(): string {
    global $AAD_TENANT, $AAD_CLIENT, $AAD_SECRET, $DV_ORG_URL;
    $cacheFile = sys_get_temp_dir() . '/cbk_token_' . md5($AAD_CLIENT) . '.json';
    if (is_file($cacheFile)) {
        $j = json_decode(file_get_contents($cacheFile), true);
        if ($j && ($j['exp'] ?? 0) > time() + 60) return $j['token'];
    }
    $ch = curl_init("https://login.microsoftonline.com/$AAD_TENANT/oauth2/v2.0/token");
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POSTFIELDS => http_build_query([
            'client_id'     => $AAD_CLIENT,
            'client_secret' => $AAD_SECRET,
            'grant_type'    => 'client_credentials',
            'scope'         => "$DV_ORG_URL/.default",
        ]),
        CURLOPT_HTTPHEADER => ['Content-Type: application/x-www-form-urlencoded'],
        CURLOPT_TIMEOUT => 15,
    ]);
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200) throw new RuntimeException("Token endpoint $code: $resp");
    $j = json_decode($resp, true);
    @file_put_contents($cacheFile, json_encode([
        'token' => $j['access_token'],
        'exp'   => time() + (int)$j['expires_in'] - 300,
    ]));
    @chmod($cacheFile, 0600);
    return $j['access_token'];
}

function dv(string $method, string $path, ?array $body = null) {
    global $DV_ORG_URL;
    $token = get_token();
    $ch = curl_init("$DV_ORG_URL/api/data/v9.2/$path");
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => [
            "Authorization: Bearer $token",
            'Accept: application/json',
            'OData-MaxVersion: 4.0',
            'OData-Version: 4.0',
            'Content-Type: application/json',
            'Prefer: return=representation',
        ],
        CURLOPT_POSTFIELDS => $body !== null ? json_encode($body) : null,
        CURLOPT_TIMEOUT => 20,
    ]);
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code < 200 || $code >= 300) throw new RuntimeException("Dataverse $method $path → $code: $resp");
    return $resp === '' ? null : json_decode($resp, true);
}

function resolve_contact(array $p): string {
    if (!empty($p['email'])) {
        $e = str_replace("'", "''", $p['email']);
        $r = dv('GET', "contacts?\$filter=emailaddress1 eq '$e'&\$select=contactid&\$top=1");
        if (!empty($r['value'][0]['contactid'])) return $r['value'][0]['contactid'];
    }
    if (!empty($p['phoneE164'])) {
        $f = urlencode("mobilephone eq '{$p['phoneE164']}'");
        $r = dv('GET', "contacts?\$filter=$f&\$select=contactid&\$top=1");
        if (!empty($r['value'][0]['contactid'])) return $r['value'][0]['contactid'];
    }
    $created = dv('POST', 'contacts', [
        'firstname'     => $p['firstName'],
        'lastname'      => $p['lastName'],
        'emailaddress1' => $p['email']     ?? null,
        'mobilephone'   => $p['phoneE164'] ?? null,
    ]);
    return $created['contactid'];
}

function find_config(): string {
    global $CFG_ID;
    if ($CFG_ID !== '') return $CFG_ID;
    $r = dv('GET', 'msdyn_proactive_engagement_configs?$select=msdyn_proactive_engagement_configid&$top=1');
    if (empty($r['value'][0])) throw new RuntimeException('No Proactive Engagement Configuration found.');
    return $r['value'][0]['msdyn_proactive_engagement_configid'];
}

try {
    $contactId = resolve_contact($p);
    $configId  = find_config();
    $windows = json_encode([[
        'StartTime' => $p['windowStartIso'],
        'EndTime'   => $p['windowEndIso'],
        'TimeZone'  => $p['timeZone'] ?? 'UTC',
    ]]);
    $inputAttrs = json_encode([
        'Topic' => $p['topic'] ?? '',
        'Notes' => $p['notes'] ?? '',
        'Locale' => $p['locale'] ?? 'en',
        'ConsentTimestampUtc' => $p['consentTimestampUtc'] ?? gmdate('c'),
    ]);
    $resp = dv('POST', 'CCaaS_CreateProactiveVoiceDelivery', [
        'ProactiveEngagementConfigId' => $configId,
        'ContactId'                   => $contactId,
        'Windows'                     => $windows,
        'InputAttributes'             => $inputAttrs,
    ]);
    error_log("[book] ok contact=$contactId delivery={$resp['DeliveryId']} email={$p['email']}");
    echo json_encode(['ok' => true, 'deliveryId' => $resp['DeliveryId']]);
} catch (Throwable $e) {
    error_log('[book] FAIL ' . $e->getMessage());
    http_response_code(502);
    echo json_encode(['error' => 'Booking failed. Try again in a moment.']);
}
