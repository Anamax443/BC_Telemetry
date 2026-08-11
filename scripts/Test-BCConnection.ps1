<#
.SYNOPSIS
    Overi, ze jsme napojeni na BC tenant, a vysledek zapise do ops\bc-status.json.

.DESCRIPTION
    PROC EXISTUJE: dashboard umi rict "sluzba bezi", ale to o spojeni s Business Centralem
    nevypovida nic — token muze byt po expiraci secretu neplatny, souhlas odvolany, prava
    v BC odebrana. Tenhle skript udela to jedine, co je prukazne: prihlasi se service
    principalem a polozi BC levny dotaz (seznam firem). Vysledek (i neuspech) zapise do
    ops\bc-status.json, odkud ho cte hlavicka dashboardu.

    PROC NE Z WEBU: web sluzba bezi jako LocalSystem a secret service principalu je
    v Credential Manageru servisniho uctu — LocalSystem ho neprecte. Proto tuhle kontrolu
    musi spustit servisni ucet: bud v ramci nocniho importu (dela se automaticky), nebo
    na vyzadani pres ulohu BC_Telemetry_BCCheck (viz Register-BCCheckTask.ps1).

    CENA: jeden token + jeden GET. Limit BC je 6000 pozadavku / 5 min na identitu, takze
    rucni overeni je zanedbatelne. Presto neni na co klikat porad dokola — beznou odpoved
    dava uz nocni beh.

.NOTES
    Windows PowerShell 5.1. Spoustet jako AXINETWORK\svc-bc-telemetry.
    Ulozit jako UTF-8 s BOM + CRLF (kvuli podpisu a AllSigned).
#>
[CmdletBinding()]
param(
    [string] $TenantId     = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId     = '4eda9e64-ead7-4aac-9631-ef4703c10135',   # BC_Telemetry_SP
    [string] $SecretTarget = 'BC_Telemetry_BCAPI',                     # Credential Manager target
    [string] $Environment  = 'Production',
    [string] $WebDir       = 'C:\Apps\BC_Telemetry_Web'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BCApi.psm1') -Force

$base = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$Environment/ODataV4"
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
Write-Host "[$stamp] Test spojeni s BC: $base"

try {
    # Initialize-BCApiSession zapise stav sam (uspech i selhani prihlaseni).
    Initialize-BCApiSession -TenantId $TenantId -ClientId $ClientId -SecretTarget $SecretTarget `
        -WebDir $WebDir -Label 'test spojeni' -Environment $Environment -Endpoint $base -StatusSource 'manual'

    # Levny prukazny dotaz: seznam firem (jen nazvy).
    $companies = @((Invoke-BCApiGet -Uri "$base/Company?`$select=Name").value | ForEach-Object { $_.Name })

    Write-BCApiStatus -Ok $true -WebDir $WebDir -TenantId $TenantId -Environment $Environment `
        -ClientId $ClientId -Endpoint $base -Companies ([int]$companies.Count) -Source 'manual'

    Write-Host "OK: napojeno na tenant, BC vratil $($companies.Count) firem."
    Write-BCApiSummary
    exit 0
} catch {
    $msg = $_.Exception.Message
    Write-BCApiStatus -Ok $false -WebDir $WebDir -TenantId $TenantId -Environment $Environment `
        -ClientId $ClientId -Endpoint $base -ErrorText $msg -Source 'manual'
    Write-Host "CHYBA: spojeni s BC nefunguje - $msg"
    # nejcastejsi priciny, at to nemusi nikdo dohledavat v dokumentaci
    Write-Host 'Zkontroluj v tomto poradi: 1) platnost secretu v Entra (expirace 2028-06-07),'
    Write-Host '  2) admin consent u API.ReadWrite.All, 3) stav app usera v BC (stranka Aplikace Microsoft Entra).'
    exit 1
}
