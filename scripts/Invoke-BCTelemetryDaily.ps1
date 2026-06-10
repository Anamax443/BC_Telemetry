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
    [string] $ScriptDir = $PSScriptRoot,
    [string] $SqlServer = 'localhost',
    [string] $Snapshot  = 'C:\Apps\BC_Telemetry_Web\public\data.json',
    [string] $LogDir    = 'C:\Apps\BC_Telemetry\logs'
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
$log = Join-Path $LogDir ('bct-daily-' + [DateTime]::Now.ToString('yyyyMMdd') + '.log')
function Log([string]$m) { ("$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $m") | Tee-Object -FilePath $log -Append }

Log "=== BC_Telemetry daily START (user=$env:USERNAME) ==="

$steps = @(
    @{ n = 'modul A (page views)'; f = 'BC_PageLog_Import.ps1';        a = @() },
    @{ n = 'modul C (RT0031)';     f = 'BC_AuthFail_Import.ps1';       a = @() },
    @{ n = 'modul B (change log)'; f = 'BC_ChangeLog_Import.ps1';      a = @() },
    @{ n = 'snapshot';             f = 'Export-DashboardSnapshot.ps1'; a = @('-SqlServer', $SqlServer, '-OutPath', $Snapshot) }
)

foreach ($s in $steps) {
    $path = Join-Path $ScriptDir $s.f
    Log "--- $($s.n): $($s.f) ---"
    if (-not (Test-Path $path)) { Log "CHYBI skript: $path"; continue }
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @($s.a) *>> $log
        Log "$($s.n) dokonceno (exit=$LASTEXITCODE)"
    } catch {
        Log "$($s.n) CHYBA: $($_.Exception.Message)"
    }
}

Log "=== BC_Telemetry daily END ==="
