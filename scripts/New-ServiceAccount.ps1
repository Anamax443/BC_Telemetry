<#
.SYNOPSIS
    Založí doménový servisní účet svc-bc-telemetry "ve stejném duchu" jako svc-itdashboard.

.DESCRIPTION
    Naklonuje umístění (OU) a service-account flagy z existujícího vzorového účtu
    (default svc-itdashboard): PasswordNeverExpires, CannotChangePassword, Enabled.
    Tím nový účet padne do stejné OU se stejnou konvencí jako stávající ITDashboard účet.

    Spustit na řadiči domény (nebo stroji s RSAT) jako Domain Admin.
    Idempotentní: pokud účet už existuje, nic nemění — jen vypíše DN a login pro deploy.

.NOTES
    Vyžaduje modul ActiveDirectory (RSAT; na DC je přítomen).

    ⚠ GPO AllSigned: pokud doména vynucuje AllSigned a blokuje spuštění .ps1, zkopíruj
      obsah skriptu do interaktivní *elevated* PowerShell konzole (ručně vložené/napsané
      příkazy AllSigned NEřeší — jen soubory .ps1), nebo skript podepiš interním cert.

.EXAMPLE
    .\New-ServiceAccount.ps1
        # založí svc-bc-telemetry, OU + flagy převezme z svc-itdashboard

.EXAMPLE
    .\New-ServiceAccount.ps1 -OUPath 'OU=Service Accounts,DC=axinetwork,DC=loc'
        # explicitní OU (když vzorový účet nechceš použít)
#>
[CmdletBinding()]
param(
    [string] $SamAccountName  = 'svc-bc-telemetry',
    [string] $TemplateAccount = 'svc-itdashboard',   # vzor: stejná OU + flagy
    [string] $DisplayName     = 'svc-bc-telemetry',
    [string] $Description      = 'Service account for BC_Telemetry (Azure/BC telemetry import + SQL)',
    [string] $OUPath          = ''                    # prázdné = převzít OU z $TemplateAccount
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain    = Get-ADDomain
$netbios   = $domain.NetBIOSName       # např. AXINETWORK
$upnSuffix = $domain.DNSRoot           # např. axinetwork.loc

# ── Idempotence ──────────────────────────────────────────────────────────────
$existing = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Účet '$SamAccountName' už existuje: $($existing.DistinguishedName)" -ForegroundColor Yellow
    Write-Host "Login pro deploy/scheduler:  $netbios\$SamAccountName"
    return
}

# ── OU z vzorového účtu (ve stejném duchu jako svc-itdashboard) ───────────────
if (-not $OUPath) {
    $tmpl = Get-ADUser -Filter "SamAccountName -eq '$TemplateAccount'" -ErrorAction SilentlyContinue
    if (-not $tmpl) {
        throw "Vzorový účet '$TemplateAccount' nenalezen a -OUPath nezadán. " +
              "Zadej -OUPath 'OU=...,DC=axinetwork,DC=loc'."
    }
    # DistinguishedName bez 'CN=...,' prefixu = rodičovská OU
    $OUPath = ($tmpl.DistinguishedName -split ',', 2)[1]
    Write-Host "OU převzata z '$TemplateAccount':  $OUPath"
}

# ── Heslo (interaktivně, nikam se neukládá) ───────────────────────────────────
$pw1 = Read-Host "Zadej heslo pro $SamAccountName" -AsSecureString
$pw2 = Read-Host "Zopakuj heslo"                   -AsSecureString
$p1  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
$p2  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
if ($p1 -ne $p2) { throw "Hesla se neshodují — nic nevytvořeno." }

# ── Vytvoření účtu (splatting — odolné vůči kopírování do konzole) ────────────
$adParams = @{
    Name                 = $DisplayName
    SamAccountName       = $SamAccountName
    UserPrincipalName    = "$SamAccountName@$upnSuffix"
    DisplayName          = $DisplayName
    Description          = $Description
    Path                 = $OUPath
    AccountPassword      = $pw1
    Enabled              = $true
    PasswordNeverExpires = $true
    CannotChangePassword = $true
}
New-ADUser @adParams

$created = Get-ADUser -Identity $SamAccountName -Properties DistinguishedName
Write-Host ""
Write-Host "✔ Vytvořen: $($created.DistinguishedName)" -ForegroundColor Green
Write-Host "  Login pro deploy / scheduler:  $netbios\$SamAccountName" -ForegroundColor Green
Write-Host ""
Write-Host "── Další kroky (na serveru 10.8.2.225) ──────────────────────────────"
Write-Host "  1. User Rights pro $netbios\$SamAccountName (GPO nebo secpol.msc):"
Write-Host "       'Log on as a service'  +  'Log on as a batch job'"
Write-Host "  2. SQL práva (vytvoří login+user+role+EXECUTE):"
Write-Host "       sql\deploy.cmd localhost `"$netbios\$SamAccountName`""
Write-Host "  3. Secret do Credential Manageru V PROFILU účtu (Cred Manager je per-user)"
Write-Host "     — přes PsExec -u $netbios\$SamAccountName -p <heslo> powershell:"
Write-Host "       New-StoredCredential -Target BC_Telemetry_SP    -UserName <client-id> -Password <secret> -Persist LocalMachine"
Write-Host "       New-StoredCredential -Target BC_Telemetry_BCAPI -UserName <client-id> -Password <secret> -Persist LocalMachine"
Write-Host "  4. Scheduler:"
Write-Host "       scripts\Register-ScheduledTask.ps1 -RunAs `"$netbios\$SamAccountName`""
