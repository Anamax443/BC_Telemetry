<#
.SYNOPSIS
    Vyexportuje agregovaná data z SQL do web\data.json pro admin dashboard.

.DESCRIPTION
    Čte POUZE z agregačních pohledů (vw_Dash*) — nikdy z raw dbo.BCPageLog.
    Výstup je malý (jednotky až stovky kB) i při milionech raw řádků, takže ho
    statický HTML dashboard načte okamžitě bez živého připojení k DB.

    Spouští se denně po importu (stejný Task Scheduler, druhá akce nebo navazující úloha).
#>

[CmdletBinding()]
param(
    [string] $SqlServer   = 'localhost',   # DB co-located na 10.8.2.225
    [string] $SqlDatabase = 'BC_Telemetry',
    [string] $OutPath     = 'C:\Apps\BC_Telemetry_Web\public\data.json',
    [int]    $TopRows     = 5000   # strop řádků na sekci — chrání velikost snapshotu
)

$ErrorActionPreference = 'Stop'

function Invoke-Sql {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$Sql)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 300
    $rdr = $cmd.ExecuteReader()
    $rows = @()
    while ($rdr.Read()) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $rdr.FieldCount; $i++) {
            $v = $rdr.GetValue($i)
            $o[$rdr.GetName($i)] = if ($v -is [DBNull]) { $null } elseif ($v -is [DateTime]) { $v.ToString('yyyy-MM-dd') } else { $v }
        }
        $rows += [pscustomobject]$o
    }
    $rdr.Close()
    return ,$rows
}

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True"
$conn.Open()
try {
    $kpi = (Invoke-Sql $conn 'SELECT * FROM dbo.vw_DashKPI')[0]
    $sync = @()
    try { $sync = Invoke-Sql $conn 'SELECT Module, CloudCount, LocalCount, CONVERT(varchar(19),UpdatedAt,120) AS UpdatedAt FROM dbo.BCSyncStatus ORDER BY Module' } catch { }

    # Velikost lokalni DB (datovy + log soubor; MB) — orientacni pro spravu retence/mazani.
    $dbSize = $null
    try {
        $dbSize = (Invoke-Sql $conn @"
SELECT
  CAST(ISNULL(SUM(CASE WHEN type=0 THEN CAST(size AS bigint) END),0)*8/1024.0 AS decimal(18,1)) AS DataAllocMB,
  CAST(ISNULL(SUM(CASE WHEN type=0 THEN CAST(FILEPROPERTY(name,'SpaceUsed') AS bigint) END),0)*8/1024.0 AS decimal(18,1)) AS DataUsedMB,
  CAST(ISNULL(SUM(CASE WHEN type=1 THEN CAST(size AS bigint) END),0)*8/1024.0 AS decimal(18,1)) AS LogAllocMB
FROM sys.database_files
"@)[0]
    } catch { }

    # Pocet audit zaznamu (modul B) per firma — podklad pro vyber firem k mazani.
    $clByCompany = @()
    try { $clByCompany = Invoke-Sql $conn 'SELECT CompanyName, COUNT_BIG(*) AS Rows FROM dbo.BCChangeLog GROUP BY CompanyName ORDER BY COUNT_BIG(*) DESC' } catch { }

    $snapshot = [ordered]@{
        generatedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
        kpi            = $kpi
        sync           = $sync
        dbSize         = $dbSize
        changeLogByCompany = $clByCompany
        userActivity   = Invoke-Sql $conn "SELECT TOP ($TopRows) * FROM dbo.vw_DashUserActivity ORDER BY TotalHits DESC"
        trend          = Invoke-Sql $conn 'SELECT * FROM dbo.vw_DashTrend ORDER BY DateKey'
        trendByCompany = Invoke-Sql $conn 'SELECT DateKey, CompanyName, SUM(Hits) AS Hits, COUNT(DISTINCT UserName) AS Users FROM dbo.BCPageDaily GROUP BY DateKey, CompanyName ORDER BY DateKey'
        authFails      = Invoke-Sql $conn "SELECT TOP ($TopRows) DateKey, UserName, ObjectId, ObjectName, Failures FROM dbo.BCAuthFailDaily ORDER BY DateKey DESC, Failures DESC"
        changeLog      = Invoke-Sql $conn "SELECT TOP ($TopRows) CONVERT(varchar(19),ChangedAt,120) AS ChangedAt, UserId, ChangeType, TableName, FieldName, PrimaryKey, OldValue, NewValue FROM dbo.vw_DashAudit"
    }

    $json = $snapshot | ConvertTo-Json -Depth 6 -Compress
    $dir = Split-Path $OutPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($OutPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Snapshot zapsán: $OutPath ($([Math]::Round((Get-Item $OutPath).Length/1KB,1)) kB)"
}
finally {
    if ($conn.State -eq 'Open') { $conn.Close() }
}
