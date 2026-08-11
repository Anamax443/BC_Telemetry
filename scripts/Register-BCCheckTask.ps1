<#
.SYNOPSIS
    Zaregistruje ulohu BC_Telemetry_BCCheck — rucni overeni spojeni s BC z dashboardu.

.DESCRIPTION
    Bez teto ulohy dashboard stav spojeni porad ukazuje (bere ho z nocniho importu),
    jen tlacitko "Overit ted" vrati vysvetleni, ze na vyzadani to spustit nejde.
    Uloha existuje presne proto, ze web sluzba (LocalSystem) nema secret service
    principalu — musi to provest servisni ucet.

    Uloha nema zadny trigger: nespousti se sama, jen ji dashboard kopne pres
    Start-ScheduledTask. Bezi par sekund (token + jeden GET).

.NOTES
    Spustit JEDNOU, na serveru 10.8.2.225, jako spravce. Vyzada heslo servisniho uctu
    (registrace ulohy pod jinym uctem ho potrebuje — ulozi se do Credential Manageru
    Task Scheduleru, ne do souboru).
    Overeni po registraci:  Start-ScheduledTask -TaskName 'BC_Telemetry_BCCheck'
#>
[CmdletBinding()]
param(
    [string] $TaskName    = 'BC_Telemetry_BCCheck',
    [string] $ScriptPath  = 'C:\Apps\BC_Telemetry\scripts\Test-BCConnection.ps1',
    [string] $ServiceAcct = 'AXINETWORK\svc-bc-telemetry'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) {
    throw "Skript $ScriptPath na serveru neni - nejdriv nasad obsah scripts\ na \\10.8.2.225\BC_Telemetry."
}

# Stejny rezim jako BC_Telemetry_Daily (Register-ScheduledTask.ps1) — skripty na .225 nejsou podepsane.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

# Bez triggeru: ulohu spousti vyhradne dashboard (POST /bc-check -> Start-ScheduledTask).
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

$cred = Get-Credential -UserName $ServiceAcct -Message "Heslo uctu $ServiceAcct (potrebne jen pro registraci ulohy)"

Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null

Write-Host "Uloha $TaskName zaregistrovana (bezi jako $ServiceAcct, bez triggeru)."
Write-Host "Test:  Start-ScheduledTask -TaskName '$TaskName'  ->  pak zkontroluj ops\bc-status.json"
