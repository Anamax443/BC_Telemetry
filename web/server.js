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

function logActivity(level, scope, msg) { console.log(`[${level}] ${scope}: ${msg}`); }

// ── PowerShell helper (inline -Command, AllSigned-safe) ──────────────────────
function runPs(script) {
  return new Promise((resolve, reject) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script],
      { windowsHide: true, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
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
  // Validate input — single IP, CIDR mask (x.x.x.x/n) nebo rozsah (x.x.x.x-y.y.y.y).
  // (Set-NetFirewallRule -RemoteAddress umí všechny tři formy; pomlčka = rozsah.)
  for (const ip of ips) {
    if (!/^[\d.:a-fA-F/-]+$/.test(ip)) {
      throw new Error(`Invalid IP/CIDR/range: ${ip}`);
    }
  }
  if (ips.length === 0) {
    throw new Error('At least one allowed IP required (otherwise nobody can reach the API)');
  }
  const jsonArray = JSON.stringify(ips);
  const ps = `
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ips = '${jsonArray.replace(/'/g, "''")}' | ConvertFrom-Json
Set-NetFirewallRule -DisplayName '${RULE_DISPLAY_NAME}' -RemoteAddress $ips -ErrorAction Stop
'OK'
`;
  const out = await runPs(ps);
  if (out !== 'OK') throw new Error(`unexpected output: ${out}`);
  logActivity('success', 'firewall', `Whitelist updated: ${ips.join(', ')}`);
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
  if (entry === remoteIp) return true;
  // CIDR maska: x.x.x.x/n
  if (entry.includes('/')) {
    const [base, bitsStr] = entry.split('/');
    const bits = Number(bitsStr);
    if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false;
    const baseInt = ipv4ToInt(base ?? '');
    const ipInt = ipv4ToInt(remoteIp);
    if (baseInt === null || ipInt === null) return false;
    if (bits === 0) return true;
    const mask = bits === 32 ? 0xFFFFFFFF : (0xFFFFFFFF << (32 - bits)) >>> 0;
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
  if (url.startsWith('/firewall/') || url.startsWith('/api/')) return sendJson(res, 404, { error: 'unknown endpoint' });
  return serveStatic(req, res);
});

server.listen(PORT, () => {
  console.log(`BC_Telemetry web na :${PORT}, public=${PUBLIC_DIR}, rule="${RULE_DISPLAY_NAME}"`);
  refreshIpGuard('boot');
});
