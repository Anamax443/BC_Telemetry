<#
.SYNOPSIS
    Spočítá kolik záznamů cloud obsahuje vs kolik je zesynchronizováno (per modul) → dbo.BCSyncStatus.

.DESCRIPTION
    Běží jako svc (creds z Credential Manageru). Cloud počty:
      A (využití stránek) = AppPageViews count (Log Analytics, retence ~90 dní)
      C (RT0031)          = AppTraces eventId RT0031 count
      B (audit změn)      = součet OData $count Change Logu přes všechny firmy
    Lokální počty = COUNT z dbo.BCPageLog / BCAuthFailRaw / BCChangeLog.
    Volá se z denního wrapperu před snapshotem (Export pak data dá do data.json).

.NOTES
    Uložit jako UTF-8 s BOM (Windows PowerShell 5.1).
#>
#requires -Modules Az.Accounts, Az.OperationalInsights
[CmdletBinding()]
param(
    [string] $WorkspaceId    = '484e3038-d41f-4c92-991c-cb71ecb54590',
    [string] $TenantId       = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId       = '4eda9e64-ead7-4aac-9631-ef4703c10135',
    [string] $Environment    = 'Production',
    [string] $SecretTargetSP = 'BC_Telemetry_SP',
    [string] $SecretTargetBC = 'BC_Telemetry_BCAPI',
    [string] $SqlServer      = 'localhost',
    [string] $SqlDatabase    = 'BC_Telemetry'
)
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager

# Odolna vrstva pro volani BC API (brzda, opakovani pri 429/5xx, read-only replika) — viz BCApi.psm1.
$bcApiModule = Join-Path $PSScriptRoot 'BCApi.psm1'
if (-not (Test-Path $bcApiModule)) { $bcApiModule = 'C:\Apps\BC_Telemetry\scripts\BCApi.psm1' }
Import-Module $bcApiModule -Force

$conn = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True"
$conn.Open()
function Set-Sync([string]$m, $cloud, $local) {
    $c = $conn.CreateCommand(); $c.CommandText = 'EXEC dbo.usp_BCSyncStatus_Set @m,@cl,@lo'
    $c.Parameters.AddWithValue('@m', $m)            | Out-Null
    $c.Parameters.AddWithValue('@cl', [int64]$cloud) | Out-Null
    $c.Parameters.AddWithValue('@lo', [int64]$local) | Out-Null
    $c.ExecuteNonQuery() | Out-Null
    Write-Host "  $m : cloud=$cloud  local=$local"
}
function Get-Local([string]$t) { $c = $conn.CreateCommand(); $c.CommandText = "SELECT COUNT_BIG(*) FROM dbo.$t"; return [int64]$c.ExecuteScalar() }

try {
    # ── Azure (moduly A, C) ──────────────────────────────────────────────────
    $spSecret = (Get-StoredCredential -Target $SecretTargetSP).Password
    $spCred = New-Object System.Management.Automation.PSCredential ($ClientId, $spSecret)
    Connect-AzAccount -ServicePrincipal -Credential $spCred -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null

    try {
        $a = (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query 'AppPageViews | summarize c=count()').Results.c
        if ($null -eq $a) { $a = 0 }
        Set-Sync 'A' $a (Get-Local 'BCPageLog')
    } catch { Write-Host "A chyba: $($_.Exception.Message)" }

    try {
        $c = (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query "AppTraces | where tostring(Properties.eventId)=='RT0031' | summarize c=count()").Results.c
        if ($null -eq $c) { $c = 0 }
        Set-Sync 'C' $c (Get-Local 'BCAuthFailRaw')
    } catch { Write-Host "C chyba: $($_.Exception.Message)" }

    Disconnect-AzAccount | Out-Null

    # ── BC API (modul B) — součet OData $count přes firmy ────────────────────
    try {
        $base = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$Environment/ODataV4"
        Initialize-BCApiSession -TenantId $TenantId -ClientId $ClientId -SecretTarget $SecretTargetBC -Label 'sync-status (modul B)' `
            -Environment $Environment -Endpoint $base
        $companies = (Invoke-BCApiGet -Uri "$base/Company?`$select=Name").value.Name
        Write-BCApiStatus -Ok $true -TenantId $TenantId -Environment $Environment -ClientId $ClientId `
            -Endpoint $base -Companies ([int]@($companies).Count)
        $sum = [int64]0
        $failed = 0
        foreach ($co in $companies) {
            try {
                $r = Invoke-BCApiGet -Uri "$base/Company('$co')/ChangelogEntry?`$top=0&`$count=true"
                $sum += [int64]$r.'@odata.count'
            } catch {
                $failed++
                Write-Host "  firma ${co}: počet v cloudu se nepodařilo zjistit — $($_.Exception.Message)"
            }
        }
        $localB = Get-Local 'BCChangeLog'
        # Když se část firem nespočítala, je součet zavádějící (vypadal by jako chybějící data)
        # → radši ukaž lokální počet a napiš proč, ať dashboard netvrdí nesmysl.
        if ($failed -gt 0) {
            Write-Host "  pozor: u $failed z $($companies.Count) firem se cloudový počet nezjistil (BC odmítal požadavky) → sync-status modulu B ukazuje lokální stav."
            $sum = $localB
        }
        # fallback: když $count není podporován (sum 0) ale lokálně data máme, ukaž alespoň lokál
        if ($sum -eq 0 -and $localB -gt 0) { $sum = $localB }
        Set-Sync 'B' $sum $localB
        Write-BCApiSummary
    } catch { Write-Host "B chyba: $($_.Exception.Message)" }

    Write-Host 'Sync-status aktualizován.'
}
finally { if ($conn.State -eq 'Open') { $conn.Close() } }
