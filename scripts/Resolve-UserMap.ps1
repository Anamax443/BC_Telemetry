# Resolve-UserMap.ps1
# Naplni web/usermap.json mapovanim  telemetricky GUID -> jmeno  primo z BC.
#
# Zdroj: BC Users (Page 9800) publikovany jako OData web service. BC ma pole
#   "Telemetry User ID" (sloupec "ID telemetrie") = presne ten GUID, ktery emituje
#   telemetrie do AppPageViews (NE User Security ID, NE AAD object id).
# Auth: Service Principal client-credentials (stejny SP jako modul B / ChangelogEntry).
# Users jsou tenant-wide -> staci jedna firma.
#
# Browser na OData endpoint ukaze Basic-auth dialog (BC online ho neudela) -> Zrusit;
# cte se jen pres SP, presne jako modul B.
#
# Usage (na serveru jako svc, creds v Credential Manageru profilu svc):
#   pwsh -File scripts\Resolve-UserMap.ps1
#   pwsh -File scripts\Resolve-UserMap.ps1 -Company 'AXIMA_CZ_KVE' -ServiceName 'Users'

param(
    [string] $TenantId     = '2ecd5815-0eb9-4e9a-93be-ac58545cdca6',
    [string] $ClientId     = '4eda9e64-ead7-4aac-9631-ef4703c10135',   # BC_Telemetry_SP
    [string] $SecretTarget = 'BC_Telemetry_BCAPI',                     # Credential Manager target
    [string] $Environment  = 'Production',
    [string] $Company      = 'AXIMA_CZ_KVE',                           # libovolna firma (Users jsou tenant-wide)
    [string] $ServiceName  = 'Users',                                  # publikovany web service (Page 9800)
    [string] $OutFile      = (Join-Path $PSScriptRoot '..\web\usermap.json')
)
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager

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
$url  = "$base/Company('$Company')/$ServiceName"
$resp = Invoke-RestMethod -Headers $headers -Uri $url
$users = $resp.value
if (-not $users -or $users.Count -eq 0) { throw "Users vratil 0 zaznamu z $url" }

# -- detekce pole s telemetry ID (nazev obsahuje 'telemetr') ------------------
$props   = $users[0].PSObject.Properties.Name
$telProp = $props | Where-Object { $_ -match '(?i)telemetr' } | Select-Object -First 1
if (-not $telProp) {
    Write-Warning "Pole s Telemetry ID nenalezeno v OData. Dostupna pole:"
    $props | ForEach-Object { Write-Host "  - $_" }
    throw "Pridej 'Telemetry User ID' na Page 9800 (nebo dej vedet nazev pole)."
}
$nameProp = ($props | Where-Object { $_ -match '(?i)^full' } | Select-Object -First 1)
if (-not $nameProp) { $nameProp = ($props | Where-Object { $_ -match '(?i)user.?name' } | Select-Object -First 1) }
Write-Host "Pole: telemetry='$telProp'  name='$nameProp'  (firma $Company, $($users.Count) uzivatelu)"

# -- merge: zachovej rucni edity, BC je autoritativni pro klice ktere zna -----
$map = [ordered]@{}
if (Test-Path $OutFile) {
    try { (Get-Content -Raw -Path $OutFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value } } catch {}
}
$empty = '00000000-0000-0000-0000-000000000000'
$added = 0
foreach ($u in $users) {
    $gid = [string]$u.$telProp
    if ([string]::IsNullOrWhiteSpace($gid) -or $gid -eq $empty) { continue }
    $name = [string]$u.$nameProp
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '^user_') { $name = [string]$u.User_Name }
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if (-not $map.Contains($gid) -or $map[$gid] -ne $name) { $added++ }
    $map[$gid] = $name
}

$enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 bez BOM (Node JSON.parse)
[IO.File]::WriteAllText($OutFile, ($map | ConvertTo-Json -Depth 2), $enc)
Write-Host "OK -> $OutFile  ($($map.Count) jmen, z toho $added novych/zmenenych)"
