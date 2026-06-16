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
    [string] $ClientId    = '4eda9e64-ead7-4aac-9631-ef4703c10135',   # BC_Telemetry_SP
    [string] $SecretTarget= 'BC_Telemetry_BCAPI',     # Credential Manager target (SP secret)
    [string] $Environment = 'Production',
    [string[]] $Companies = @(),                          # prázdné = VŠECHNY firmy (auto-list)
    [string] $ServiceName = 'ChangelogEntry',           # publikovaný web service (přesný název z BC)
    [string] $SqlServer   = 'localhost',
    [string] $SqlDatabase = 'BC_Telemetry',
    [string] $CompaniesFile = '',                         # vyber firem z dashboardu (Nastaveni)
    [int]    $ForwardRowsPerRun  = 150000,                # strop dosyncu k soucasnosti na firmu/beh (bezpecnostni pojistka proti zaseknuti)
    [int]    $BackfillRowsPerRun = 50000                  # strop backfillu historie na firmu/beh (0 = backfill vypnut)
)
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager

# Retence change logu z dashboardu (ops/retention.json), default 24 mesicu
$ChangeLogRetentionMonths = 24
$rf = 'C:\Apps\BC_Telemetry_Web\ops\retention.json'
if (Test-Path $rf) { try { $rc = Get-Content -Raw $rf | ConvertFrom-Json; if ($rc.changeLogMonths) { $ChangeLogRetentionMonths = [int]$rc.changeLogMonths } } catch {} }

# Vlozi stranku Change Log zaznamu (dedup pres UX index = swallow duplicit). Vraci pocet vlozenych.
function Add-ChangeLogPage {
    param($Conn, $Entries, [string]$Company)
    $n = 0
    foreach ($e in $Entries) {
        $c = $Conn.CreateCommand()
        $c.CommandText = @"
INSERT INTO dbo.BCChangeLog (EntryNo,ChangedAt,UserId,CompanyName,TableNo,TableName,FieldNo,FieldName,ChangeType,PrimaryKey,OldValue,NewValue)
VALUES (@EntryNo,@ChangedAt,@UserId,@Company,@TableNo,@TableName,@FieldNo,@FieldName,@ChangeType,@PK,@Old,@New)
"@
        $c.Parameters.AddWithValue('@EntryNo',   [int64]$e.Entry_No)         | Out-Null
        $c.Parameters.AddWithValue('@ChangedAt', [datetime]$e.Date_and_Time) | Out-Null
        $c.Parameters.AddWithValue('@UserId',    "$($e.User_ID)")            | Out-Null
        $c.Parameters.AddWithValue('@Company',   $Company)                   | Out-Null
        $c.Parameters.AddWithValue('@TableNo',   [int]$e.Table_No)           | Out-Null
        $c.Parameters.AddWithValue('@TableName', "$($e.Table_Caption)")      | Out-Null
        $c.Parameters.AddWithValue('@FieldNo',   [int]$e.Field_No)           | Out-Null
        $c.Parameters.AddWithValue('@FieldName', "$($e.Field_Caption)")      | Out-Null
        $c.Parameters.AddWithValue('@ChangeType',"$($e.Type_of_Change)")     | Out-Null
        $c.Parameters.AddWithValue('@PK',        "$($e.Primary_Key)")        | Out-Null
        $c.Parameters.AddWithValue('@Old',       "$($e.Old_Value)")          | Out-Null
        $c.Parameters.AddWithValue('@New',       "$($e.New_Value)")          | Out-Null
        try { $c.ExecuteNonQuery() | Out-Null; $n++ } catch { }
    }
    return $n
}

# changelog-companies.json patri tam, odkud ho cte/pise dashboard (web sluzba)
if (-not $CompaniesFile) {
    $served = 'C:\Apps\BC_Telemetry_Web\changelog-companies.json'
    if (Test-Path (Split-Path $served)) { $CompaniesFile = $served }
    else { $CompaniesFile = (Join-Path $PSScriptRoot '..\web\changelog-companies.json') }
}

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
    if ($Companies.Count) {
        $companyList = $Companies
    } else {
        $allNames = @((Invoke-RestMethod -Headers $headers -Uri "$base/Company?`$select=Name").value | ForEach-Object { $_.Name })
        # nacti vyber z dashboardu (Nastaveni) + persistuj seznam VSECH firem (pro UI checkboxy)
        $cfg = $null
        if (Test-Path $CompaniesFile) { try { $cfg = Get-Content -Raw -Path $CompaniesFile | ConvertFrom-Json } catch {} }
        $enabled = $null
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'enabled') -and $null -ne $cfg.enabled) { $enabled = @($cfg.enabled) }
        $out = [ordered]@{ all = $allNames; enabled = $enabled }
        try { [IO.File]::WriteAllText($CompaniesFile, ($out | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false))) }
        catch { Write-Host "WARN: nelze zapsat $CompaniesFile : $($_.Exception.Message)" }
        if ($null -ne $enabled) {
            $companyList = @($allNames | Where-Object { $enabled -contains $_ })
            Write-Host "Vyber firem (Nastaveni): $($companyList.Count) z $($allNames.Count)"
        } else {
            $companyList = $allNames
        }
    }
    Write-Host "Firmy ($($companyList.Count)): $($companyList -join ', ')"

    # Strategie (newest-first + backfill, gap-free, bez nutnosti resetu):
    #   Phase 0: prazdna firma -> seed NEJNOVEJSIM blokem (orderby desc), aby se dnesek ukazal hned.
    #   Phase A: dosync k SOUCASNOSTI -> Entry_No gt MAX vzestupne, re-query az do vycerpani (gap-free).
    #   Phase B: backfill HISTORIE -> Entry_No lt MIN sestupne, bounded -BackfillRowsPerRun (gap-free).
    # MAX/MIN drzi horni i dolni hranu souvisleho rozsahu -> zadne diry.
    $inserted = 0
    function Get-MinMax($conn, $company) {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT ISNULL(MAX(EntryNo),0), ISNULL(MIN(EntryNo),0), COUNT_BIG(*) FROM dbo.BCChangeLog WHERE CompanyName=@c"
        $cmd.Parameters.AddWithValue('@c', $company) | Out-Null
        $r = $cmd.ExecuteReader(); [void]$r.Read()
        $o = [pscustomobject]@{ Max=[int64]$r.GetValue(0); Min=[int64]$r.GetValue(1); Count=[int64]$r.GetValue(2) }
        $r.Close(); return $o
    }
    foreach ($company in $companyList) {
        $svc = "$base/Company('$company')/$ServiceName"
        $mm = Get-MinMax $conn $company

        # Phase 0 — prazdna firma: seed nejnovejsim blokem
        if ($mm.Count -eq 0) {
            $resp = Invoke-RestMethod -Headers $headers -Uri "$svc`?`$orderby=Entry_No desc&`$top=5000"
            $inserted += (Add-ChangeLogPage $conn @($resp.value) $company)
            $mm = Get-MinMax $conn $company
        }

        # Phase A — dosync k soucasnosti (vzestupne nad MAX), bounded (pojistka proti zaseknuti)
        $cursor = $mm.Max; $fwd = 0
        while ($fwd -lt $ForwardRowsPerRun) {
            $resp = Invoke-RestMethod -Headers $headers -Uri "$svc`?`$filter=Entry_No gt $cursor&`$orderby=Entry_No&`$top=5000"
            $page = @($resp.value); if (-not $page.Count) { break }
            $inserted += (Add-ChangeLogPage $conn $page $company); $fwd += $page.Count
            $cursor = [int64]($page | Measure-Object -Property Entry_No -Maximum).Maximum
        }

        # Phase B — backfill historie (sestupne pod MIN, bounded)
        $bf = 0
        if ($BackfillRowsPerRun -gt 0 -and $mm.Min -gt 1) {
            $cursor = $mm.Min
            while ($bf -lt $BackfillRowsPerRun) {
                $resp = Invoke-RestMethod -Headers $headers -Uri "$svc`?`$filter=Entry_No lt $cursor&`$orderby=Entry_No desc&`$top=5000"
                $page = @($resp.value); if (-not $page.Count) { break }
                $inserted += (Add-ChangeLogPage $conn $page $company); $bf += $page.Count
                $cursor = [int64]($page | Measure-Object -Property Entry_No -Minimum).Minimum
            }
        }
        Write-Host "  $company : forward +$fwd, backfill +$bf (max=$($mm.Max), min=$($mm.Min))"
    }
    Write-Host "Change Log: vloženo $inserted nových záznamů napříč $($companyList.Count) firmami."

    $cmdP = $conn.CreateCommand(); $cmdP.CommandText = 'EXEC dbo.usp_BCChangeLog_Purge @RetentionMonths=@rm'
    $cmdP.Parameters.AddWithValue('@rm', $ChangeLogRetentionMonths) | Out-Null
    $cmdP.ExecuteNonQuery() | Out-Null
}
finally { if ($conn.State -eq 'Open') { $conn.Close() } }
