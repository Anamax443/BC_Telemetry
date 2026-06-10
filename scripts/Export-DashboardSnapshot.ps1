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

    $snapshot = [ordered]@{
        generatedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
        kpi            = $kpi
        userActivity   = Invoke-Sql $conn "SELECT TOP ($TopRows) * FROM dbo.vw_DashUserActivity ORDER BY TotalHits DESC"
        trimCandidates = Invoke-Sql $conn "SELECT TOP ($TopRows) * FROM dbo.vw_DashTrimCandidates ORDER BY UserName, PageName"
        trend          = Invoke-Sql $conn 'SELECT * FROM dbo.vw_DashTrend ORDER BY DateKey'
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
