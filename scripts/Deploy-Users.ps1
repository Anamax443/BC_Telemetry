# Deploy-Users.ps1
# Nasadi na 10.8.2.225: dbo.BCUser (03_users.sql), BC_Users_Import + zmenene skripty,
# web (index.html + usermap.json), pak spusti denni task a vypise overeni.
#
# SPUSTET JAKO admintrnka (krok SQL = CREATE TABLE = DDL = sysadmin).
# Prepinace: -SkipCopy / -SkipSql / -SkipRun  (default = vse).
#
#   powershell -ExecutionPolicy Bypass -File scripts\Deploy-Users.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\Deploy-Users.ps1 -SkipRun   # bez spusteni tasku

param(
    [string] $Server   = '10.8.2.225',
    [string] $Database = 'BC_Telemetry',
    [string] $TaskName = 'BC_Telemetry_Daily',
    [string] $Src      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,   # koren repa
    [string] $AppShare = "\\$Server\BC_Telemetry",                              # = C:\Apps\BC_Telemetry
    [string] $WebDir   = "\\$Server\c$\Apps\BC_Telemetry_Web",
    [switch] $SkipCopy, [switch] $SkipSql, [switch] $SkipRun
)
$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# --- 1) kopie souboru ---------------------------------------------------------
if (-not $SkipCopy) {
    Step "1/3 Kopie souboru na $Server"
    $scripts = 'BC_Users_Import.ps1','Invoke-BCTelemetryDaily.ps1','BC_PageLog_Import.ps1','BC_AuthFail_Import.ps1'
    $sql     = '03_users.sql','deploy.cmd','deploy-full.sql'
    foreach ($f in $scripts) { Copy-Item (Join-Path $Src "scripts\$f") "$AppShare\scripts\" -Force; Write-Host "  scripts\$f" }
    foreach ($f in $sql)     { Copy-Item (Join-Path $Src "sql\$f")     "$AppShare\sql\"     -Force; Write-Host "  sql\$f" }
    foreach ($f in 'index.html','usermap.json') { Copy-Item (Join-Path $Src "web\$f") "$WebDir\" -Force; Write-Host "  web\$f -> $WebDir" }
} else { Step "1/3 Kopie PRESKOCENA" }

# --- 2) SQL DDL (dbo.BCUser + vw_UserMap) -------------------------------------
if (-not $SkipSql) {
    Step "2/3 SQL deploy 03_users.sql (DDL -> potreba admintrnka/sysadmin)"
    & sqlcmd -S $Server -E -b -d $Database -i (Join-Path $Src 'sql\03_users.sql')
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd selhal (exit $LASTEXITCODE) - bezi to jako admintrnka? Ma ucet DDL prava?" }
    Write-Host "  dbo.BCUser + vw_UserMap OK"
} else { Step "2/3 SQL PRESKOCEN" }

# --- 3) spustit denni task (import vc. uzivatelu, jako svc) --------------------
if (-not $SkipRun) {
    Step "3/3 Spousteni tasku $TaskName na $Server (bezi jako svc-bc-telemetry)"
    & schtasks /run /s $Server /tn $TaskName
    Write-Host "  task spusten - sleduj log behu (krok 'uzivatele' + 'snapshot')"
} else { Step "3/3 Spusteni tasku PRESKOCENO" }

# --- overeni ------------------------------------------------------------------
Step "Overeni (po dobehnuti tasku)"
Write-Host @"
  sqlcmd -S $Server -E -d $Database -Q "SELECT COUNT(*) AS users FROM dbo.BCUser; SELECT TOP 10 UserId,Name FROM dbo.vw_UserMap ORDER BY Name;"
  Dashboard: http://$Server:8080/  -> zalozka Uzivatele (Ctrl+F5), pruh 'Celkem SQL / cloud'
"@
