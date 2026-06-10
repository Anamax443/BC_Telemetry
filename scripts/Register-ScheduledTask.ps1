<#
.SYNOPSIS
    Zaregistruje denní scheduled task pro BC_PageLog_Import.ps1.

.DESCRIPTION
    Verze 1.1 — zapracována oponentura 2026-06-08:
      #8 LogonType  -> 'Password' pro doménový účet (ServiceAccount je jen pro
                       virtuální/gMSA účty; s doménovým by úloha selhala 0x80041315).
                       Alternativa gMSA viz poznámka níže.

    Spustit jednorázově jako administrátor na serveru, kde úloha poběží.
#>

[CmdletBinding()]
param(
    [string] $TaskName   = 'BC_PageLog_Import',
    [string] $ScriptPath = 'C:\Scripts\BC_PageLog_Import.ps1',
    [string] $LogPath    = 'C:\Scripts\Logs\BC_PageLog_Import.log',
    [string] $RunAs      = 'AXINETWORK\svc-bc-telemetry'
)

$ErrorActionPreference = 'Stop'

# Heslo servisního účtu — vyžádá interaktivně při registraci (neukládá se ve skriptu).
$cred = Get-Credential -UserName $RunAs -Message "Heslo pro $RunAs (uloží se do úlohy)"

$action = New-ScheduledTaskAction `
    -Execute 'PowerShell.exe' `
    -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" >> `"$LogPath`" 2>&1"

$trigger = New-ScheduledTaskTrigger -Daily -At '02:00'

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 15) `
    -StartWhenAvailable

# LogonType Password — správně pro doménový účet AXINETWORK\svc-bc-telemetry (oponentura #8)
Register-ScheduledTask `
    -TaskName    $TaskName `
    -Description 'Stahuje BC telemetrii z Azure AppInsights do SQL (inkrementálně).' `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -User        $cred.UserName `
    -Password    $cred.GetNetworkCredential().Password `
    -RunLevel    Highest `
    -Force

Write-Host "Úloha '$TaskName' zaregistrována (LogonType Password, denně 02:00)."

# Pozn.: regular doménový účet (AXINETWORK\svc-bc-telemetry), stejně jako ITDashboard.
# gMSA se NEpoužívá (rozhodnutí operatora).
