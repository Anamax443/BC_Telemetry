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
            $o = Get-Content -Raw -Encoding UTF8 $f | ConvertFrom-Json
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
try { if (Test-Path $DataJson) { $data = Get-Content -Raw -Encoding UTF8 $DataJson | ConvertFrom-Json } } catch {}

# Dnešní log (exit kódy + ROLLBACK)
if (-not $LogFile) { $LogFile = Join-Path $LogDir ('bct-daily-' + $now.ToString('yyyyMMdd') + '.log') }
$logTxt = ''
if (Test-Path $LogFile) { try { $logTxt = Get-Content -Raw -Encoding UTF8 $LogFile } catch {} }

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
if (Test-Path $stateFile) { try { $state = Get-Content -Raw -Encoding UTF8 $stateFile | ConvertFrom-Json } catch {} }
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

# ── Sestav HTML report (tisknutelná manažerská zpráva) ───────────────────────
$enc = [System.Text.Encoding]::UTF8
function EscH([string]$s) { if ($null -eq $s) { return '' }; ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }
function Fmt($n) { if ($null -eq $n -or "$n" -eq '') { return '—' }; try { ('{0:#,0}' -f [long][math]::Round([double]$n)) -replace ',', ' ' } catch { "$n" } }
$td  = "style='border:1px solid #cbd2dd;padding:4px 8px'"
$tdR = "style='border:1px solid #cbd2dd;padding:4px 8px;text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap'"
$thS = "style='border:1px solid #cbd2dd;padding:4px 8px;background:#f1f3f7;text-align:left;font-size:9px;text-transform:uppercase;color:#555'"
# Pruh = vnořená tabulka (Outlook-robustní; flexbox/div-width Outlook ignoruje).
function BarRow([string]$label, [double]$value, [double]$max, [string]$sub) {
    $w = if ($max -gt 0) { [int][math]::Round(100 * $value / $max) } else { 0 }
    if ($w -lt 1 -and $value -gt 0) { $w = 1 }; if ($w -gt 100) { $w = 100 }
    $rest = 100 - $w
    $fill = if ($w -gt 0) { "<td bgcolor='#1d4ed8' width='$w%' style='width:$w%;height:12px;font-size:0;line-height:0'>&nbsp;</td>" } else { '' }
    $empty = if ($rest -gt 0) { "<td bgcolor='#eef1f6' width='$rest%' style='width:$rest%;height:12px;font-size:0;line-height:0'>&nbsp;</td>" } else { '' }
    $subHtml = if ($sub) { " <span style='color:#888'>$sub</span>" } else { '' }
    "<tr><td style='padding:2px 8px 2px 0;font-size:12px;white-space:nowrap;max-width:200px;overflow:hidden;text-overflow:ellipsis'>$(EscH $label)</td>" +
    "<td style='padding:2px 0;width:55%'><table role='presentation' cellpadding='0' cellspacing='0' width='100%' style='border-collapse:collapse;table-layout:fixed'><tr>$fill$empty</tr></table></td>" +
    "<td style='padding:2px 0 2px 8px;text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums'>$(Fmt $value)$subHtml</td></tr>"
}
function TopBars($rows, [int]$take) {
    $arr = @($rows | Sort-Object Value -Descending | Select-Object -First $take)
    if (-not $arr.Count) { return "<div style='color:#999'>—</div>" }
    $max = ($arr | Measure-Object Value -Maximum).Maximum
    "<table role='presentation' cellpadding='0' cellspacing='0' width='100%' style='border-collapse:collapse;font-size:12px'>" + (($arr | ForEach-Object { BarRow $_.Label $_.Value $max $_.Sub }) -join '') + "</table>"
}

$kpi    = if ($data) { $data.kpi } else { $null }
$gen    = if ($data) { $data.generatedUtc } else { '?' }
$sync   = if ($data -and $data.sync) { @($data.sync) } else { @() }
$dbsz   = if ($data) { $data.dbSize } else { $null }
$dbInfo = if ($data) { $data.dbInfo } else { $null }
$ua     = if ($data -and $data.userActivity) { @($data.userActivity) } else { @() }
$cl     = if ($data -and $data.changeLog) { @($data.changeLog) } else { @() }
$clc    = if ($data -and $data.changeLogByCompany) { @($data.changeLogByCompany) } else { @() }
$trend  = if ($data -and $data.trend) { @($data.trend) } else { @() }
$modName = @{ A = 'A · Využití stránek'; B = 'B · Audit změn'; C = 'C · Permission errors' }

# usermap (GUID → jméno) + sledované firmy modulu B
$userMap = @{}
try { $um = Get-Content -Raw -Encoding UTF8 (Join-Path $WebDir 'usermap.json') | ConvertFrom-Json; $um.PSObject.Properties | ForEach-Object { $userMap[$_.Name] = $_.Value } } catch {}
$clCompanies = $null
try { $cc = Get-Content -Raw -Encoding UTF8 (Join-Path $WebDir 'changelog-companies.json') | ConvertFrom-Json; if ($cc.enabled) { $clCompanies = @($cc.enabled) } } catch {}

$manualTag = if ($Manual) { '[RUČNĚ] ' } else { '' }
$subject   = '[' + $statusKey + '] ' + $manualTag + "BC Telemetrie — stav $today"

$rowsProblems = if ($hasProblems) {
    '<ul style="margin:6px 0 0 0;padding-left:18px;color:#b00020">' + (($problems | ForEach-Object { '<li>' + (EscH $_) + '</li>' }) -join '') + '</ul>'
} else { '<div style="color:#0a7d33;font-weight:600">Bez problémů — vše běží.</div>' }
$rowsWarns = if ($warns.Count -gt 0) {
    '<div style="color:#9a6700;margin-top:6px"><b>Upozornění:</b></div><ul style="margin:2px 0 0 0;padding-left:18px;color:#9a6700">' + (($warns | ForEach-Object { '<li>' + (EscH $_) + '</li>' }) -join '') + '</ul>'
} else { '' }

# ── Výčet aktivit (kontrola jednotlivých kroků z denního logu) ───────────────
function LogExit([string]$label) { $m = [regex]::Match($logTxt, "(?im)" + [regex]::Escape($label) + "\s+exit=(\d+)"); if ($m.Success) { [int]$m.Groups[1].Value } else { $null } }
function StepCell($e) { if ($null -eq $e) { "<span style='color:#999'>— neproběhlo</span>" } elseif ($e -eq 0) { "<span style='color:#0a7d33'>✓ OK</span>" } else { "<span style='color:#b00020'>✗ chyba (exit=$e)</span>" } }
$steps = @(
    @{ n = 'Import — Modul A (využití stránek)'; e = (LogExit 'modul A') },
    @{ n = 'Import — Modul C (RT0031)';          e = (LogExit 'modul C') },
    @{ n = 'Import — Modul B (audit změn)';      e = (LogExit 'modul B') },
    @{ n = 'Import — Uživatelé (mapování jmen)'; e = (LogExit 'uzivatele') },
    @{ n = 'Synchronizace stavu z cloudu';       e = (LogExit 'sync-status') },
    @{ n = 'Snapshot dat (data.json)';           e = (LogExit 'snapshot') }
)
$stepHtml = ($steps | ForEach-Object { "<tr><td $td>$($_.n)</td><td $tdR>$(StepCell $_.e)</td></tr>" }) -join ''
$aN = Get-NewestDate $ua 'LastUsed'
$bN = Get-NewestDate $cl 'ChangedAt'
function FreshCell($d) { if (-not $d) { return "<span style='color:#999'>—</span>" }; $h = [math]::Round(($now - $d).TotalHours, 1); $col = if ($h -gt [double]$cfg.staleHours) { '#b00020' } else { '#0a7d33' }; "<span style='color:$col'>$($d.ToString('yyyy-MM-dd HH:mm')) ($h h)</span>" }
$stepHtml += "<tr><td $td>Čerstvost — Modul A (poslední záznam)</td><td $tdR>$(FreshCell $aN)</td></tr>"
$stepHtml += "<tr><td $td>Čerstvost — Modul B (poslední záznam)</td><td $tdR>$(FreshCell $bN)</td></tr>"
$stepHtml += "<tr><td $td>Snapshot vygenerován</td><td $tdR>$gen UTC</td></tr>"

# ── KPI ──────────────────────────────────────────────────────────────────────
$kpiHtml = if ($kpi) {
    "<tr><td $td>Aktivní uživatelé · 30 dní</td><td $tdR>$(Fmt $kpi.ActiveUsers30d)</td></tr>" +
    "<tr><td $td>Použité stránky · 30 dní</td><td $tdR>$(Fmt $kpi.DistinctPages30d)</td></tr>" +
    "<tr><td $td>Otevření stránek · 30 dní</td><td $tdR>$(Fmt $kpi.Hits30d)</td></tr>" +
    "<tr><td $td>Permission errors (RT0031) · 14 dní</td><td $tdR>$(Fmt $kpi.AuthFails14d)</td></tr>"
} else { "<tr><td $td colspan='2'>data.json nedostupné</td></tr>" }

# ── Synchronizace (SQL / cloud) — počty, rozsah dat, firmy ───────────────────
$syncUpdated = if ($sync.Count -and $sync[0].UpdatedAt) { [string]$sync[0].UpdatedAt } else { '' }
$rangeOf = @{ A = $data.pageRange; B = $data.auditRange }
$aComp = @($ua | Where-Object { $_.CompanyName } | Select-Object -ExpandProperty CompanyName -Unique)
$syncRows = ($sync | ForEach-Object {
    $mk = [string]$_.Module; $nm = $modName[$mk]; if (-not $nm) { $nm = $mk }
    $cloud = [double]($_.CloudCount); $loc = [double]($_.LocalCount)
    $pct = if ($cloud -gt 0) { [int][math]::Round(100 * $loc / $cloud) } elseif ($loc -gt 0) { 100 } else { 0 }
    $rng = $rangeOf[$mk]; $rngTxt = if ($rng -and $rng.MinDate) { "$($rng.MinDate) – $($rng.MaxDate)" } else { '—' }
    $comp = switch ($mk) {
        'A' { if ($aComp.Count) { "$($aComp.Count) firem" } else { '—' } }
        'B' { if ($clCompanies) { $h = (($clCompanies | Select-Object -First 5) -join ', '); if ($clCompanies.Count -gt 5) { $h += " … (+$($clCompanies.Count - 5))" }; "$($clCompanies.Count) firem: $h" } else { '—' } }
        default { '—' }
    }
    "<tr><td $td>$nm</td><td $tdR>$(Fmt $loc)</td><td $tdR>$(Fmt $cloud)</td><td $tdR>$pct %</td><td $td>$rngTxt</td><td $td>$(EscH $comp)</td></tr>"
}) -join ''
if (-not $syncRows) { $syncRows = "<tr><td $td colspan='6' style='text-align:center;color:#999'>—</td></tr>" }

# ── Top uživatelé / stránky / firmy (modul A) ────────────────────────────────
$uByUser = @($ua | Group-Object UserName | ForEach-Object { $g = $_; $nm = if ($userMap[$g.Name]) { $userMap[$g.Name] } else { $g.Name }; [pscustomobject]@{ Label = $nm; Value = [double](($g.Group | Measure-Object TotalHits -Sum).Sum); Sub = '' } })
$uByPage = @($ua | Group-Object PageName | ForEach-Object { $g = $_; [pscustomobject]@{ Label = $(if ($g.Name) { $g.Name } else { 'Page ?' }); Value = [double](($g.Group | Measure-Object TotalHits -Sum).Sum); Sub = '' } })
$uByComp = @($ua | Group-Object CompanyName | ForEach-Object { $g = $_; $u = @($g.Group | Select-Object -ExpandProperty UserName -Unique).Count; [pscustomobject]@{ Label = $(if ($g.Name) { $g.Name } else { '?' }); Value = [double](($g.Group | Measure-Object TotalHits -Sum).Sum); Sub = "$u uživ." } })
$topUsersHtml = TopBars $uByUser 10
$topPagesHtml = TopBars $uByPage 10
$byCompanyHtml = TopBars $uByComp 12

# ── Trend (otevření/den + kumulace) ──────────────────────────────────────────
$cum = 0
$trendRows = ($trend | ForEach-Object { $cum += [double]$_.Hits; "<tr><td $td>$(EscH $_.DateKey)</td><td $tdR>$(Fmt $_.Hits)</td><td $tdR>$(Fmt $_.Users)</td><td $tdR>$(Fmt $cum)</td></tr>" }) -join ''
if (-not $trendRows) { $trendRows = "<tr><td $td colspan='4' style='text-align:center;color:#999'>—</td></tr>" }

# ── Audit změn — dle typu a firmy ────────────────────────────────────────────
$auByType = @($cl | Group-Object ChangeType | ForEach-Object { [pscustomobject]@{ Label = $(if ($_.Name) { $_.Name } else { '?' }); Value = [double]$_.Count; Sub = '' } })
$auByComp = @($clc | ForEach-Object { [pscustomobject]@{ Label = [string]$_.CompanyName; Value = [double]$_.Rows; Sub = '' } })
$auTypeHtml = TopBars $auByType 8
$auCompHtml = TopBars $auByComp 10
$auRangeTxt = if ($data.auditRange -and $data.auditRange.MinDate) { "$($data.auditRange.MinDate) – $($data.auditRange.MaxDate) · celkem $(Fmt $data.auditRange.Rows) záznamů" } else { '—' }

# ── Databáze ─────────────────────────────────────────────────────────────────
$srv = if ($dbInfo -and $dbInfo.ServerName) { $dbInfo.ServerName } else { '?' }
$dbn = if ($dbInfo -and $dbInfo.DbName) { $dbInfo.DbName } else { 'BC_Telemetry' }
$dbEd = if ($dbInfo) { "$($dbInfo.Version) · $($dbInfo.Edition)" } else { '' }
$dbState = if ($dbInfo) { "$($dbInfo.State) / $($dbInfo.Recovery)" } else { '' }
$dbUsed = if ($dbsz) { Fmt $dbsz.DataUsedMB } else { '—' }
$dbAlloc = if ($dbsz) { Fmt $dbsz.DataAllocMB } else { '—' }
$dbLog = if ($dbsz -and $null -ne $dbsz.LogAllocMB) { Fmt $dbsz.LogAllocMB } else { '—' }

# ── RT0031 ───────────────────────────────────────────────────────────────────
$rt = if ($kpi) { [int]$kpi.AuthFails14d } else { 0 }
$rtHtml = if ($rt -gt 0) { "<div style='color:#b00020'>$rt chyb za 14 dní — uživatelům chybí oprávnění (detail v dashboardu).</div>" } else { "<div style='color:#0a7d33'>Žádné chyby v období — uživatelé mají potřebná oprávnění.</div>" }

$dashUrl = [string]$cfg.dashboardUrl
$statusColor = if ($hasProblems) { '#b00020' } else { '#0a7d33' }
$H2 = "style='font-size:15px;margin:22px 0 8px;padding-bottom:5px;border-bottom:1px solid #cbd2dd'"
$H3 = "style='font-size:12px;margin:0 0 6px'"
$TBL = "style='border-collapse:collapse;width:100%;font-size:12px'"

$body = @"
<html><head><meta charset="utf-8"><style>
@media print{ a.btn{display:none} @page{margin:12mm} h2{break-after:avoid} }
body{margin:0}
</style></head>
<body style="font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#111;margin:0">
<div style="max-width:860px;margin:0 auto;padding:22px">

<div style="display:flex;justify-content:space-between;align-items:flex-start;border-bottom:2px solid #1d4ed8;padding-bottom:12px">
  <div>
    <div style="font-size:20px;font-weight:600">BC Telemetrie — manažerská zpráva</div>
    <div style="color:#555;font-size:11px;margin-top:4px">Snapshot $gen UTC · stav $today · stav systému: <b style="color:$statusColor">$statusKey</b></div>
  </div>
  <a class="btn" href="$dashUrl" style="background:#1d4ed8;color:#fff;padding:8px 14px;border-radius:6px;text-decoration:none;font-size:12px">Otevřít dashboard</a>
</div>

<h2 $H2>Stav systému</h2>
$rowsProblems
$rowsWarns
<h3 $H3 style="margin-top:12px">Výčet aktivit (poslední běh)</h3>
<table $TBL><thead><tr><th $thS>Činnost</th><th $thS style="text-align:right">Výsledek</th></tr></thead><tbody>$stepHtml</tbody></table>

<h2 $H2>Souhrn (KPI · 30 dní)</h2>
<table $TBL><tbody>$kpiHtml</tbody></table>

<h2 $H2>Synchronizace (SQL / cloud)</h2>
<div style="color:#666;font-size:11px;margin-bottom:6px">Cloud drží kompletní historii (Azure App Insights / BC), lokální SQL jen výřez dle retence — <b>nižší % je v pořádku</b>. Cloud naposledy změřen: $syncUpdated.</div>
<table $TBL><thead><tr><th $thS>Modul</th><th $thS style="text-align:right">SQL (lokálně)</th><th $thS style="text-align:right">Cloud (celkem)</th><th $thS style="text-align:right">Zesync.</th><th $thS>Rozsah dat</th><th $thS>Firmy / log</th></tr></thead><tbody>$syncRows</tbody></table>

<h2 $H2>Databáze</h2>
<table $TBL><tbody>
<tr><td $td style="width:200px">Server</td><td $td>$(EscH $srv)</td></tr>
<tr><td $td>Databáze</td><td $td>$(EscH $dbn)</td></tr>
<tr><td $td>Verze / edice</td><td $td>$(EscH $dbEd)</td></tr>
<tr><td $td>Stav / recovery</td><td $td>$(EscH $dbState)</td></tr>
<tr><td $td>Velikost (data)</td><td $td>$dbUsed MB využito / $dbAlloc MB alokováno · log $dbLog MB</td></tr>
</tbody></table>

<h2 $H2>Trend využití (otevření / den)</h2>
<table $TBL><thead><tr><th $thS>Datum</th><th $thS style="text-align:right">Otevření</th><th $thS style="text-align:right">Uživatelé</th><th $thS style="text-align:right">Kumulativně</th></tr></thead><tbody>$trendRows</tbody></table>

<h2 $H2>Top 10 uživatelů dle otevření</h2>
$topUsersHtml

<h2 $H2>Top 10 stránek dle otevření</h2>
$topPagesHtml

<h2 $H2>Aktivita dle firmy (modul A)</h2>
$byCompanyHtml

<h2 $H2>Audit změn — dle typu a firmy</h2>
<div style="color:#666;font-size:11px;margin-bottom:6px">Rozsah auditu v SQL: $auRangeTxt.</div>
<h3 $H3>Dle typu změny <span style="color:#777;font-weight:400;font-size:10px">(z posledních záznamů ve snapshotu)</span></h3>
$auTypeHtml
<h3 $H3 style="margin-top:10px">Dle firmy <span style="color:#777;font-weight:400;font-size:10px">(celkové počty v BC)</span></h3>
$auCompHtml

<h2 $H2>Permission errors (RT0031)</h2>
$rtHtml

<div style="color:#999;font-size:11px;margin-top:20px;border-top:1px solid #cbd2dd;padding-top:8px">Automatická zpráva BC_Telemetry · © Milan Trnka, IT · Modul A (využití stránek) · Modul B (audit změn) · Modul C (RT0031)</div>
</div>
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
