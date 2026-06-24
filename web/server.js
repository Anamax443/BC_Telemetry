'use strict';
/*
 * BC_Telemetry — web servis (bez závislostí).
 * Servíruje statický dashboard + data.json a poskytuje whitelist API.
 *
 * Whitelist logika je PORT 1:1 z ITDashboard:
 *   apps/server/src/services/firewall.ts   (getAllowedIPs/setAllowedIPs/getDomainProfileStatus)
 *   apps/server/src/services/ip-guard.ts    (normalizeRequestIp/ipv4ToInt/matchesEntry/isIpAllowed/refreshIpGuard)
 *   apps/server/src/routes/firewall.ts       (/access-check, /firewall/whitelist, /firewall/domain-profile)
 * Žádné odchylky — jen RULE name a port jsou BC-specific. Source of truth je
 * pojmenovaná Windows Firewall rule; čteme/zapisujeme přes `powershell -Command`
 * inline (NEpodléhá GPO AllSigned, na rozdíl od .ps1).
 *
 * Spouští se jako Windows služba přes NSSM (scripts/install-service.cmd).
 * Konfigurace přes env:  BCT_PORT (8080), BCT_PUBLIC (./public)
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');

const PORT = Number(process.env.BCT_PORT || 8080);
const PUBLIC_DIR = path.resolve(process.env.BCT_PUBLIC || path.join(__dirname, 'public'));
const RULE_DISPLAY_NAME = `BC Telemetry Dashboard (${PORT})`;

const MIME = { '.html': 'text/html; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.ico': 'image/x-icon' };

// In-memory aktivita (ring buffer) — jako ITDashboard activity log; přežije do restartu služby.
const ACTIVITY = [];
const ACT_MAX = 200;
function logActivity(level, scope, msg) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  ACTIVITY.push({ ts, level, scope, msg });
  if (ACTIVITY.length > ACT_MAX) ACTIVITY.shift();
  console.log(`[${level}] ${scope}: ${msg}`);
}
const LOG_DIR = 'C:\\Apps\\BC_Telemetry\\logs';
const SCRIPTS_DIR = 'C:\\Apps\\BC_Telemetry\\scripts';   // importní/notifikační .ps1 (svc je odsud spouští)
const USERMAP_FILE = path.join(__dirname, 'usermap.json');  // mapování pseudonymní GUID → reálné jméno
const CHANGELOG_COMPANIES_FILE = path.join(__dirname, 'changelog-companies.json');  // výběr firem pro modul B (Audit změn)
// Ops fronta: web (LocalSystem) zapíše požadavek, denní úloha (svc) ho zpracuje a uklidí.
const OPS_DIR = path.join(__dirname, 'ops');
const OPS_REQUEST_FILE = path.join(OPS_DIR, 'ops-request.json');   // { action:'purge', companies:[], requestedAt }
const OPS_STATUS_FILE = path.join(OPS_DIR, 'ops-status.json');     // výsledek od svc (purge)
const RETENTION_FILE = path.join(OPS_DIR, 'retention.json');       // retenční politika (čtou importní skripty)
const RETENTION_DEFAULTS = { pageLogMonths: 6, changeLogMonths: 24, dailyLogDays: 30 };
const SCHEDULE_FILE = path.join(OPS_DIR, 'schedule.json');         // okno + četnost běhu úlohy
const SNAPSHOT_FILE = path.join(OPS_DIR, 'snapshot.json');         // strop řádků na sekci ve snapshotu (čte Export-DashboardSnapshot.ps1)
const SNAPSHOT_DEFAULTS = { topRows: 5000 };
const PAGEMAP_FILE = path.join(OPS_DIR, 'pagemap.json');           // PageID → {t:TableNo, n:TableName} (čte Export-DashboardSnapshot.ps1 pro „čtení tabulek")
const NOTIFY_FILE = path.join(OPS_DIR, 'notify.json');             // e-mail notifikace (čte Send-BCTelemetryNotification.ps1)
const NOTIFY_DEFAULTS = {
  enabled: false, smtpHost: 'axima-cz.mail.protection.outlook.com', smtpPort: 25,
  from: 'bc-telemetry@axima.cz', recipients: ['mtrnka@axima.cz'], cadence: 'daily', cadenceDays: 7,
  dashboardUrl: 'http://10.8.2.225:8080/', alertImportFail: true, alertStaleModule: true,
  alertSecretExpiry: true, staleHours: 24, secretExpiry: '2028-06-07', secretWarnDays: 30,
};
const SVC_ACCT = 'AXINETWORK\\svc-bc-telemetry';

// Zajisti ops dir + práva pro svc (denní úloha čte/maže request a píše status). LocalSystem to zvládne.
function ensureOpsDir() {
  try {
    if (!fs.existsSync(OPS_DIR)) fs.mkdirSync(OPS_DIR, { recursive: true });
    execFile('icacls', [OPS_DIR, '/grant', `${SVC_ACCT}:(OI)(CI)M`], { windowsHide: true }, (err) => {
      if (err) console.error(`ensureOpsDir icacls warn: ${err.message}`);
    });
  } catch (e) { console.error(`ensureOpsDir warn: ${e.message}`); }
}

// ── PowerShell helper (inline -Command, AllSigned-safe) ──────────────────────
function runPs(script) {
  return new Promise((resolve, reject) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script],
      { windowsHide: true, maxBuffer: 1 << 20, timeout: 90000 }, (err, stdout, stderr) => {
        if (err) return reject(new Error((stderr || '').toString().trim() || err.message));
        resolve(stdout.toString().trim());
      });
  });
}

// ── PORT z firewall.ts ───────────────────────────────────────────────────────
async function getAllowedIPs() {
  const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$addr = (Get-NetFirewallRule -DisplayName '${RULE_DISPLAY_NAME}' -ErrorAction Stop |
  Get-NetFirewallAddressFilter).RemoteAddress
if ($addr -is [string]) { $addr = @($addr) }
$addr | ConvertTo-Json -Compress
`;
  const out = await runPs(ps);
  if (!out) return [];
  const parsed = JSON.parse(out);
  return Array.isArray(parsed) ? parsed : [parsed];
}

async function getDomainProfileStatus() {
  const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$p = Get-NetFirewallProfile -Profile Domain -ErrorAction Stop
[pscustomobject]@{
  Enabled = [bool]$p.Enabled
  DefaultInboundAction = "$($p.DefaultInboundAction)"
} | ConvertTo-Json -Compress
`;
  try {
    const out = await runPs(ps);
    if (!out) return { enabled: null, defaultInboundAction: null, error: 'empty output' };
    const parsed = JSON.parse(out);
    return { enabled: parsed.Enabled, defaultInboundAction: parsed.DefaultInboundAction ?? null };
  } catch (err) {
    return { enabled: null, defaultInboundAction: null, error: String(err).split('\n')[0]?.slice(0, 200) ?? 'unknown' };
  }
}

async function setAllowedIPs(ips) {
  // Validate input — single IP, CIDR mask (x.x.x.x/n), rozsah (x.x.x.x-y.y.y.y)
  // nebo wildcard "*"/"Any" = bez omezení (celá rule → Any).
  // (Set-NetFirewallRule -RemoteAddress umí všechny formy; pomlčka = rozsah, Any = vše.)
  const isWild = (ip) => ip === '*' || /^any$/i.test(ip);
  const hasAny = ips.some(isWild);
  for (const ip of ips) {
    if (isWild(ip)) continue;
    if (!/^[\d.:a-fA-F/-]+$/.test(ip)) {
      throw new Error(`Invalid IP/CIDR/range: ${ip}`);
    }
  }
  if (ips.length === 0) {
    throw new Error('At least one allowed IP required (otherwise nobody can reach the API)');
  }
  // Jakýkoliv wildcard → celá rule = Any (mix s konkrétními IP nedává smysl).
  const list = hasAny ? ['Any'] : ips;
  const jsonArray = JSON.stringify(list);
  const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ips = '${jsonArray.replace(/'/g, "''")}' | ConvertFrom-Json
Set-NetFirewallRule -DisplayName '${RULE_DISPLAY_NAME}' -RemoteAddress $ips -ErrorAction Stop
'OK'
`;
  const out = await runPs(ps);
  if (out !== 'OK') throw new Error(`unexpected output: ${out}`);
  logActivity('success', 'firewall', `Whitelist updated: ${list.join(', ')}`);
}

// ── PORT z ip-guard.ts ───────────────────────────────────────────────────────
let allowedList = [];
const ALWAYS_ALLOW = new Set(['127.0.0.1', '::1']);

function ipv4ToInt(ip) {
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    const x = Number(p);
    if (!Number.isInteger(x) || x < 0 || x > 255) return null;
    n = (n * 256) + x;
  }
  return n >>> 0;
}

function normalizeRequestIp(raw) {
  if (raw.startsWith('::ffff:')) return raw.slice('::ffff:'.length);
  return raw;
}

function matchesEntry(remoteIp, entry) {
  if (entry === '*' || /^any$/i.test(entry) || entry === '0.0.0.0/0') return true; // neomezeno
  if (entry === remoteIp) return true;
  // CIDR — prefix (x.x.x.x/24) i tečková maska (x.x.x.x/255.255.255.0)
  if (entry.includes('/')) {
    const [base, maskStr] = entry.split('/');
    const baseInt = ipv4ToInt(base ?? '');
    const ipInt = ipv4ToInt(remoteIp);
    if (baseInt === null || ipInt === null) return false;
    let mask;
    if ((maskStr ?? '').includes('.')) {          // tečková maska 255.255.255.0
      mask = ipv4ToInt(maskStr);
      if (mask === null) return false;
    } else {                                       // prefix /n
      const bits = Number(maskStr);
      if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false;
      mask = bits === 0 ? 0 : (0xFFFFFFFF << (32 - bits)) >>> 0;
    }
    return (baseInt & mask) === (ipInt & mask);
  }
  // Rozsah: x.x.x.x-y.y.y.y (inkluzivně)
  if (entry.includes('-')) {
    const [startStr, endStr] = entry.split('-');
    const startInt = ipv4ToInt((startStr ?? '').trim());
    const endInt = ipv4ToInt((endStr ?? '').trim());
    const ipInt = ipv4ToInt(remoteIp);
    if (startInt === null || endInt === null || ipInt === null) return false;
    return ipInt >= startInt && ipInt <= endInt;
  }
  return false;
}

function isIpAllowed(remoteIpRaw) {
  const ip = normalizeRequestIp(remoteIpRaw);
  if (ALWAYS_ALLOW.has(ip)) return true;
  if (!allowedList.length) return true;   // cache nenačtena (po bootu) → fail-open (gate je jen formální, nezamykat)
  for (const entry of allowedList) {
    if (matchesEntry(ip, entry)) return true;
  }
  return false;
}

async function refreshIpGuard(reason) {
  try {
    const ips = await getAllowedIPs();
    allowedList = ips;
    if (reason === 'boot') {
      console.log(`Access-check whitelist loaded with ${ips.length} entries from firewall rule`);
    } else {
      logActivity('info', 'access-check', `Whitelist cache refreshed (${ips.length} entries)`);
    }
  } catch (err) {
    const msg = String(err).split('\n')[0]?.slice(0, 300) ?? 'unknown';
    if (reason === 'boot') {
      console.error(`Access-check FAILED to load whitelist at boot — cache stays empty: ${msg}`);
    } else {
      logActivity('error', 'access-check', `Whitelist refresh failed — keeping previous cache: ${msg}`);
    }
  }
}

function getCurrentWhitelist() { return [...allowedList]; }

// ── HTTP (routes 1:1 z firewall.ts + static) ─────────────────────────────────
function sendJson(res, code, obj) { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(obj)); }
function reqIp(req) { return normalizeRequestIp((req.socket.remoteAddress || '').toString()); }

function serveStatic(req, res) {
  let rel = decodeURIComponent(req.url.split('?')[0]);
  if (rel === '/' || rel === '') rel = '/index.html';
  const full = path.join(PUBLIC_DIR, path.normalize(rel));
  if (!full.startsWith(PUBLIC_DIR)) { res.writeHead(403); return res.end('forbidden'); }
  fs.readFile(full, (err, data) => {
    if (err) { res.writeHead(404, { 'Content-Type': 'text/plain' }); return res.end('not found'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(full).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // GET /access-check — always 200, gate v poli `allowed` (jako firewall.ts)
  if (url === '/access-check') {
    return sendJson(res, 200, { ip: reqIp(req), allowed: isIpAllowed((req.socket.remoteAddress || '').toString()) });
  }
  if (url === '/firewall/domain-profile') {
    return getDomainProfileStatus().then((r) => sendJson(res, 200, r));
  }
  if (url === '/firewall/whitelist' && req.method === 'GET') {
    return getAllowedIPs()
      .then((ips) => sendJson(res, 200, { ips, appLayerCache: getCurrentWhitelist() }))
      .catch((err) => sendJson(res, 500, { error: String(err) }));
  }
  if (url === '/firewall/whitelist' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body || '{}');
        const ips = Array.isArray(parsed.ips) ? parsed.ips.map(String).map((s) => s.trim()).filter(Boolean) : [];
        if (ips.length === 0) throw new Error('ips must be a non-empty array');
        await setAllowedIPs(ips);
        await refreshIpGuard('update');
        sendJson(res, 200, { ips, appLayerCache: getCurrentWhitelist() });
      } catch (err) {
        sendJson(res, 500, { error: String(err.message || err) });
      }
    });
    return;
  }
  // GET /activity — in-memory aktivita služby (refresh, whitelist, boot) — nejnovější první.
  if (url === '/activity' && req.method === 'GET') {
    return sendJson(res, 200, { activity: ACTIVITY.slice().reverse() });
  }

  // GET /logs — tail posledního denního import logu (čte přes PowerShell kvůli kódování).
  if (url.split('?')[0] === '/logs' && req.method === 'GET') {
    const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$f = Get-ChildItem '${LOG_DIR}' -Filter 'bct-daily-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($f) { [pscustomobject]@{ file=$f.Name; text=((Get-Content $f.FullName -Tail 400) -join "\`n") } | ConvertTo-Json -Compress }
else { '{"file":null,"text":""}' }
`;
    return runPs(ps)
      .then((o) => { const j = JSON.parse(o || '{}'); sendJson(res, 200, j); })
      .catch((e) => sendJson(res, 500, { error: String(e.message || e) }));
  }

  // GET/PUT /usermap — mapování pseudonymní GUID → reálné jméno (soubor usermap.json).
  if (url === '/usermap' && req.method === 'GET') {
    return fs.readFile(USERMAP_FILE, 'utf8', (err, data) => {
      if (err) return sendJson(res, 200, {});
      try { sendJson(res, 200, JSON.parse(data)); } catch { sendJson(res, 200, {}); }
    });
  }
  if (url === '/usermap' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
    req.on('end', () => {
      try {
        const obj = JSON.parse(body || '{}');
        if (typeof obj !== 'object' || Array.isArray(obj)) throw new Error('expected object');
        const clean = {};
        for (const k of Object.keys(obj)) { const v = obj[k]; if (typeof v === 'string' && v.trim()) clean[k] = String(v).trim().slice(0, 120); }
        fs.writeFileSync(USERMAP_FILE, JSON.stringify(clean, null, 2), 'utf8');
        logActivity('success', 'usermap', `uloženo ${Object.keys(clean).length} jmen`);
        sendJson(res, 200, { ok: true, count: Object.keys(clean).length });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }

  // GET/PUT /changelog-companies — výběr firem pro modul B (Audit změn). Soubor: changelog-companies.json
  //   { all:[...vsechny firmy z importu...], enabled:[...vybrane...] | null (=vse, default) }
  if (url === '/changelog-companies' && req.method === 'GET') {
    return fs.readFile(CHANGELOG_COMPANIES_FILE, 'utf8', (err, data) => {
      if (err) return sendJson(res, 200, { all: [], enabled: null });
      try { const o = JSON.parse(data); sendJson(res, 200, { all: Array.isArray(o.all) ? o.all : [], enabled: Array.isArray(o.enabled) ? o.enabled : null }); }
      catch { sendJson(res, 200, { all: [], enabled: null }); }
    });
  }
  if (url === '/changelog-companies' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
    req.on('end', () => {
      try {
        const obj = JSON.parse(body || '{}');
        if (!Array.isArray(obj.enabled)) throw new Error('expected { enabled: [] }');
        const enabled = obj.enabled.filter((x) => typeof x === 'string' && x.trim()).map((x) => x.trim());
        let cur = {}; try { cur = JSON.parse(fs.readFileSync(CHANGELOG_COMPANIES_FILE, 'utf8')); } catch { }
        const out = { all: Array.isArray(cur.all) ? cur.all : [], enabled };
        fs.writeFileSync(CHANGELOG_COMPANIES_FILE, JSON.stringify(out, null, 2), 'utf8');
        logActivity('success', 'changelog-companies', `uloženo ${enabled.length} firem`);
        sendJson(res, 200, { ok: true, count: enabled.length });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }

  // POST /changelog-purge — požadavek na smazání audit záznamů (modul B) vybraných firem.
  //   Web (LocalSystem) na SQL nesahá — zapíše ops-request a kopne do denní úlohy (svc),
  //   ta v purge-only režimu provede DELETE + snapshot a request uklidí. UI pak polluje /ops-status.
  if (url === '/changelog-purge' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
    req.on('end', async () => {
      try {
        const obj = JSON.parse(body || '{}');
        let companies = Array.isArray(obj.companies)
          ? obj.companies.filter((x) => typeof x === 'string' && x.trim()).map((x) => x.trim()) : [];
        companies = [...new Set(companies)];
        if (!companies.length) throw new Error('companies must be a non-empty array');
        // bezpečnostní filtr: povol jen firmy známé z changelog-companies.json (pokud je seznam k dispozici)
        try {
          const cfg = JSON.parse(fs.readFileSync(CHANGELOG_COMPANIES_FILE, 'utf8'));
          if (Array.isArray(cfg.all) && cfg.all.length) {
            const known = new Set(cfg.all);
            const bad = companies.filter((c) => !known.has(c));
            if (bad.length) throw new Error(`neznámé firmy: ${bad.join(', ')}`);
          }
        } catch (e) { if (/neznámé firmy/.test(String(e.message))) throw e; }
        ensureOpsDir();
        const reqObj = { action: 'purge', companies, requestedAt: new Date().toISOString() };
        fs.writeFileSync(OPS_REQUEST_FILE, JSON.stringify(reqObj, null, 2), 'utf8');
        // smaž starý status, ať UI nepoll-ne na předchozí výsledek
        try { fs.unlinkSync(OPS_STATUS_FILE); } catch { }
        const ps = `
$t = Get-ScheduledTask -TaskName 'BC_Telemetry_Daily' -ErrorAction Stop
if ($t.State -eq 'Running') { 'running' } else { Start-ScheduledTask -TaskName 'BC_Telemetry_Daily'; 'started' }
`;
        const o = (await runPs(ps)).trim();
        logActivity('info', 'changelog-purge', `purge naplánován pro ${companies.length} firem (${o}): ${companies.join(', ')}`);
        sendJson(res, 200, { status: o, queued: o === 'running', companies });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }
  // GET /tasks — stav naplánovaných úloh BC_Telemetry* (state / poslední / příští běh).
  if (url === '/tasks' && req.method === 'GET') {
    const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ts = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'BC_Telemetry*' }
$out = @(foreach ($t in $ts) {
  $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
  $lr = $null; if ($i -and $i.LastRunTime) { $lr = $i.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
  $nr = $null; if ($i -and $i.NextRunTime) { $nr = $i.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
  [pscustomobject]@{ name=$t.TaskName; state="$($t.State)"; last=$lr; next=$nr; result=("0x{0:X}" -f [int]$i.LastTaskResult) }
})
$out | ConvertTo-Json -Compress -Depth 3
`;
    return runPs(ps)
      .then((o) => { let j = []; try { j = JSON.parse(o || '[]'); if (!Array.isArray(j)) j = [j]; } catch { } sendJson(res, 200, { tasks: j }); })
      .catch((e) => sendJson(res, 500, { error: String(e.message || e) }));
  }
  // POST /import-stop — zastaví běžící (i zaseknutý) import (úloha BC_Telemetry_Daily).
  if (url === '/import-stop' && req.method === 'POST') {
    const ps = `Stop-ScheduledTask -TaskName 'BC_Telemetry_Daily' -ErrorAction Stop; 'stopped'`;
    return runPs(ps)
      .then((o) => { logActivity('warn', 'import-stop', `import zastaven z ${reqIp(req)}`); sendJson(res, 200, { status: o.trim() }); })
      .catch((e) => sendJson(res, 500, { error: String(e.message || e) }));
  }
  // POST /restart — restart web služby: proces skončí, NSSM ji nahodí znovu (s novým server.js).
  if (url === '/restart' && req.method === 'POST') {
    logActivity('warn', 'restart', `restart služby vyžádán z ${reqIp(req)}`);
    sendJson(res, 200, { status: 'restarting' });
    setTimeout(() => process.exit(0), 600);
    return;
  }
  // GET/PUT /retention — retenční politika (soubor retention.json, čtou ji importní skripty).
  if (url === '/retention' && req.method === 'GET') {
    let r = { ...RETENTION_DEFAULTS };
    try { const o = JSON.parse(fs.readFileSync(RETENTION_FILE, 'utf8')); for (const k of Object.keys(RETENTION_DEFAULTS)) if (Number.isFinite(+o[k])) r[k] = +o[k]; } catch { }
    return sendJson(res, 200, r);
  }
  if (url === '/retention' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on('end', () => {
      try {
        const o = JSON.parse(body || '{}'); const out = {};
        for (const k of Object.keys(RETENTION_DEFAULTS)) {
          const v = Math.round(+o[k]);
          if (!Number.isFinite(v) || v < 1 || v > 1200) throw new Error(`neplatná hodnota pro ${k}`);
          out[k] = v;
        }
        ensureOpsDir();
        fs.writeFileSync(RETENTION_FILE, JSON.stringify(out, null, 2), 'utf8');
        logActivity('success', 'retention', `retence uložena z ${reqIp(req)}: ${JSON.stringify(out)}`);
        sendJson(res, 200, { ok: true, ...out });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }

  // GET/PUT /snapshot-config — strop řádků na sekci (audit/aktivita/RT0031) ve snapshotu.
  // Web jen zapíše JSON; projeví se po nejbližší obnově (Export-DashboardSnapshot.ps1 ho čte).
  if (url === '/snapshot-config' && req.method === 'GET') {
    let r = { ...SNAPSHOT_DEFAULTS };
    try { const o = JSON.parse(fs.readFileSync(SNAPSHOT_FILE, 'utf8')); if (Number.isFinite(+o.topRows)) r.topRows = +o.topRows; } catch { }
    return sendJson(res, 200, r);
  }
  if (url === '/snapshot-config' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on('end', () => {
      try {
        const o = JSON.parse(body || '{}');
        const v = Math.round(+o.topRows);
        if (!Number.isFinite(v) || v < 100 || v > 1000000) throw new Error('topRows musí být 100–1000000');
        ensureOpsDir();
        fs.writeFileSync(SNAPSHOT_FILE, JSON.stringify({ topRows: v }, null, 2), 'utf8');
        logActivity('success', 'snapshot-config', `strop řádků = ${v} (z ${reqIp(req)})`);
        sendJson(res, 200, { ok: true, topRows: v });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }

  // GET/PUT /pagemap — mapování PageID → zdrojová tabulka (pro „čtení tabulek" odvozené ze stránek).
  // PUT přijme nalepený text z BC „Page Metadata" (ID / SourceTable / [SourceTableName]); odděleno TAB/;/,.
  if (url === '/pagemap' && req.method === 'GET') {
    let count = 0;
    try { const m = JSON.parse(fs.readFileSync(PAGEMAP_FILE, 'utf8')); count = Object.keys(m || {}).length; } catch { }
    return sendJson(res, 200, { count });
  }
  if (url === '/pagemap' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 8e6) req.destroy(); });
    req.on('end', () => {
      try {
        let txt = body;
        try { const j = JSON.parse(body); if (j && typeof j.text === 'string') txt = j.text; } catch { }
        const map = {};
        for (const raw of String(txt).split(/\r?\n/)) {
          const line = raw.trim(); if (!line) continue;
          const cols = line.split(/[\t;,]/).map((s) => s.trim());
          const pid = (cols[0] || '').replace(/\D/g, '');
          const tno = (cols[1] || '').replace(/\D/g, '');
          if (!pid || !tno) continue;            // přeskoč hlavičku / prázdné
          map[pid] = { t: +tno, n: (cols[2] || '').slice(0, 200) };
        }
        if (Object.keys(map).length === 0) throw new Error('nenačten žádný řádek „PageID<tab>SourceTable[<tab>Název]"');
        ensureOpsDir();
        fs.writeFileSync(PAGEMAP_FILE, JSON.stringify(map), 'utf8');
        logActivity('success', 'pagemap', `mapování stránek uloženo z ${reqIp(req)}: ${Object.keys(map).length} stránek`);
        sendJson(res, 200, { ok: true, count: Object.keys(map).length });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }

  // GET/PUT /notify-config — e-mailové notifikace (ops/notify.json, čte Send-BCTelemetryNotification.ps1).
  if (url === '/notify-config' && req.method === 'GET') {
    let r = { ...NOTIFY_DEFAULTS };
    try { const o = JSON.parse(fs.readFileSync(NOTIFY_FILE, 'utf8')); r = { ...r, ...o }; } catch { }
    if (!Array.isArray(r.recipients)) r.recipients = NOTIFY_DEFAULTS.recipients;
    return sendJson(res, 200, r);
  }
  if (url === '/notify-config' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on('end', () => {
      try {
        const o = JSON.parse(body || '{}');
        const recips = (Array.isArray(o.recipients) ? o.recipients : String(o.recipients || '').split(/[\s,;]+/))
          .map((s) => String(s).trim()).filter(Boolean);
        for (const a of recips) if (!/@axima\.cz$/i.test(a)) throw new Error(`příjemce musí být @axima.cz: ${a}`);
        if (!/@axima\.cz$/i.test(String(o.from || ''))) throw new Error('odesílatel (From) musí být @axima.cz');
        const cadence = ['daily', 'everyNDays', 'perRun', 'onChange'].includes(o.cadence) ? o.cadence : 'daily';
        const cadenceDays = Math.round(+o.cadenceDays); if (!Number.isFinite(cadenceDays) || cadenceDays < 1 || cadenceDays > 365) throw new Error('cadenceDays 1–365');
        const port = Math.round(+o.smtpPort); if (!Number.isFinite(port) || port < 1 || port > 65535) throw new Error('neplatný SMTP port');
        const staleHours = Math.round(+o.staleHours); if (!Number.isFinite(staleHours) || staleHours < 1 || staleHours > 8760) throw new Error('staleHours 1–8760');
        const secretWarnDays = Math.round(+o.secretWarnDays); if (!Number.isFinite(secretWarnDays) || secretWarnDays < 1 || secretWarnDays > 3650) throw new Error('secretWarnDays 1–3650');
        const out = {
          enabled: !!o.enabled,
          smtpHost: String(o.smtpHost || NOTIFY_DEFAULTS.smtpHost).trim(),
          smtpPort: port,
          from: String(o.from).trim(),
          recipients: recips.length ? recips : NOTIFY_DEFAULTS.recipients,
          cadence,
          cadenceDays,
          dashboardUrl: String(o.dashboardUrl || NOTIFY_DEFAULTS.dashboardUrl).trim(),
          alertImportFail: !!o.alertImportFail,
          alertStaleModule: !!o.alertStaleModule,
          alertSecretExpiry: !!o.alertSecretExpiry,
          staleHours,
          secretExpiry: /^\d{4}-\d{2}-\d{2}$/.test(String(o.secretExpiry || '')) ? o.secretExpiry : NOTIFY_DEFAULTS.secretExpiry,
          secretWarnDays,
        };
        ensureOpsDir();
        fs.writeFileSync(NOTIFY_FILE, JSON.stringify(out, null, 2), 'utf8');
        logActivity('success', 'notify-config', `notifikace uloženy z ${reqIp(req)}: enabled=${out.enabled} cadence=${out.cadence} → ${out.recipients.join(',')}`);
        sendJson(res, 200, { ok: true, ...out });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }
  // POST /notify-test — pošle testovací e-mail HNED (Send-BCTelemetryNotification.ps1 -Manual) podle uložené konfigurace.
  if (url === '/notify-test' && req.method === 'POST') {
    const script = path.join(SCRIPTS_DIR, 'Send-BCTelemetryNotification.ps1');
    const cmd = `& '${script.replace(/'/g, "''")}' -Manual`;
    return runPs(cmd)
      .then((o) => { logActivity('info', 'notify-test', `test e-mail z ${reqIp(req)}: ${(o || '').replace(/\s+/g, ' ').slice(0, 200)}`); sendJson(res, 200, { ok: true, output: (o || '').trim() }); })
      .catch((e) => { logActivity('error', 'notify-test', `test e-mail selhal: ${e.message || e}`); sendJson(res, 500, { error: String(e.message || e) }); });
  }

  // GET/PUT /schedule — okno a četnost běhu úlohy BC_Telemetry_Daily (opakování v okně).
  if (url === '/schedule' && req.method === 'GET') {
    let s = { startTime: '02:00', endTime: '06:00', intervalMinutes: 0, days: [0, 1, 2, 3, 4, 5, 6] };
    try { const o = JSON.parse(fs.readFileSync(SCHEDULE_FILE, 'utf8')); s = { ...s, ...o }; } catch { }
    if (!Array.isArray(s.days) || !s.days.length) s.days = [0, 1, 2, 3, 4, 5, 6];
    return sendJson(res, 200, s);
  }
  if (url === '/schedule' && req.method === 'PUT') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on('end', async () => {
      try {
        const o = JSON.parse(body || '{}');
        const rx = /^(\d{1,2}):(\d{2})$/;
        const ms = rx.exec(String(o.startTime || '')), me = rx.exec(String(o.endTime || ''));
        if (!ms || !me) throw new Error('čas musí být ve formátu HH:MM');
        const sh = +ms[1], sm = +ms[2], eh = +me[1], em = +me[2];
        if (sh > 23 || sm > 59 || eh > 23 || em > 59) throw new Error('neplatný čas');
        let iv = Math.round(+o.intervalMinutes || 0);
        if (iv < 0 || iv > 1440) throw new Error('interval 0–1440 min');
        let days = Array.isArray(o.days) ? o.days.map(Number).filter((d) => Number.isInteger(d) && d >= 0 && d <= 6) : [];
        days = [...new Set(days)].sort((a, b) => a - b);
        if (!days.length) days = [0, 1, 2, 3, 4, 5, 6];
        // Jen uložíme config — opakování v okně řídí wrapper (Invoke-BCTelemetryDaily.ps1),
        // NE OS úloha: její trigger nejde z LocalSystem měnit bez hesla svc (0x8007052e / prompt).
        ensureOpsDir();
        const saved = { startTime: `${String(sh).padStart(2, '0')}:${String(sm).padStart(2, '0')}`, endTime: `${String(eh).padStart(2, '0')}:${String(em).padStart(2, '0')}`, intervalMinutes: iv, days };
        fs.writeFileSync(SCHEDULE_FILE, JSON.stringify(saved, null, 2), 'utf8');
        logActivity('success', 'schedule', `plán úlohy: ${saved.startTime}–${saved.endTime} á ${iv} min (z ${reqIp(req)})`);
        // Když je Od už v minulosti a jsme uvnitř okna → spustit import hned (windowed; wrapper pak loopuje do Do).
        const now = new Date(); const nowMin = now.getHours() * 60 + now.getMinutes();
        const startMin = sh * 60 + sm, endMin = eh * 60 + em;
        let triggered = false;
        if (days.includes(now.getDay()) && nowMin >= startMin && (iv === 0 || nowMin < endMin)) {
          triggered = true;
          runPs(`$t=Get-ScheduledTask -TaskName 'BC_Telemetry_Daily' -ErrorAction Stop; if($t.State -ne 'Running'){ Start-ScheduledTask -TaskName 'BC_Telemetry_Daily' }; 'ok'`)
            .then(() => logActivity('info', 'schedule', 'okno aktivní → import spuštěn hned'))
            .catch((e) => logActivity('error', 'schedule', 'auto-start selhal: ' + (e.message || e)));
        }
        sendJson(res, 200, { ok: true, ...saved, triggered });
      } catch (e) { sendJson(res, 500, { error: String(e.message || e) }); }
    });
    return;
  }

  // GET /ops-status — výsledek poslední ops operace (purge) + jestli ještě čeká požadavek.
  if (url === '/ops-status' && req.method === 'GET') {
    let status = null, pending = false;
    try { status = JSON.parse(fs.readFileSync(OPS_STATUS_FILE, 'utf8')); } catch { }
    try { pending = fs.existsSync(OPS_REQUEST_FILE); } catch { }
    return sendJson(res, 200, { status, pending });
  }

  // GET /logfiles — seznam log souborů v obou složkách (pro ověření retence v Nastavení).
  if (url === '/logfiles' && req.method === 'GET') {
    const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($p){ ,@(Get-ChildItem $p -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { [pscustomobject]@{ name=$_.Name; kb=[math]::Round($_.Length/1KB,1); modified=$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } }) }
[pscustomobject]@{ dailyDir='${LOG_DIR}'; serviceDir='C:\\Apps\\BC_Telemetry_Web\\logs'; daily=(L '${LOG_DIR}'); service=(L 'C:\\Apps\\BC_Telemetry_Web\\logs') } | ConvertTo-Json -Depth 4
`;
    return runPs(ps)
      .then((o) => sendJson(res, 200, JSON.parse(o || '{}')))
      .catch((e) => sendJson(res, 500, { error: String(e.message || e) }));
  }

  // POST /refresh — vynutí denní běh (import 3 modulů + snapshot). Task běží jako svc;
  // službu (LocalSystem) jen spustí task. Když už běží, vrátí 'running' (nezdvojí).
  if (url === '/refresh' && req.method === 'POST') {
    ensureOpsDir();
    const flag = path.join(OPS_DIR, 'oneshot.flag');
    const ps = `
$t = Get-ScheduledTask -TaskName 'BC_Telemetry_Daily' -ErrorAction Stop
if ($t.State -eq 'Running') { 'running' } else { Set-Content -Path '${flag.replace(/\\/g, '\\\\')}' -Value '1' -Force; Start-ScheduledTask -TaskName 'BC_Telemetry_Daily'; 'started' }
`;
    return runPs(ps)
      .then((o) => { logActivity('info', 'refresh', `manual refresh: ${o.trim()}`); sendJson(res, 200, { status: o.trim() }); })
      .catch((e) => sendJson(res, 500, { error: String(e.message || e) }));
  }
  if (url.startsWith('/firewall/') || url.startsWith('/api/') || url === '/refresh' || url === '/activity' || url === '/logs' || url === '/logfiles' || url === '/usermap' || url === '/changelog-companies' || url === '/changelog-purge' || url === '/ops-status' || url === '/import-stop' || url === '/restart' || url === '/retention' || url === '/tasks' || url === '/schedule' || url === '/snapshot-config' || url === '/notify-config' || url === '/notify-test' || url === '/pagemap') return sendJson(res, 404, { error: 'unknown endpoint' });
  return serveStatic(req, res);
});

server.listen(PORT, () => {
  console.log(`BC_Telemetry web na :${PORT}, public=${PUBLIC_DIR}, rule="${RULE_DISPLAY_NAME}"`);
  logActivity('info', 'boot', `služba nastartována na :${PORT}`);
  ensureOpsDir();
  refreshIpGuard('boot');
});
