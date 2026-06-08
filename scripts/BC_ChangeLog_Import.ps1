<#
.SYNOPSIS
    Modul B — import BC Change Log Entries (audit kdo/co/kdy) přes OData do SQL.

.DESCRIPTION
    "Kdo vytvořil / změnil / SMAZAL záznam" — s REÁLNÝM uživatelem (BC User ID, ne pseudonym).
    Zdroj: BC Change Log Entries publikované jako OData web service (Page 405).
    Auth: OAuth2 client-credentials se Service Principalem (registrovaným v BC Admin Center →
    Microsoft Entra Apps). Watermark přes MAX(EntryNo) → inkrementální, idempotentní.

    PŘEDPOKLADY (operátor, jednorázově) — viz docs/modules.md Modul B:
      1. Change Log zapnutý + tabulky nakonfigurované (Insert/Modify/Delete)
      2. Page 405 publikovaná jako web service "ChangeLogEntries"
      3. SP registrovaný v BC Admin Center s permission setem na čtení Change Log

    ⚠ Názvy OData polí (entryNo, changeType, oldValue, primaryKeyField1…) se liší dle verze/
    web service — OVĚŘIT proti reálnému $metadata před produkčním během (otevři OData URL v prohlížeči).
#>
[CmdletBinding()]
param(
    [string] $TenantId    = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId    = '<BC API Service Principal AppId>',
    [string] $SecretTarget= 'BC_Telemetry_BCAPI',     # Credential Manager target (SP secret)
    [string] $Environment = 'Production',
    [string[]] $Companies = @(),                          # prázdné = VŠECHNY firmy (auto-list)
    [string] $ServiceName = 'ChangelogEntry',           # publikovaný web service (přesný název z BC)
    [string] $SqlServer   = 'localhost',
    [string] $SqlDatabase = 'BC_Telemetry'
)
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager

# ── OAuth2 client-credentials → token pro BC API ─────────────────────────────
$secret = (Get-StoredCredential -Target $SecretTarget).Password
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
$tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
    client_id     = $ClientId
    client_secret = $plain
    scope         = 'https://api.businesscentral.dynamics.com/.default'
    grant_type    = 'client_credentials'
}
$headers = @{ Authorization = "Bearer $($tok.access_token)" }

# ── SQL watermark ────────────────────────────────────────────────────────────
$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True"
$conn.Open()
try {
    $base = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$Environment/ODataV4"

    # Seznam firem — prázdný param = VŠECHNY (Change Log je per-firma, EntryNo je per-firma sekvence)
    $companyList = if ($Companies.Count) { $Companies } else {
        (Invoke-RestMethod -Headers $headers -Uri "$base/Company?`$select=Name").value | ForEach-Object { $_.Name }
    }
    Write-Host "Firmy ($($companyList.Count)): $($companyList -join ', ')"

    $inserted = 0
    foreach ($company in $companyList) {
        # per-firma watermark
        $cmdMax = $conn.CreateCommand()
        $cmdMax.CommandText = "SELECT ISNULL(MAX(EntryNo),0) FROM dbo.BCChangeLog WHERE CompanyName=@c"
        $cmdMax.Parameters.AddWithValue('@c', $company) | Out-Null
        $lastEntry = [int64]$cmdMax.ExecuteScalar()

        $url = "$base/Company('$company')/$ServiceName`?`$filter=entryNo gt $lastEntry&`$orderby=entryNo&`$top=5000"
        while ($url) {
            $resp = Invoke-RestMethod -Headers $headers -Uri $url
            foreach ($e in $resp.value) {
                # ⚠ MAPOVÁNÍ POLÍ — ověřit proti $metadata; níže typické názvy z Page 405:
                $c = $conn.CreateCommand()
                $c.CommandText = @"
INSERT INTO dbo.BCChangeLog (EntryNo,ChangedAt,UserId,CompanyName,TableNo,TableName,FieldNo,FieldName,ChangeType,PrimaryKey,OldValue,NewValue)
VALUES (@EntryNo,@ChangedAt,@UserId,@Company,@TableNo,@TableName,@FieldNo,@FieldName,@ChangeType,@PK,@Old,@New)
"@
                $c.Parameters.AddWithValue('@EntryNo',   [int64]$e.entryNo)                | Out-Null
                $c.Parameters.AddWithValue('@ChangedAt', [datetime]("$($e.changeDate) $($e.changeTime)")) | Out-Null
                $c.Parameters.AddWithValue('@UserId',    "$($e.userID)")                  | Out-Null
                $c.Parameters.AddWithValue('@Company',   $company)                        | Out-Null
                $c.Parameters.AddWithValue('@TableNo',   [int]$e.tableNo)                 | Out-Null
                $c.Parameters.AddWithValue('@TableName', "$($e.tableCaption)")            | Out-Null
                $c.Parameters.AddWithValue('@FieldNo',   [int]$e.fieldNo)                 | Out-Null
                $c.Parameters.AddWithValue('@FieldName', "$($e.fieldCaption)")            | Out-Null
                $c.Parameters.AddWithValue('@ChangeType',"$($e.typeOfChange)")            | Out-Null
                $c.Parameters.AddWithValue('@PK',        "$($e.primaryKey)")              | Out-Null
                $c.Parameters.AddWithValue('@Old',       "$($e.oldValue)")               | Out-Null
                $c.Parameters.AddWithValue('@New',       "$($e.newValue)")               | Out-Null
                try { $c.ExecuteNonQuery() | Out-Null; $inserted++ } catch { } # UX index = dedup
            }
            $url = $resp.'@odata.nextLink'
        }
    }
    Write-Host "Change Log: vloženo $inserted nových záznamů napříč $($companyList.Count) firmami."

    $cmdP = $conn.CreateCommand(); $cmdP.CommandText = 'EXEC dbo.usp_BCChangeLog_Purge @RetentionMonths=24'
    $cmdP.ExecuteNonQuery() | Out-Null
}
finally { if ($conn.State -eq 'Open') { $conn.Close() } }
