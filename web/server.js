'use strict';
/*
 * BC_Telemetry — minimální web servis (bez závislostí).
 * Servíruje statický dashboard + data.json a poskytuje whitelist API,
 * stejný model jako ITDashboard: source of truth je pojmenovaná Windows
 * Firewall rule, kterou čteme/zapisujeme přes `powershell -Command`
 * (inline -Command NEpodléhá GPO ExecutionPolicy=AllSigned, na rozdíl od .ps1).
 *
 * Whitelist je VISIBILITY / formální gate, ne security boundary — pokud je
 * Domain firewall profil vyplý, je rule inertní a omezení čistě evidenční.
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
const RULE = 'BC Telemetry Dashboard (8080)';
const ALWAYS_ALLOW = new Set(['127.0.0.1', '::1']);

const MIME = { '.html': 'text/html; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.ico': 'image/x-icon' };

// ── PowerShell helper (inline -Command, AllSigned-safe) ──────────────────────
function ps(script) {
  return new Promise((resolve, reject) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script],
      { windowsHide: true, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
        if (err) return reject(new Error((stderr || err.message || '').toString().split('\n')[0]));
        resolve(stdout.toString().trim());
      });
  });
}

async function getAllowedIPs() {
  const out = await ps(
    `$OutputEncoding=[Text.Encoding]::UTF8;[Console]::OutputEncoding=[Text.Encoding]::UTF8;` +
    `$a=(Get-NetFirewallRule -DisplayName '${RULE}' -ErrorAction Stop|Get-NetFirewallAddressFilter).RemoteAddress;` +
    `if($a -is [string]){$a=@($a)};$a|ConvertTo-Json -Compress`);
  if (!out) return [];
  const parsed = JSON.parse(out);
  return Array.isArray(parsed) ? parsed : [parsed];
}

async function setAllowedIPs(ips) {
  for (const ip of ips) {
    if (!/^[\d.:a-fA-F/-]+$/.test(ip)) throw new Error(`Neplatná IP/CIDR: ${ip}`);
  }
  if (ips.length === 0) throw new Error('Aspoň jedna IP musí zůstat (jinak nikdo neuvidí stránku).');
  const json = JSON.stringify(ips).replace(/'/g, "''");
  const out = await ps(
    `$ips='${json}'|ConvertFrom-Json;` +
    `$r=Get-NetFirewallRule -DisplayName '${RULE}' -ErrorAction SilentlyContinue;` +
    `if($r){Set-NetFirewallRule -DisplayName '${RULE}' -RemoteAddress $ips -ErrorAction Stop}` +
    `else{New-NetFirewallRule -DisplayName '${RULE}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort ${PORT} -RemoteAddress $ips -Profile Domain|Out-Null};'OK'`);
  if (out !== 'OK') throw new Error(`Neočekávaný výstup: ${out}`);
}

async function getDomainProfile() {
  try {
    const out = await ps(`$p=Get-NetFirewallProfile -Profile Domain -ErrorAction Stop;` +
      `[pscustomobject]@{Enabled=[bool]$p.Enabled;DefaultInboundAction="$($p.DefaultInboundAction)"}|ConvertTo-Json -Compress`);
    const p = JSON.parse(out);
    return { enabled: p.Enabled, defaultInboundAction: p.DefaultInboundAction || null };
  } catch (e) {
    return { enabled: null, defaultInboundAction: null, error: String(e.message || e).slice(0, 200) };
  }
}

// ── IP match (port ITDashboard ip-guard, rozšířeno o /mask) ───────────────────
function ipv4ToInt(ip) {
  const p = ip.split('.');
  if (p.length !== 4) return null;
  let n = 0;
  for (const x of p) { const v = Number(x); if (!Number.isInteger(v) || v < 0 || v > 255) return null; n = n * 256 + v; }
  return n >>> 0;
}
function normIp(raw) { return raw && raw.startsWith('::ffff:') ? raw.slice(7) : raw; }
function maskToBits(mask) { const n = ipv4ToInt(mask); if (n === null) return null; let b = 0, m = n; while (m & 0x80000000) { b++; m = (m << 1) >>> 0; } return ((0xFFFFFFFF << (32 - b)) >>> 0) === n ? b : null; }
function matchesEntry(ip, entry) {
  if (!entry || entry.toLowerCase() === 'any') return true;
  if (entry === ip) return true;
  if (entry.includes('-')) { // range a-b
    const [a, b] = entry.split('-'); const ai = ipv4ToInt(a), bi = ipv4ToInt(b), xi = ipv4ToInt(ip);
    return ai !== null && bi !== null && xi !== null && xi >= ai && xi <= bi;
  }
  if (entry.includes('/')) {
    const [base, suf] = entry.split('/');
    const bits = /\./.test(suf) ? maskToBits(suf) : Number(suf);
    if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false;
    const bi = ipv4ToInt(base), xi = ipv4ToInt(ip);
    if (bi === null || xi === null) return false;
    if (bits === 0) return true;
    const m = bits === 32 ? 0xFFFFFFFF : (0xFFFFFFFF << (32 - bits)) >>> 0;
    return (bi & m) === (xi & m);
  }
  return false;
}
function isAllowed(ip, list) {
  const n = normIp(ip);
  if (ALWAYS_ALLOW.has(n)) return true;
  return list.some((e) => matchesEntry(n, e));
}

// ── HTTP ─────────────────────────────────────────────────────────────────────
function sendJson(res, code, obj) { const b = JSON.stringify(obj); res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(b); }
function clientIp(req) { return normIp((req.socket.remoteAddress || '').toString()); }

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

const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];
  try {
    if (url === '/api/access-check') {
      const list = await getAllowedIPs().catch(() => []);
      return sendJson(res, 200, { ip: clientIp(req), allowed: isAllowed(clientIp(req), list) });
    }
    if (url === '/api/whitelist' && req.method === 'GET') {
      const [ips, domainProfile] = await Promise.all([getAllowedIPs(), getDomainProfile()]);
      return sendJson(res, 200, { ips, domainProfile });
    }
    if (url === '/api/whitelist' && req.method === 'PUT') {
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
      req.on('end', async () => {
        try {
          const parsed = JSON.parse(body || '{}');
          const ips = Array.isArray(parsed.ips) ? parsed.ips.map(String).map((s) => s.trim()).filter(Boolean) : [];
          await setAllowedIPs(ips);
          sendJson(res, 200, { ips });
        } catch (e) { sendJson(res, 400, { error: String(e.message || e) }); }
      });
      return;
    }
    if (url.startsWith('/api/')) return sendJson(res, 404, { error: 'unknown endpoint' });
    return serveStatic(req, res);
  } catch (e) {
    sendJson(res, 500, { error: String(e.message || e) });
  }
});

server.listen(PORT, () => console.log(`BC_Telemetry web na :${PORT}, public=${PUBLIC_DIR}, rule="${RULE}"`));
