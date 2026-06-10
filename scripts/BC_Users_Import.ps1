# BC_Users_Import.ps1
# Zavede BC uzivatele z Users web service (OData) do SQL dbo.BCUser a z DB
# pregeneruje web/usermap.json (telemetricky GUID -> jmeno).
#
# Zdroj: BC Users (Page 9800) publikovany jako OData web service. Pole "Telemetry User ID"
#   (sloupec "ID telemetrie") = presne GUID, ktery emituje telemetrie do AppPageViews.
# Auth: Service Principal client-credentials (stejny SP jako modul B / ChangelogEntry).
# Users jsou tenant-wide -> staci jedna firma.
# Browser na OData endpoint ukaze Basic-auth dialog -> Zrusit; cte se jen pres SP.
#
# Prereq: deploynuta tabulka dbo.BCUser (sql\03_users.sql).
# Usage (na serveru jako svc):
#   pwsh -File scripts\BC_Users_Import.ps1

param(
    [string] $TenantId     = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId     = '4eda9e64-ead7-4aac-9631-ef4703c10135',   # BC_Telemetry_SP
    [string] $SecretTarget = 'BC_Telemetry_BCAPI',                     # Credential Manager target
    [string] $Environment  = 'Production',
    [string] $Company      = 'AXIMA_CZ_KVE',                           # libovolna firma (Users jsou tenant-wide)
    [string] $ServiceName  = 'Users',                                  # publikovany web service (Page 9800)
    [string] $SqlServer    = 'localhost',
    [string] $SqlDatabase  = 'BC_Telemetry',
    [string] $UserMapFile  = ''
)
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager

# usermap.json patri tam, odkud ho cte dashboard (web sluzba), NE vedle skriptu.
if (-not $UserMapFile) {
    $served = 'C:\Apps\BC_Telemetry_Web\usermap.json'
    if (Test-Path (Split-Path $served)) { $UserMapFile = $served }
    else { $UserMapFile = (Join-Path $PSScriptRoot '..\web\usermap.json') }
}

# -- OAuth2 client-credentials -> token (1:1 jako BC_ChangeLog_Import) --------
$secret = (Get-StoredCredential -Target $SecretTarget).Password
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
$tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
    client_id     = $ClientId
    client_secret = $plain
    scope         = 'https://api.businesscentral.dynamics.com/.default'
    grant_type    = 'client_credentials'
}
$headers = @{ Authorization = "Bearer $($tok.access_token)" }

# -- GET Users ----------------------------------------------------------------
$base = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$Environment/ODataV4"
$resp = Invoke-RestMethod -Headers $headers -Uri "$base/Company('$Company')/$ServiceName"
$users = $resp.value
if (-not $users -or $users.Count -eq 0) { throw "Users vratil 0 zaznamu" }

# -- auto-detekce nazvu OData poli (lisi se dle verze/jazyka) ------------------
$props = $users[0].PSObject.Properties.Name
function Pick($patterns) { foreach ($p in $patterns) { $h = $props | Where-Object { $_ -match $p } | Select-Object -First 1; if ($h) { return $h } } return $null }
$pSec  = Pick @('(?i)security')
$pTel  = Pick @('(?i)telemetr')
$pUsr  = Pick @('(?i)^user.?name','(?i)\buser_?name')
$pFull = Pick @('(?i)^full','(?i)full.?name')
$pMail = Pick @('(?i)auth.*mail','(?i)authentication')
$pStat = Pick @('(?i)^state','(?i)\bstate')
if (-not $pSec) { Write-Warning "Pole 'User Security ID' nenalezeno. Dostupna pole:"; $props | ForEach-Object { Write-Host "  - $_" }; throw "Chybi security id pole." }
if (-not $pTel) { Write-Warning "Pole 'Telemetry User ID' nenalezeno. Dostupna pole:"; $props | ForEach-Object { Write-Host "  - $_" }; throw "Pridej 'Telemetry User ID' na Page 9800." }
Write-Host "Pole: sec='$pSec' tel='$pTel' user='$pUsr' full='$pFull' mail='$pMail' state='$pStat' ($($users.Count) uzivatelu)"

function Clean([string]$v) { if ($null -eq $v) { return $null }; return ($v -replace '[{}]','').Trim() }

# -- SQL: staging -> MERGE dbo.BCUser -----------------------------------------
$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True"
$conn.Open()
try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
CREATE TABLE #BCUserStg (
    UserSecurityId NVARCHAR(36) NOT NULL, TelemetryUserId NVARCHAR(36) NULL,
    UserName NVARCHAR(132) NULL, FullName NVARCHAR(132) NULL,
    AuthEmail NVARCHAR(250) NULL, State NVARCHAR(20) NULL)
"@
    $cmd.ExecuteNonQuery() | Out-Null

    $dt = New-Object System.Data.DataTable
    foreach ($c in 'UserSecurityId','TelemetryUserId','UserName','FullName','AuthEmail','State') {
        $col = $dt.Columns.Add($c); $col.DataType = [string]; $col.AllowDBNull = $true
    }
    foreach ($u in $users) {
        $sec = Clean ([string]$u.$pSec)
        if ([string]::IsNullOrWhiteSpace($sec)) { continue }   # bez security id nemerge-ujeme
        $r = $dt.NewRow()
        $r['UserSecurityId']  = $sec
        $r['TelemetryUserId'] = [DBNull]::Value; if ($pTel) { $t = Clean([string]$u.$pTel); if ($t) { $r['TelemetryUserId'] = $t } }
        $r['UserName']        = [DBNull]::Value; if ($pUsr)  { $r['UserName']  = [string]$u.$pUsr }
        $r['FullName']        = [DBNull]::Value; if ($pFull) { $r['FullName']  = [string]$u.$pFull }
        $r['AuthEmail']       = [DBNull]::Value; if ($pMail) { $r['AuthEmail'] = [string]$u.$pMail }
        $r['State']           = [DBNull]::Value; if ($pStat) { $r['State']     = [string]$u.$pStat }
        $dt.Rows.Add($r)
    }
    $bulk = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
    $bulk.DestinationTableName = '#BCUserStg'
    foreach ($c in $dt.Columns) { $bulk.ColumnMappings.Add($c.ColumnName, $c.ColumnName) | Out-Null }
    $bulk.WriteToServer($dt)

    $merge = $conn.CreateCommand()
    $merge.CommandText = @"
MERGE dbo.BCUser AS t
USING #BCUserStg AS s ON t.UserSecurityId = s.UserSecurityId
WHEN MATCHED THEN UPDATE SET
    t.TelemetryUserId = s.TelemetryUserId, t.UserName = s.UserName, t.FullName = s.FullName,
    t.AuthEmail = s.AuthEmail, t.State = s.State, t.UpdatedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (UserSecurityId, TelemetryUserId, UserName, FullName, AuthEmail, State)
    VALUES (s.UserSecurityId, s.TelemetryUserId, s.UserName, s.FullName, s.AuthEmail, s.State);
SELECT @@ROWCOUNT;
"@
    $affected = [int]$merge.ExecuteScalar()
    Write-Host "dbo.BCUser MERGE: $affected radku ($($dt.Rows.Count) ze zdroje)."

    # -- pregeneruj usermap.json z DB (vw_UserMap), zachovej rucni edity -------
    $map = [ordered]@{}
    if (Test-Path $UserMapFile) {
        try { (Get-Content -Raw -Path $UserMapFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value } } catch {}
    }
    $q = $conn.CreateCommand(); $q.CommandText = 'SELECT UserId, Name FROM dbo.vw_UserMap'
    $rd = $q.ExecuteReader()
    while ($rd.Read()) { $map[[string]$rd['UserId']] = [string]$rd['Name'] }   # DB je autoritativni
    $rd.Close()

    $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 bez BOM (Node JSON.parse)
    [IO.File]::WriteAllText($UserMapFile, ($map | ConvertTo-Json -Depth 2), $enc)
    Write-Host "OK -> $UserMapFile ($($map.Count) jmen z dbo.vw_UserMap)"
}
finally { $conn.Close() }
