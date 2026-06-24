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

    # Stav SQL serveru/DB (zalozka Databaze)
    $dbInfo = $null
    try {
        $dbInfo = (Invoke-Sql $conn @"
SELECT CONVERT(varchar(30),SERVERPROPERTY('ProductVersion')) AS Version,
       CONVERT(varchar(80),SERVERPROPERTY('Edition')) AS Edition,
       d.recovery_model_desc AS Recovery, d.state_desc AS State,
       d.collation_name AS Collation, CONVERT(int,d.compatibility_level) AS CompatLevel,
       CONVERT(varchar(19),d.create_date,120) AS Created
FROM sys.databases d WHERE d.name = DB_NAME()
"@)[0]
    } catch { }

    # Tabulky: pocet radku + velikost (MB) — sys catalog (cte i db_datareader)
    $dbTables = @()
    try {
        $dbTables = Invoke-Sql $conn @"
SELECT t.name AS TableName,
  (SELECT ISNULL(SUM(p2.rows),0) FROM sys.partitions p2 WHERE p2.object_id=t.object_id AND p2.index_id IN (0,1)) AS [Rows],
  CAST((SELECT ISNULL(SUM(au.total_pages),0) FROM sys.partitions p JOIN sys.allocation_units au ON au.container_id=p.partition_id WHERE p.object_id=t.object_id)*8/1024.0 AS decimal(18,1)) AS TotalMB
FROM sys.tables t WHERE t.is_ms_shipped = 0
ORDER BY TotalMB DESC
"@
    } catch { }

    $snapshot = [ordered]@{
        generatedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
        kpi            = $kpi
        sync           = $sync
        dbSize         = $dbSize
        dbInfo         = $dbInfo
        dbTables       = $dbTables
        changeLogByCompany = $clByCompany
        # LastUsed s časem: agregát vw_DashUserActivity má jen DATE (MAX(DateKey)) → čas je jen v raw dbo.BCPageLog.
        # MAX(Timestamp) z raw (covering index IX_BCPageLog_UserName_Timestamp) → CONVERT(...,120) jako string,
        # jinak by ho Invoke-Sql usekl na yyyy-MM-dd. COALESCE na DateKey (půlnoc) pro řádky mimo 6měs. retenci raw.
        userActivity   = Invoke-Sql $conn @"
SELECT TOP ($TopRows) a.UserName, a.PageId, a.PageName, a.CompanyName, a.TotalHits,
  CONVERT(varchar(19), COALESCE(r.LastSeen, CAST(a.LastUsed AS datetime2(0))), 120) AS LastUsed
FROM dbo.vw_DashUserActivity a
LEFT JOIN (
  SELECT UserName, ISNULL(PageId,'?') AS PageId, ISNULL(CompanyName,'?') AS CompanyName, MAX(Timestamp) AS LastSeen
  FROM dbo.BCPageLog
  GROUP BY UserName, ISNULL(PageId,'?'), ISNULL(CompanyName,'?')
) r ON r.UserName = a.UserName AND r.PageId = a.PageId AND r.CompanyName = a.CompanyName
ORDER BY a.TotalHits DESC
"@
        trend          = Invoke-Sql $conn 'SELECT * FROM dbo.vw_DashTrend ORDER BY DateKey'
        trendByCompany = Invoke-Sql $conn 'SELECT DateKey, CompanyName, SUM(Hits) AS Hits, COUNT(DISTINCT UserName) AS Users FROM dbo.BCPageDaily GROUP BY DateKey, CompanyName ORDER BY DateKey'
        authFails      = Invoke-Sql $conn "SELECT TOP ($TopRows) DateKey, UserName, ObjectId, ObjectName, Failures FROM dbo.BCAuthFailDaily ORDER BY DateKey DESC, Failures DESC"
        changeLog      = Invoke-Sql $conn "SELECT TOP ($TopRows) CONVERT(varchar(19),ChangedAt,120) AS ChangedAt, UserId, CompanyName, ChangeType, TableNo, TableName, FieldNo, FieldName, PrimaryKey, OldValue, NewValue FROM dbo.BCChangeLog ORDER BY ChangedAt DESC"
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
