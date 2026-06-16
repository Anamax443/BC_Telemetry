<#
.SYNOPSIS
    Denní běh BC_Telemetry — import všech 3 modulů + snapshot pro dashboard.

.DESCRIPTION
    Volá se ze scheduled tasku (denně, viz Register-ScheduledTask.ps1) pod servisním
    účtem AXINETWORK\svc-bc-telemetry. Každý krok běží ve VLASTNÍM child procesu
    (powershell -File), aby `exit 1` jednoho importu neshodil ostatní kroky.
    Loguje do -LogDir (per-den soubor).

    Pořadí: modul A (page views) → modul C (RT0031) → modul B (change log) → snapshot.
    Importy jsou inkrementální (watermark), takže denní náklad roste jen s přírůstkem.

.NOTES
    Uložit jako UTF-8 s BOM (Windows PowerShell 5.1 jinak čte CP1250 → parse error).
#>
[CmdletBinding()]
param(
    [string] $ScriptDir = 'C:\Apps\BC_Telemetry\scripts',
    [string] $SqlServer = 'localhost',
    [string] $Snapshot  = 'C:\Apps\BC_Telemetry_Web\public\data.json',
    [string] $LogDir    = 'C:\Apps\BC_Telemetry\logs',
    [string] $WebDir    = 'C:\Apps\BC_Telemetry_Web',
    [int]    $LogRetentionDays = 30
)
# fallback, kdyby ScriptDir nesedl
if (-not $ScriptDir -or -not (Test-Path $ScriptDir)) { if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot } }
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
$log = Join-Path $LogDir ('bct-daily-' + [DateTime]::Now.ToString('yyyyMMdd') + '.log')
function Log([string]$m) { ("$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $m") | Tee-Object -FilePath $log -Append }

$ps = 'powershell.exe'
$A  = Join-Path $ScriptDir 'BC_PageLog_Import.ps1'
$C  = Join-Path $ScriptDir 'BC_AuthFail_Import.ps1'
$B  = Join-Path $ScriptDir 'BC_ChangeLog_Import.ps1'
$USR= Join-Path $ScriptDir 'BC_Users_Import.ps1'
$U  = Join-Path $ScriptDir 'Update-SyncStatus.ps1'
$E  = Join-Path $ScriptDir 'Export-DashboardSnapshot.ps1'
$P  = Join-Path $ScriptDir 'BC_ChangeLog_Purge.ps1'

Log "=== BC_Telemetry daily START (user=$env:USERNAME) ==="
Log "ScriptDir=$ScriptDir  (A exists=$(Test-Path $A))"

# Ops-request (z dashboardu) — pokud ceka pozadavek na smazani audit zaznamu, provedeme
# JEN purge + snapshot a import preskocime (jinak by import smazane firmy hned natahl zpet).
$opsReq = Join-Path $WebDir 'ops\ops-request.json'
if (Test-Path $opsReq) {
    Log "--- ops-request detekovan: purge-only rezim (import preskocen) ---"
    & $ps -NoProfile -ExecutionPolicy Bypass -File $P *>> $log
    Log "purge exit=$LASTEXITCODE"
    Log "--- snapshot po purge: Export-DashboardSnapshot.ps1 ---"
    & $ps -NoProfile -ExecutionPolicy Bypass -File $E -SqlServer $SqlServer -OutPath $Snapshot *>> $log
    Log "snapshot exit=$LASTEXITCODE"
    Log "=== BC_Telemetry daily END (purge-only) ==="
    return
}

Log "--- modul A (page views): BC_PageLog_Import.ps1 ---"
& $ps -NoProfile -ExecutionPolicy Bypass -File $A *>> $log
Log "modul A exit=$LASTEXITCODE"

Log "--- modul C (RT0031): BC_AuthFail_Import.ps1 ---"
& $ps -NoProfile -ExecutionPolicy Bypass -File $C *>> $log
Log "modul C exit=$LASTEXITCODE"

Log "--- modul B (change log): BC_ChangeLog_Import.ps1 ---"
& $ps -NoProfile -ExecutionPolicy Bypass -File $B *>> $log
Log "modul B exit=$LASTEXITCODE"

Log "--- uzivatele (BC Users -> dbo.BCUser + usermap.json): BC_Users_Import.ps1 ---"
& $ps -NoProfile -ExecutionPolicy Bypass -File $USR *>> $log
Log "uzivatele exit=$LASTEXITCODE"

Log "--- sync-status: Update-SyncStatus.ps1 ---"
& $ps -NoProfile -ExecutionPolicy Bypass -File $U *>> $log
Log "sync-status exit=$LASTEXITCODE"

Log "--- snapshot: Export-DashboardSnapshot.ps1 ---"
& $ps -NoProfile -ExecutionPolicy Bypass -File $E -SqlServer $SqlServer -OutPath $Snapshot *>> $log
Log "snapshot exit=$LASTEXITCODE"

# Retence logů — denní soubory se jinak množí (1/den). Smazat starší než N dní.
try {
    $cut = (Get-Date).AddDays(-$LogRetentionDays)
    $old = Get-ChildItem $LogDir -Filter 'bct-daily-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut }
    if ($old) { $old | Remove-Item -Force -ErrorAction SilentlyContinue; Log "Retence logů: smazáno $($old.Count) souborů starších $LogRetentionDays dní." }
} catch { Log "Retence logů — chyba: $($_.Exception.Message)" }

Log "=== BC_Telemetry daily END ==="
