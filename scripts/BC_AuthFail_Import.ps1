<#
.SYNOPSIS
    Modul C — import RT0031 (Authorization Failed) z App Insights do SQL.

.DESCRIPTION
    Stejná infra jako BC_PageLog_Import (Service Principal + Log Analytics workspace).
    RT0031 vzniká AŽ po odebrání plného přístupu a nasazení omezených rolí — pod plným
    přístupem žádné nejsou. Identita = pseudonymní GUID (UserId), jako modul A.

    Tok: AppTraces (eventId == 'RT0031') → staging → dbo.BCAuthFailRaw → rollup → dbo.BCAuthFailDaily.

    ⚠ Pole RT0031 v AppTraces (eventId / alObjectId / UserId umístění) OVĚŘIT na reálných
    RT0031 datech před produkčním během — schéma App Insights nás už jednou překvapilo.
#>
#requires -Modules Az.Accounts, Az.OperationalInsights
[CmdletBinding()]
param(
    [string] $WorkspaceId  = '484e3038-d41f-4c92-991c-cb71ecb54590',  # DefaultWorkspace-…-WEU
    [string] $TenantId     = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId     = '4eda9e64-ead7-4aac-9631-ef4703c10135',  # BC_Telemetry_SP
    [string] $SecretTarget = 'BC_Telemetry_SP',
    [string] $SqlServer    = 'localhost',
    [string] $SqlDatabase  = 'BC_Telemetry'
)
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager
$secret = (Get-StoredCredential -Target $SecretTarget).Password
$cred = New-Object System.Management.Automation.PSCredential ($ClientId, $secret)
Connect-AzAccount -ServicePrincipal -Credential $cred -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True"
$conn.Open()
try {
    $cmdMax = $conn.CreateCommand()
    $cmdMax.CommandText = "SELECT ISNULL(MAX(Timestamp),'2000-01-01') FROM dbo.BCAuthFailRaw"
    $lastIso = ([DateTime]$cmdMax.ExecuteScalar()).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    # Jednorázový re-import (ops/authfail-reset.flag): smaže RT0031 a načte znovu s bohatými poli
    # (po rozšíření o permissionType/errorMessage). Flag založí operátor/dashboard, skript ho uklidí.
    $resetFlag = 'C:\Apps\BC_Telemetry_Web\ops\authfail-reset.flag'
    if (Test-Path $resetFlag) {
        Write-Host 'RT0031 RESET: mažu BCAuthFailRaw + BCAuthFailDaily, re-import od začátku.'
        $cmdDel = $conn.CreateCommand(); $cmdDel.CommandText = 'DELETE FROM dbo.BCAuthFailRaw; DELETE FROM dbo.BCAuthFailDaily;'; $cmdDel.ExecuteNonQuery() | Out-Null
        $lastIso = '2000-01-01T00:00:00.000Z'
        Remove-Item $resetFlag -Force -ErrorAction SilentlyContinue
    }

    # AppTraces / Log Analytics; RT0031 = Authorization Failed.
    # Ověřeno 2026-06-24, že Properties nese: alObjectType, alObjectId, permissionType,
    # permissionArea, companyName a hlavně errorMessage (= co konkrétně chybí, lokalizovaně).
    # Napěchujeme do stávajících sloupců (bez DDL): ObjectId = "<permType> · <objType> [id]",
    #   ObjectName = "<firma> · <errorMessage>" → na dashboardu rovnou vidíš, co udělit.
    $query = @"
AppTraces
| where TimeGenerated > datetime($lastIso)
| where tostring(Properties.eventId) == 'RT0031'
| extend userId   = tostring(UserId)
| extend pType    = tostring(Properties.permissionType)
| extend oType    = tostring(Properties.alObjectType)
| extend oId      = tostring(Properties.alObjectId)
| extend oName    = tostring(Properties.alObjectName)
| extend company  = tostring(Properties.companyName)
| extend errMsg   = tostring(Properties.errorMessage)
| extend objectId   = substring(strcat(coalesce(pType,'?'), ' · ', coalesce(oType,'?'), iff(oId in ('0',''), '', strcat(' ', oId)), iff(isempty(oName), '', strcat(' ', oName))), 0, 50)
| extend objectName = substring(strcat(iff(isempty(company), '', strcat(company, ' · ')), coalesce(errMsg, oName)), 0, 200)
| project timestamp = TimeGenerated, userId, objectId, objectName
| order by timestamp desc
"@
    $rows = @((Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query).Results)
    Write-Host "RT0031 staženo: $($rows.Count)"
    foreach ($r in $rows) {
        $c = $conn.CreateCommand()
        $c.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM dbo.BCAuthFailRaw WHERE Timestamp=@t AND UserId=@u AND ISNULL(ObjectId,'')=ISNULL(@o,''))
INSERT INTO dbo.BCAuthFailRaw (Timestamp,UserId,ObjectId,ObjectName) VALUES (@t,@u,@o,@n)
"@
        $oVal = [DBNull]::Value; if ($r.objectId)   { $oVal = $r.objectId }
        $nVal = [DBNull]::Value; if ($r.objectName) { $nVal = $r.objectName }
        $c.Parameters.AddWithValue('@t',[datetime]$r.timestamp) | Out-Null
        $c.Parameters.AddWithValue('@u',$r.userId) | Out-Null
        $c.Parameters.AddWithValue('@o',$oVal) | Out-Null
        $c.Parameters.AddWithValue('@n',$nVal) | Out-Null
        $c.ExecuteNonQuery() | Out-Null
    }
    $cmdR = $conn.CreateCommand(); $cmdR.CommandText = 'EXEC dbo.usp_BCAuthFail_Rollup'; $cmdR.ExecuteNonQuery() | Out-Null
    Write-Host "RT0031 rollup hotov."
}
finally { if ($conn.State -eq 'Open') { $conn.Close() }; Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null }
