<#
.SYNOPSIS
    Zaregistruje denní scheduled task pro BC_Telemetry (všechny 3 moduly + snapshot).

.DESCRIPTION
    Spustí Invoke-BCTelemetryDaily.ps1 denně pod servisním účtem (regular doménový,
    LogonType Password — ne gMSA). Vytvoří log složku a dá na ni servisnímu účtu zápis.

    Spustit jednorázově jako administrátor na serveru (10.8.2.225). Vyžádá heslo svc účtu.

.NOTES
    Uložit jako UTF-8 s BOM (Windows PowerShell 5.1).
#>
[CmdletBinding()]
param(
    [string] $TaskName   = 'BC_Telemetry_Daily',
    [string] $ScriptPath = 'C:\Apps\BC_Telemetry\scripts\Invoke-BCTelemetryDaily.ps1',
    [string] $RunAs      = 'AXINETWORK\svc-bc-telemetry',
    [string] $LogDir     = 'C:\Apps\BC_Telemetry\logs',
    [string] $At         = '02:00'
)
$ErrorActionPreference = 'Stop'

# Log složka — servisní účet potřebuje zápis (task běží jako on)
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
icacls $LogDir /grant "${RunAs}:(OI)(CI)M" | Out-Null

# Heslo servisního účtu — vyžádá interaktivně, neukládá se ve skriptu
$cred = Get-Credential -UserName $RunAs -Message "Heslo pro $RunAs (uloží se do úlohy)"

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -Daily -At $At

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 15) `
    -StartWhenAvailable

# LogonType Password — správně pro regular doménový účet (gMSA se NEpoužívá)
Register-ScheduledTask `
    -TaskName    $TaskName `
    -Description 'BC_Telemetry: denní import 3 modulů (page views / RT0031 / change log) + snapshot dashboardu.' `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -User        $cred.UserName `
    -Password    $cred.GetNetworkCredential().Password `
    -RunLevel    Highest `
    -Force

Write-Host "Úloha '$TaskName' zaregistrována (denně $At, jako $RunAs)."
Write-Host "Ruční spuštění / test:  Start-ScheduledTask -TaskName $TaskName"
Write-Host "Log:  $LogDir\bct-daily-<datum>.log"
