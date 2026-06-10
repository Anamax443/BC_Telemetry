<#
.SYNOPSIS
    Inkrementální import BC telemetrie (page views) z Azure Log Analytics do SQL.

.DESCRIPTION
    Stáhne page views interaktivních uživatelů (Web client) z Application Insights /
    Log Analytics Workspace a vloží nové záznamy do dbo.BCPageLog (DB co-located na 10.8.2.225).

    Verze 1.1 — zapracována oponentura 2026-06-08:
      #2 watermark   -> dynamický KQL `where timestamp > lastTs`, dedup přes MERGE
      #3 over-fetch  -> stahuje jen od posledního importu, ne fixních 90 dní
      #4 atomicita   -> try/catch/finally + staging tabulka + MERGE (vše-nebo-nic)
      #5 auth        -> Service Principal (neinteraktivní), secret z Credential Manageru
      #6 výkon       -> SqlBulkCopy místo řádkového INSERT
      #7 retence     -> volání usp_BCPageLog_Purge po úspěšném importu

    Umístění:  C:\Scripts\BC_PageLog_Import.ps1
    Spouští:   Task Scheduler jako AXINETWORK\svc-bc-telemetry (viz Register-ScheduledTask.ps1)

.NOTES
    Vyžaduje moduly: Az.Accounts, Az.OperationalInsights
        Install-Module Az.Accounts, Az.OperationalInsights -Scope AllUsers
#>

#requires -Modules Az.Accounts, Az.OperationalInsights

[CmdletBinding()]
param(
    [string] $WorkspaceId  = '484e3038-d41f-4c92-991c-cb71ecb54590',  # DefaultWorkspace-…-WEU
    [string] $TenantId     = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId     = '4eda9e64-ead7-4aac-9631-ef4703c10135',  # BC_Telemetry_SP
    [string] $SqlServer    = 'localhost',   # DB co-located na 10.8.2.225 (B-S-W-SQL-04)
    [string] $SqlDatabase  = 'BC_Telemetry',
    # Cílový generic credential v Windows Credential Manageru, který drží SP client secret.
    # Vytvoření: cmdkey /generic:BC_Telemetry_SP /user:<ClientId> /pass:<secret>
    [string] $SecretTarget = 'BC_Telemetry_SP',
    [int]    $RetentionMonths = 6,
    [int]    $MaxRetries    = 3
)

$ErrorActionPreference = 'Stop'

# region ── Logging ──────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "$([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) [$Level] $Message"
    Write-Host $line
    # Duplicitně do Application Event Logu pro monitoring (oponentura 🟢#1)
    if ($Level -ne 'INFO') {
        $type = if ($Level -eq 'ERROR') { 'Error' } else { 'Warning' }
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('BC_Telemetry')) {
                New-EventLog -LogName Application -Source 'BC_Telemetry' -ErrorAction SilentlyContinue
            }
            Write-EventLog -LogName Application -Source 'BC_Telemetry' -EntryType $type -EventId 1000 -Message $Message -ErrorAction SilentlyContinue
        } catch { }
    }
}
# endregion

# region ── Tajemství z Credential Manageru ─────────────────────────────────
function Get-StoredSecret {
    param([string]$Target)
    # Čte generic credential bez ukládání hesla v plaintextu ve skriptu.
    $cred = cmdkey /list:$Target 2>$null
    if (-not $cred) { throw "Credential '$Target' nenalezen v Credential Manageru." }
    # cmdkey neumí vrátit heslo; použijeme CredentialManager modul, pokud je k dispozici.
    if (Get-Module -ListAvailable -Name CredentialManager) {
        Import-Module CredentialManager
        return (Get-StoredCredential -Target $Target).Password
    }
    throw "Modul CredentialManager není nainstalován (Install-Module CredentialManager)."
}
# endregion

$conn = $null
try {
    Write-Log '=== Spuštění importu BC_PageLog ==='

    # region ── 01 Azure auth (Service Principal, neinteraktivní) ─────────────
    $secureSecret = Get-StoredSecret -Target $SecretTarget
    $spCred = New-Object System.Management.Automation.PSCredential ($ClientId, $secureSecret)
    Connect-AzAccount -ServicePrincipal -Credential $spCred -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null
    Write-Log 'Azure: přihlášeno přes Service Principal.'
    # endregion

    # region ── 02 SQL připojení + watermark ─────────────────────────────────
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
    $conn.Open()

    $cmdMax = $conn.CreateCommand()
    $cmdMax.CommandText = "SELECT ISNULL(MAX(Timestamp), '2000-01-01') FROM dbo.BCPageLog"
    $lastImport = [DateTime]$cmdMax.ExecuteScalar()
    $lastIso    = $lastImport.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    Write-Log "Watermark — poslední importovaný záznam: $lastIso (UTC)"
    # endregion

    # region ── 03 KQL — stahuje jen NOVÉ záznamy od watermarku ───────────────
    # Log Analytics schéma (AppPageViews), ověřeno na reálných datech 2026-06-08:
    #  - identita uživatele = UserId (pseudonymní GUID, NE AAD object id — Entra ho nezná,
    #    ověřeno 404; UserAuthenticatedId prázdný, aadUserId neexistuje). Jméno NELZE získat
    #    z Graphu; mapuje se korelací (Entra sign-in logy / marker page) do dbo.BCUserMap.
    #    Do té doby UserName = GUID; pro role-mining stačí grupovat podle GUID.
    #  - BC custom dimensions jsou v Properties.* (ne customDimensions)
    #  - interaktivní klienti = Desktop / WebClient (NE "Web"); Background ap. vyřazeno
    $query = @"
AppPageViews
| where TimeGenerated > datetime($lastIso)
| where tostring(Properties.clientType) in ('WebClient','Web','Desktop','Tablet','Phone')
| extend userId      = tostring(UserId)
| extend userName    = tostring(UserId)
| extend pageId      = tostring(Properties.alObjectId)
| extend pageName    = tostring(Properties.alObjectName)
| extend companyName = tostring(Properties.companyName)
| project timestamp = TimeGenerated, userId, userName, pageId, pageName, companyName
| order by timestamp asc
"@

    # Retry s exponenciálním čekáním (oponentura 🟢#2 — rate limiting)
    $attempt = 0
    do {
        $attempt++
        try {
            $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query
            break
        } catch {
            if ($attempt -ge $MaxRetries) { throw }
            $wait = [Math]::Pow(2, $attempt) * 5
            Write-Log "Azure dotaz selhal (pokus $attempt/$MaxRetries): $($_.Exception.Message). Čekám $wait s." 'WARN'
            Start-Sleep -Seconds $wait
        }
    } while ($attempt -lt $MaxRetries)

    $data = @($result.Results)
    Write-Log "Staženo $($data.Count) nových záznamů z Azure."
    if ($data.Count -eq 0) {
        Write-Log '=== Žádná nová data — import dokončen ==='
        return
    }
    # endregion

    # region ── 04 SqlBulkCopy do staging + MERGE (atomicky) ──────────────────
    $tran = $conn.BeginTransaction()
    try {
        # Staging tabulka v rámci transakce
        $cmdStage = $conn.CreateCommand(); $cmdStage.Transaction = $tran
        $cmdStage.CommandText = @"
CREATE TABLE #Staging (
    Timestamp DATETIME2(3) NOT NULL, UserId NVARCHAR(100) NOT NULL,
    UserName NVARCHAR(200), PageId NVARCHAR(50), PageName NVARCHAR(200),
    CompanyName NVARCHAR(100))
"@
        $cmdStage.ExecuteNonQuery() | Out-Null

        # Naplnit DataTable (PS 5.1-safe: žádné if-expression přiřazení)
        $dt = New-Object System.Data.DataTable
        foreach ($colName in 'Timestamp','UserId','UserName','PageId','PageName','CompanyName') {
            $col = $dt.Columns.Add($colName)
            if ($colName -eq 'Timestamp') { $col.DataType = [DateTime] } else { $col.DataType = [string] }
            $col.AllowDBNull = $true
        }
        foreach ($row in $data) {
            $r = $dt.NewRow()
            $r['Timestamp']   = [DateTime]$row.timestamp
            $r['UserId']      = [DBNull]::Value; if ($row.userId)      { $r['UserId']      = $row.userId }
            $r['UserName']    = [DBNull]::Value; if ($row.userName)    { $r['UserName']    = $row.userName }
            $r['PageId']      = [DBNull]::Value; if ($row.pageId)      { $r['PageId']      = $row.pageId }
            $r['PageName']    = [DBNull]::Value; if ($row.pageName)    { $r['PageName']    = $row.pageName }
            $r['CompanyName'] = [DBNull]::Value; if ($row.companyName) { $r['CompanyName'] = $row.companyName }
            $dt.Rows.Add($r)
        }

        $bulk = New-Object System.Data.SqlClient.SqlBulkCopy($conn, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $tran)
        $bulk.DestinationTableName = '#Staging'
        $bulk.BatchSize = 5000
        foreach ($c in $dt.Columns) { $bulk.ColumnMappings.Add($c.ColumnName, $c.ColumnName) | Out-Null }
        $bulk.WriteToServer($dt)
        Write-Log "Staging naplněn: $($dt.Rows.Count) řádků."

        # MERGE — dedup přes (Timestamp, UserId, PageId); idempotentní vůči re-importu
        $cmdMerge = $conn.CreateCommand(); $cmdMerge.Transaction = $tran
        $cmdMerge.CommandText = @"
INSERT INTO dbo.BCPageLog (Timestamp, UserId, UserName, PageId, PageName, CompanyName)
SELECT s.Timestamp, s.UserId, s.UserName, s.PageId, s.PageName, s.CompanyName
FROM #Staging s
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.BCPageLog b
    WHERE b.Timestamp = s.Timestamp AND b.UserId = s.UserId
      AND ISNULL(b.PageId,'') = ISNULL(s.PageId,'')
);
SELECT @@ROWCOUNT;
"@
        $inserted = [int]$cmdMerge.ExecuteScalar()
        $tran.Commit()
        Write-Log "=== Import dokončen — vloženo $inserted nových záznamů ==="
    } catch {
        $tran.Rollback()
        Write-Log "Import ROLLBACK — transakce vrácena, žádná data neuložena. $($_.Exception.Message)" 'ERROR'
        throw
    }
    # endregion

    # region ── 05 Rollup do agregátů (škála: miliony raw → malé agregáty) ────
    $cmdRollup = $conn.CreateCommand()
    $cmdRollup.CommandText = 'EXEC dbo.usp_BCPageLog_Rollup'
    $cmdRollup.CommandTimeout = 600
    $cmdRollup.ExecuteNonQuery() | Out-Null
    Write-Log 'Rollup do dbo.BCPageDaily dokončen.'
    # endregion

    # region ── 06 Retence ───────────────────────────────────────────────────
    $cmdPurge = $conn.CreateCommand()
    $cmdPurge.CommandText = 'EXEC dbo.usp_BCPageLog_Purge @RetentionMonths'
    $cmdPurge.Parameters.AddWithValue('@RetentionMonths', $RetentionMonths) | Out-Null
    $cmdPurge.ExecuteNonQuery() | Out-Null
    Write-Log "Retence: záznamy starší $RetentionMonths měsíců smazány."
    # endregion
}
catch {
    Write-Log "FATÁLNÍ CHYBA importu: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
    Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
}
