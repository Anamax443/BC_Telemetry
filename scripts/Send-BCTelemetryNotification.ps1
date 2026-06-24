<#
.SYNOPSIS
    Notifikace o stavu BC_Telemetry — e-mail přes Microsoft 365 Direct Send.

.DESCRIPTION
    Volá se z wrapperu (Invoke-BCTelemetryDaily.ps1) po snapshotu, jako svc.
    Stav čte z data.json (KPI / sync / velikost DB / čerstvost modulů) a z denního
    logu (exit kódy importů, "Import ROLLBACK"). Alerty:
      - selhání importu (exit≠0 nebo ROLLBACK v logu)
      - zastaralý modul A/B (nejnovější záznam starší než staleHours)
      - blížící se expirace SP secretu (secretExpiry − dnes ≤ secretWarnDays)
    Pozn.: sync ukazuje ~5 % ZÁMĚRNĚ (cloud drží vše, lokál jen výřez dle retence),
    proto se NEhlídá total %, ale ČERSTVOST (lag nejnovějšího záznamu).

    Odesílá M365 Direct Send (host axima-cz.mail.protection.outlook.com:25, STARTTLS,
    bez auth, From @axima.cz, příjemci jen vlastní doména). Konfigurace ops/notify.json
    (PUT /notify-config z dashboardu). Stav last-sent/last-status v ops/notify-state.json.

    Předmět: "[OK]|[CHYBA] [RUČNĚ?] BC Telemetrie — stav YYYY-MM-DD" (mailové pravidlo).

.NOTES
    Uložit jako UTF-8 s BOM (Windows PowerShell 5.1 jinak čte CP1250 → parse error).
#>
[CmdletBinding()]
param(
    [string] $WebDir   = 'C:\Apps\BC_Telemetry_Web',
    [string] $DataJson = 'C:\Apps\BC_Telemetry_Web\public\data.json',
    [string] $LogDir   = 'C:\Apps\BC_Telemetry\logs',
    [string] $LogFile  = '',                 # když prázdné → dnešní bct-daily-*.log
    [switch] $Manual                          # ruční test z dashboardu (vždy pošle, [RUČNĚ])
)
$ErrorActionPreference = 'Continue'

$NOTIFY_DEFAULTS = [ordered]@{
    enabled           = $false
    smtpHost          = 'axima-cz.mail.protection.outlook.com'
    smtpPort          = 25
    from              = 'bc-telemetry@axima.cz'
    recipients        = @('mtrnka@axima.cz')
    cadence           = 'daily'              # daily | perRun | onChange
    dashboardUrl      = 'http://10.8.2.225:8080/'
    alertImportFail   = $true
    alertStaleModule  = $true
    alertSecretExpiry = $true
    staleHours        = 24
    secretExpiry      = '2028-06-07'
    secretWarnDays    = 30
}

function Read-Notify {
    $f = Join-Path $WebDir 'ops\notify.json'
    $cfg = [ordered]@{}; foreach ($k in $NOTIFY_DEFAULTS.Keys) { $cfg[$k] = $NOTIFY_DEFAULTS[$k] }
    if (Test-Path $f) {
        try {
            $o = Get-Content -Raw $f | ConvertFrom-Json
            foreach ($k in $NOTIFY_DEFAULTS.Keys) {
                if ($null -ne $o.$k) { $cfg[$k] = $o.$k }
            }
        } catch {}
    }
    return $cfg
}

function Get-NewestDate([object[]]$rows, [string]$field) {
    $max = $null
    foreach ($r in $rows) {
        $v = $r.$field; if (-not $v) { continue }
        try { $d = [datetime]::Parse($v) } catch { continue }
        if ($null -eq $max -or $d -gt $max) { $max = $d }
    }
    return $max
}

# ── Posbírej stav ────────────────────────────────────────────────────────────
$cfg = Read-Notify
if (-not $Manual -and -not $cfg.enabled) { return }

$now = Get-Date
$problems = New-Object System.Collections.Generic.List[string]
$warns    = New-Object System.Collections.Generic.List[string]

# data.json
$data = $null
try { if (Test-Path $DataJson) { $data = Get-Content -Raw $DataJson | ConvertFrom-Json } } catch {}

# Dnešní log (exit kódy + ROLLBACK)
if (-not $LogFile) { $LogFile = Join-Path $LogDir ('bct-daily-' + $now.ToString('yyyyMMdd') + '.log') }
$logTxt = ''
if (Test-Path $LogFile) { try { $logTxt = Get-Content -Raw $LogFile } catch {} }

if ($cfg.alertImportFail -and $logTxt) {
    $bad = @([regex]::Matches($logTxt, '(?im)\bexit=(\d+)') | Where-Object { [int]$_.Groups[1].Value -ne 0 })
    if ($bad.Count -gt 0)               { $problems.Add("Import skončil s chybou (exit≠0) — viz $([IO.Path]::GetFileName($LogFile)).") }
    if ($logTxt -match '(?i)Import ROLLBACK') { $problems.Add('Detekován Import ROLLBACK (zamrzlý watermark modulu).') }
}

# Čerstvost modulů (lag nejnovějšího záznamu)
if ($cfg.alertStaleModule -and $data) {
    $aNewest = Get-NewestDate $data.userActivity 'LastUsed'
    $bNewest = Get-NewestDate $data.changeLog    'ChangedAt'
    foreach ($m in @(@{n='A · Využití stránek'; d=$aNewest}, @{n='B · Audit změn'; d=$bNewest})) {
        if ($m.d) {
            $hrs = [math]::Round(($now - $m.d).TotalHours, 1)
            if ($hrs -gt [double]$cfg.staleHours) {
                $problems.Add("Modul $($m.n): poslední záznam před $hrs h (> $($cfg.staleHours) h) — možná zastavený přísun dat.")
            }
        }
    }
}

# Expirace SP secretu
if ($cfg.alertSecretExpiry -and $cfg.secretExpiry) {
    try {
        $exp = [datetime]::Parse($cfg.secretExpiry)
        $daysLeft = [math]::Floor(($exp - $now).TotalDays)
        if ($daysLeft -le [int]$cfg.secretWarnDays) {
            $msg = "SP secret expiruje za $daysLeft dní ($($cfg.secretExpiry)) — obnov v Entra App registraci."
            if ($daysLeft -le 7) { $problems.Add($msg) } else { $warns.Add($msg) }
        }
    } catch {}
}

$hasProblems = $problems.Count -gt 0
$statusKey   = if ($hasProblems) { 'CHYBA' } else { 'OK' }

# ── Rozhodni, zda poslat (cadence + stav) ────────────────────────────────────
$stateFile = Join-Path $WebDir 'ops\notify-state.json'
$state = $null
if (Test-Path $stateFile) { try { $state = Get-Content -Raw $stateFile | ConvertFrom-Json } catch {} }
$today        = $now.ToString('yyyy-MM-dd')
$lastSentDate = if ($state) { [string]$state.lastSentDate } else { '' }
$lastStatus   = if ($state) { [string]$state.lastStatus }   else { '' }
$stateChanged = ($lastStatus -ne $statusKey)

$send = $false
if ($Manual) {
    $send = $true
} else {
    switch ([string]$cfg.cadence) {
        'perRun'   { $send = $true }
        'onChange' { $send = $stateChanged }
        default    { # daily
            if ($lastSentDate -ne $today) { $send = $true }       # denní souhrn 1×/den
            elseif ($hasProblems -and $stateChanged) { $send = $true } # nový problém i v rámci dne
        }
    }
}

if (-not $send) {
    Write-Host "Notifikace: nic se neposílá (cadence=$($cfg.cadence), status=$statusKey, lastSent=$lastSentDate)."
    return
}

# ── Sestav HTML e-mail ───────────────────────────────────────────────────────
$enc = [System.Text.Encoding]::UTF8
function EscH([string]$s) { if ($null -eq $s) { return '' }; ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }

$kpi  = if ($data) { $data.kpi } else { $null }
$gen  = if ($data) { $data.generatedUtc } else { '?' }
$sync = if ($data -and $data.sync) { @($data.sync) } else { @() }
$db   = if ($data) { $data.dbSize } else { $null }
$modName = @{ A = 'Využití stránek'; B = 'Audit změn'; C = 'Permission errors' }

$manualTag = if ($Manual) { '[RUČNĚ] ' } else { '' }
$subject   = '[' + $statusKey + '] ' + $manualTag + "BC Telemetrie — stav $today"

$rowsProblems = if ($hasProblems) {
    '<ul style="margin:6px 0 0 0;padding-left:18px;color:#b00020">' + (($problems | ForEach-Object { '<li>' + (EscH $_) + '</li>' }) -join '') + '</ul>'
} else { '<div style="color:#0a7d33">Bez problémů — vše běží.</div>' }
$rowsWarns = if ($warns.Count -gt 0) {
    '<ul style="margin:6px 0 0 0;padding-left:18px;color:#9a6700">' + (($warns | ForEach-Object { '<li>' + (EscH $_) + '</li>' }) -join '') + '</ul>'
} else { '' }

$kpiHtml = if ($kpi) {
@"
<tr><td>Aktivní uživatelé · 30d</td><td style="text-align:right">$($kpi.ActiveUsers30d)</td></tr>
<tr><td>Použité stránky · 30d</td><td style="text-align:right">$($kpi.DistinctPages30d)</td></tr>
<tr><td>Otevření · 30d</td><td style="text-align:right">$($kpi.Hits30d)</td></tr>
<tr><td>RT0031 chyby · 14d</td><td style="text-align:right">$($kpi.AuthFails14d)</td></tr>
"@
} else { '<tr><td colspan="2">data.json nedostupné</td></tr>' }

$syncHtml = ($sync | ForEach-Object {
    $nm = $modName[[string]$_.Module]; if (-not $nm) { $nm = $_.Module }
    "<tr><td>$nm</td><td style=`"text-align:right`">$($_.LocalCount) / $($_.CloudCount)</td></tr>"
}) -join ''
if (-not $syncHtml) { $syncHtml = '<tr><td colspan="2">—</td></tr>' }

$dbHtml = if ($db) { "$($db.DataUsedMB) MB využito / $($db.DataAllocMB) MB alok." } else { '—' }
$dashUrl = [string]$cfg.dashboardUrl

$body = @"
<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;max-width:640px">
<h2 style="margin:0 0 4px 0">BC Telemetrie — $statusKey</h2>
<div style="color:#666;margin-bottom:12px">snapshot $gen UTC · $today</div>

<h3 style="margin:14px 0 4px 0">Problémy</h3>
$rowsProblems
$rowsWarns

<h3 style="margin:16px 0 4px 0">KPI (30 dní)</h3>
<table style="border-collapse:collapse;width:100%">$kpiHtml</table>

<h3 style="margin:16px 0 4px 0">Synchronizace (SQL / cloud)</h3>
<div style="color:#666;font-size:12px;margin-bottom:4px">Nižší % je v pořádku — cloud drží vše, lokál jen výřez dle retence.</div>
<table style="border-collapse:collapse;width:100%">$syncHtml</table>

<h3 style="margin:16px 0 4px 0">Databáze</h3>
<div>$dbHtml</div>

<p style="margin-top:18px"><a href="$dashUrl" style="background:#2563eb;color:#fff;padding:8px 14px;border-radius:6px;text-decoration:none">Otevřít dashboard</a></p>
<div style="color:#999;font-size:12px;margin-top:16px">Automatická zpráva BC_Telemetry · © Milan Trnka, IT</div>
</body></html>
"@

# ── Odešli (M365 Direct Send) ────────────────────────────────────────────────
$to = @($cfg.recipients) | Where-Object { $_ -and ($_ -match '@axima\.cz\s*$') }
if (-not $to -or $to.Count -eq 0) { Write-Host 'Notifikace: žádný platný příjemce @axima.cz — nic neposláno.'; return }

try {
    Send-MailMessage -SmtpServer $cfg.smtpHost -Port ([int]$cfg.smtpPort) -UseSsl `
        -From $cfg.from -To $to -Subject $subject -Body $body -BodyAsHtml -Encoding $enc -ErrorAction Stop
    Write-Host "Notifikace ODESLÁNA ($statusKey) → $($to -join ', ')  [$subject]"
    # Ulož stav (jen po úspěšném odeslání)
    $st = [ordered]@{ lastSentDate = $today; lastStatus = $statusKey; lastProblems = @($problems); updatedAt = $now.ToString('yyyy-MM-dd HH:mm:ss') }
    try { $st | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding UTF8 -Force } catch {}
} catch {
    Write-Host "Notifikace CHYBA odeslání: $($_.Exception.Message)"
    exit 1
}
