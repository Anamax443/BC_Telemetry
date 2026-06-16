<#
.SYNOPSIS
    Modul B - smazani audit zaznamu (dbo.BCChangeLog) pro vybrane firmy.

.DESCRIPTION
    Zpracuje pozadavek z ops/ops-request.json, ktery zapisuje web sluzba (dashboard
    -> zalozka "Nastaveni auditu" -> Smazat audit zaznamy). Maze parametrizovane
    DELETE FROM dbo.BCChangeLog WHERE CompanyName IN (...). Bezi pod svc uctem
    (ma db_datawriter), vola se z denniho wrapperu (Invoke-BCTelemetryDaily.ps1)
    v "purge-only" rezimu (wrapper pak preskoci import, aby se smazane nenatahly zpet).

    Pozn.: maze jen zaznamy. Pokud firma zustava sledovana (changelog-companies.json),
    pri pristim normalnim importu se zacne natahovat znovu od nejstarsich.

    Kontrakt souboru (oba v ops dir):
      ops-request.json  { action:"purge", companies:["A","B"], requestedAt:"ISO" }   (smaze po zpracovani)
      ops-status.json   { action, companies, deleted, finishedAt, ok, error }        (zapise vysledek)

.NOTES
    ASCII-only (zadna diakritika) - bezi pod Windows PowerShell 5.1 bez ohledu na BOM.
#>
[CmdletBinding()]
param(
    [string] $OpsDir      = 'C:\Apps\BC_Telemetry_Web\ops',
    [string] $SqlServer   = 'localhost',
    [string] $SqlDatabase = 'BC_Telemetry'
)
$ErrorActionPreference = 'Stop'

$reqFile = Join-Path $OpsDir 'ops-request.json'
$statFile = Join-Path $OpsDir 'ops-status.json'

function Write-Status($obj) {
    try {
        if (-not (Test-Path $OpsDir)) { New-Item -ItemType Directory -Force $OpsDir | Out-Null }
        [IO.File]::WriteAllText($statFile, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Host "WARN: nelze zapsat $statFile : $($_.Exception.Message)" }
}

if (-not (Test-Path $reqFile)) { Write-Host 'Purge: zadny ops-request.json - nic k provedeni.'; exit 0 }

try { $req = Get-Content -Raw -Path $reqFile | ConvertFrom-Json } catch {
    Write-Host "Purge: ops-request.json nelze precist: $($_.Exception.Message)"
    Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
    exit 0
}

if (-not $req -or "$($req.action)" -ne 'purge') {
    Write-Host "Purge: action != 'purge' (action=$($req.action)) - preskakuji."
    exit 0
}

$companies = @()
if ($req.companies) { $companies = @($req.companies | ForEach-Object { "$_" } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) }
$companies = @($companies | Select-Object -Unique)

if (-not $companies.Count) {
    Write-Host 'Purge: prazdny seznam firem - nic k mazani.'
    Write-Status ([ordered]@{ action='purge'; companies=@(); deleted=0; finishedAt=([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')); ok=$true; error=$null })
    Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-Host "Purge: firmy ($($companies.Count)): $($companies -join ', ')"

$deleted = 0
$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True"
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $params = @()
    for ($i = 0; $i -lt $companies.Count; $i++) {
        $p = "@c$i"
        $params += $p
        $cmd.Parameters.AddWithValue($p, $companies[$i]) | Out-Null
    }
    $cmd.CommandText = "DELETE FROM dbo.BCChangeLog WHERE CompanyName IN ($($params -join ','))"
    $cmd.CommandTimeout = 600
    $deleted = [int]$cmd.ExecuteNonQuery()
    Write-Host "Purge: smazano $deleted zaznamu."
    Write-Status ([ordered]@{ action='purge'; companies=$companies; deleted=$deleted; finishedAt=([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')); ok=$true; error=$null })
    Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
}
catch {
    $msg = $_.Exception.Message
    Write-Host "Purge: CHYBA - $msg"
    Write-Status ([ordered]@{ action='purge'; companies=$companies; deleted=$deleted; finishedAt=([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')); ok=$false; error=$msg })
    Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
    exit 1
}
finally { if ($conn.State -eq 'Open') { $conn.Close() } }
