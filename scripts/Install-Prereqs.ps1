<#
.SYNOPSIS
    Nainstaluje PowerShell prerekvizity pro BC_Telemetry import (modul Az + Credential Manager).

.DESCRIPTION
    Skripty jsou psané pro modul **Az** (ne legacy AzureRM). Instaluje se jen to, co
    `#requires` v BC_PageLog_Import.ps1 potřebuje — ne celý meta-modul Az (stovky MB):
      - Az.Accounts            (Connect-AzAccount, Service Principal auth)
      - Az.OperationalInsights (Invoke-AzOperationalInsightsQuery)
      - CredentialManager      (čtení SP secretu z Windows Credential Manageru)

    Spustit na serveru, kde poběží Task Scheduler (BSWNAV01 / aplikační server).
    Pro běh pod servisním účtem zvol -Scope AllUsers (vyžaduje elevaci).
#>

[CmdletBinding()]
param(
    [ValidateSet('CurrentUser','AllUsers')]
    [string] $Scope = 'AllUsers'
)

$ErrorActionPreference = 'Stop'

# TLS 1.2 pro starší Windows PowerShell 5.1 (na PS 7 už default)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# NuGet provider + důvěryhodná galerie (bez interaktivního dotazu)
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
}
if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

# AzureRM a Az nesmí koexistovat ve stejné session — varuj, pokud je legacy přítomen
if (Get-Module -ListAvailable -Name AzureRM*) {
    Write-Warning 'Detekován legacy AzureRM. Doporučeno: Uninstall-AzureRm  (Az je nástupce, cmdlety jsou kompatibilní s -AzureRmAlias).'
}

foreach ($m in 'Az.Accounts','Az.OperationalInsights','CredentialManager') {
    Write-Host "Instaluji $m (scope $Scope)…"
    Install-Module $m -Scope $Scope -Force -AllowClobber
}

Write-Host "`nHotovo. Nainstalované verze:"
Get-Module -ListAvailable Az.Accounts,Az.OperationalInsights,CredentialManager |
    Select-Object Name, Version | Sort-Object Name | Format-Table -AutoSize
