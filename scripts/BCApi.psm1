<#
.SYNOPSIS
    BCApi — sdilena vrstva pro cteni dat z BC cloudu (modul B, Users, sync-status).

.DESCRIPTION
    PROC EXISTUJE: v Business Central online plati limity na IDENTITU (service principal) —
    6000 pozadavku za poslednich 5 minut a 5 soucasne zpracovavanych — a vykon prostredi je
    sdileny se vsemi ostatnimi integracemi. Jakmile vedle telemetrie pobezi dalsi aplikace
    (BI refresh, vlastni appky), zacne BC obcas odpovidat 429 (zahlceni) nebo docasnou chybou.
    Bez osetreni takovy beh spadne uprostred importu a v logu je jen "Unauthorized/Bad Gateway".

    CO TATO VRSTVA DELA:
      * OAuth2 client-credentials token + obnova po 45 min i po 401 uprostred dlouheho behu
      * opakovani pozadavku pri 429 (respektuje hlavicku Retry-After) a pri chybach 5xx/timeoutu
      * vlastni brzda (pozadavku za minutu) — telemetrie nikdy nevycerpa svuj limit a zaroven
        zbytecne nezatezuje prostredi sdilene s ostatnimi aplikacemi
      * hlavicka Data-Access-Intent: ReadOnly — cteni jde na read-only repliku, primarni databaze
        BC zustava volna pro uzivatele
      * degradace misto padu: kdyz BC hlavicku nebo vyber sloupcu ($select) neprijme, zopakuje
        pozadavek bez nich a pokracuje
      * srozumitelny souhrn na konci behu (kolik pozadavku, kolik cekani, kolik zahlceni)

.NOTES
    Windows PowerShell 5.1 — denni wrapper spousti powershell.exe, ne pwsh.
    Ulozit jako UTF-8 s BOM + CRLF.
    Nepovinna konfigurace: C:\Apps\BC_Telemetry_Web\ops\bcapi.json
      { "requestsPerMinute": 90, "maxAttempts": 6, "timeoutSeconds": 300,
        "maxWaitSeconds": 120, "readOnlyIntent": true, "useSelect": true, "tokenMinutes": 45 }
#>

# Vychozi hodnoty — plati, kdyz ops\bcapi.json neexistuje nebo klic chybi.
$script:BcDefaults = [ordered]@{
    requestsPerMinute = 90     # vlastni strop rychlosti (limit BC = 6000 / 5 min na identitu)
    maxAttempts       = 6      # pokusu na jeden pozadavek (vcetne prvniho)
    timeoutSeconds    = 300    # strop na jeden pozadavek (stranka 5000 radku byva pomala)
    maxWaitSeconds    = 120    # strop jednoho cekani mezi pokusy
    readOnlyIntent    = $true  # cist z read-only repliky (setri primarni DB)
    useSelect         = $true  # stahovat jen potrebne sloupce
    tokenMinutes      = 45     # po jak dlouhe dobe obnovit token
}

$script:Bc = $null

function Get-BCApiConfig {
    [CmdletBinding()]
    param([string] $WebDir = 'C:\Apps\BC_Telemetry_Web')

    $cfg = [ordered]@{}
    foreach ($k in $script:BcDefaults.Keys) { $cfg[$k] = $script:BcDefaults[$k] }

    $file = Join-Path $WebDir 'ops\bcapi.json'
    if (Test-Path $file) {
        try {
            $j = Get-Content -Raw -Path $file | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($cfg.Contains($p.Name) -and $null -ne $p.Value) { $cfg[$p.Name] = $p.Value }
            }
        } catch {
            Write-Host "BC API: soubor ops\bcapi.json se nepodarilo precist ($($_.Exception.Message)) - pouzivam vychozi nastaveni."
        }
    }
    return $cfg
}

<#
.SYNOPSIS
    Zapise vysledek spojeni s BC do ops\bc-status.json (cte ho dashboard).
.DESCRIPTION
    PROC: web sluzba bezi jako LocalSystem a NEMA secret service principalu (ten je v Credential
    Manageru servisniho uctu), takze si spojeni s BC sama overit nemuze. Jediny, kdo s tenantem
    prokazatelne mluvi, jsou tyhle skripty — tak at po sobe necha stopu. Dashboard pak umi rict
    "napojeno, overeno v 06:57" misto "sluzba bezi" (coz o BC nevypovida nic).
    Zapisuje se i NEUSPECH, jinak by vypadek vypadal jako by se nic nedelo.
#>
function Write-BCApiStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $Ok,
        [string] $WebDir      = 'C:\Apps\BC_Telemetry_Web',
        [string] $TenantId,
        [string] $Environment,
        [string] $ClientId,
        [string] $Endpoint,
        [string] $ErrorText,
        [Nullable[int]] $Companies,
        [ValidateSet('import', 'manual')][string] $Source = 'import'
    )
    try {
        $opsDir = Join-Path $WebDir 'ops'
        if (-not (Test-Path $opsDir)) { New-Item -ItemType Directory -Path $opsDir -Force | Out-Null }
        $o = [ordered]@{
            ok          = $Ok
            checkedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            source      = $Source
            tenantId    = $TenantId
            environment = $Environment
            clientId    = $ClientId
            endpoint    = $Endpoint
            companies   = $Companies
            error       = $ErrorText
        }
        # POZOR: Set-Content -Encoding UTF8 pridava v PS 5.1 BOM a Node JSON.parse na nem spadne
        # (dashboard by pak porad hlasil "neovereno"). Ostatni ops JSON se pisou taky bez BOM.
        [IO.File]::WriteAllText((Join-Path $opsDir 'bc-status.json'),
            ($o | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # stav je jen informace pro dashboard — nikdy kvuli nemu neshazuj import
        Write-Host "BC API: stav spojeni se nepodarilo zapsat ($($_.Exception.Message))."
    }
}

# Odstrani $select z URL (pouziva se, kdyz ho endpoint neprijme).
function Remove-BCApiSelect {
    param([string] $Uri)
    $u = $Uri -replace '(?<=[?&])\$select=[^&]*&?', ''
    $u = $u -replace '[?&]$', ''
    return $u
}

# Prevede hlavicku Retry-After (sekundy nebo HTTP datum) na pocet sekund.
function ConvertTo-BCApiWait {
    param($RetryAfter, [double] $Fallback = 20, [double] $Max = 120)
    $sec = $Fallback
    if ($RetryAfter) {
        $n = 0
        if ([int]::TryParse([string]$RetryAfter, [ref]$n) -and $n -gt 0) {
            $sec = [double]$n
        } else {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse([string]$RetryAfter, [ref]$d)) {
                $diff = ($d.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds
                if ($diff -gt 0) { $sec = $diff }
            }
        }
    }
    if ($sec -gt $Max) { $sec = $Max }
    if ($sec -lt 1)    { $sec = 1 }
    return $sec
}

# Vytahne z chyby stavovy kod, Retry-After a citelnou hlasku (funguje v PS 5.1 i 7).
function Get-BCApiErrorInfo {
    param($Err)
    $o = [ordered]@{ Status = 0; RetryAfter = $null; Message = '' }

    $resp = $null
    try { $resp = $Err.Exception.Response } catch {}
    if ($resp) {
        try { $o.Status = [int]$resp.StatusCode } catch {}
        try {
            $hdrs = $resp.Headers
            if ($hdrs) {
                if ($hdrs -is [System.Net.WebHeaderCollection]) {
                    $o.RetryAfter = $hdrs['Retry-After']
                } else {
                    $v = $null
                    if ($hdrs.TryGetValues('Retry-After', [ref]$v)) { $o.RetryAfter = @($v)[0] }
                }
            }
        } catch {}
    }

    $msg = ''
    try { if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $msg = [string]$Err.ErrorDetails.Message } } catch {}
    if (-not $msg) { $msg = [string]$Err.Exception.Message }
    $msg = ($msg -replace '\s+', ' ').Trim()
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
    $o.Message = $msg
    return $o
}

# Vlastni brzda — drzi rozestup mezi pozadavky dle requestsPerMinute.
function Wait-BCApiSlot {
    $s = $script:Bc
    $rpm = [double]$s.Config.requestsPerMinute
    if ($rpm -le 0) { $s.LastRequest = Get-Date; return }
    $minGap = 60.0 / $rpm
    if ($s.LastRequest) {
        $elapsed = ((Get-Date) - $s.LastRequest).TotalSeconds
        if ($elapsed -lt $minGap) { Start-Sleep -Milliseconds ([int](($minGap - $elapsed) * 1000)) }
    }
    $s.LastRequest = Get-Date
}

# Token (client-credentials). -Force = vynutit novy (napr. po 401 uprostred behu).
function Get-BCApiHeaders {
    [CmdletBinding()]
    param([switch] $Force)

    $s = $script:Bc
    $stale = $true
    if ($s.Token -and $s.TokenTime) {
        $stale = (((Get-Date) - $s.TokenTime).TotalMinutes -ge [double]$s.Config.tokenMinutes)
    }
    if ($Force -or $stale) {
        $body = @{
            client_id     = $s.ClientId
            client_secret = $s.Secret
            scope         = 'https://api.businesscentral.dynamics.com/.default'
            grant_type    = 'client_credentials'
        }
        $uri = "https://login.microsoftonline.com/$($s.TenantId)/oauth2/v2.0/token"
        $ok = $false
        for ($i = 1; $i -le 3 -and -not $ok; $i++) {
            try {
                $t = Invoke-RestMethod -Method Post -Uri $uri -Body $body -TimeoutSec 60
                $s.Token = $t.access_token
                $s.TokenTime = Get-Date
                if ($Force) { $s.TokenRefreshes = $s.TokenRefreshes + 1 }
                $ok = $true
            } catch {
                if ($i -eq 3) {
                    throw "BC API: nepodarilo se ziskat prihlaseni (token) pro service principal $($s.ClientId): $($_.Exception.Message). Nejcastejsi pricina = vyprsely nebo spatne ulozeny secret v Credential Manageru."
                }
                Write-Host "  BC API: ziskani tokenu selhalo (pokus $i z 3), zkousim za 5 s."
                Start-Sleep -Seconds 5
            }
        }
    }
    $h = @{ Authorization = "Bearer $($s.Token)" }
    if ($s.ReadOnlyIntent) { $h['Data-Access-Intent'] = 'ReadOnly' }
    return $h
}

<#
.SYNOPSIS
    Zalozi relaci proti BC API (token, konfigurace, pocitadla). Volat jednou na zacatku skriptu.
#>
function Initialize-BCApiSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [Parameter(Mandatory)][string] $ClientId,
        [Parameter(Mandatory)][string] $SecretTarget,
        [string] $WebDir = 'C:\Apps\BC_Telemetry_Web',
        [string] $Label  = 'BC API',
        [string] $Environment,                                   # jen pro stav spojeni v dashboardu
        [string] $Endpoint,                                      # dtto (napr. .../Production/ODataV4)
        [ValidateSet('import', 'manual')][string] $StatusSource = 'import'
    )
    # spolecne udaje pro zapis stavu (at se nemusi opakovat u kazdeho volani)
    $stArgs = @{ WebDir = $WebDir; TenantId = $TenantId; Environment = $Environment
                 ClientId = $ClientId; Endpoint = $Endpoint; Source = $StatusSource }

    Import-Module CredentialManager -ErrorAction Stop
    $cred = Get-StoredCredential -Target $SecretTarget
    if (-not $cred) {
        $msg = "BC API: v Credential Manageru chybi zaznam '$SecretTarget' (secret service principalu). Musi byt ulozeny v profilu uctu, pod kterym uloha bezi."
        Write-BCApiStatus -Ok $false -ErrorText $msg @stArgs
        throw $msg
    }
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password))

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    $script:Bc = [ordered]@{
        TenantId = $TenantId; ClientId = $ClientId; Secret = $secret; Label = $Label
        Config = (Get-BCApiConfig -WebDir $WebDir)
        Token = $null; TokenTime = $null; LastRequest = $null
        ReadOnlyIntent = $true; SelectEnabled = $true
        IntentDropped = $false; SelectDropped = $false
        Requests = 0; Throttled = 0; Transient = 0; Retries = 0; WaitSeconds = 0.0; TokenRefreshes = 0
    }
    $script:Bc.ReadOnlyIntent = [bool]$script:Bc.Config.readOnlyIntent
    $script:Bc.SelectEnabled  = [bool]$script:Bc.Config.useSelect

    # Over hned, ze prihlaseni funguje (jinak spadne tady, ne uprostred importu) — a vysledek
    # rovnou zapis, at dashboard vi, jestli jsme na tenant napojeni.
    try {
        [void](Get-BCApiHeaders)
    } catch {
        Write-BCApiStatus -Ok $false -ErrorText $_.Exception.Message @stArgs
        throw
    }
    Write-BCApiStatus -Ok $true @stArgs

    $ro = 'ne'; if ($script:Bc.ReadOnlyIntent) { $ro = 'ano' }
    Write-Host ("BC API [{0}]: prihlaseno jako aplikace, brzda {1} pozadavku/min, cteni z read-only repliky: {2}, opakovani az {3}x." -f `
        $Label, $script:Bc.Config.requestsPerMinute, $ro, $script:Bc.Config.maxAttempts)
}

<#
.SYNOPSIS
    GET na BC API/OData s brzdou, opakovanim (429 / 5xx / vyprsely token) a degradaci.
.DESCRIPTION
    Vraci tentyz objekt jako Invoke-RestMethod, takze volajici skript se nemeni.
    Kdyz se pozadavek nepodari ani na maxAttempts pokusu, vyhodi chybu s citelnym popisem —
    beh skonci, ale watermark v SQL zustava, takze dalsi beh naveze presne tam, kde skoncil.
#>
function Invoke-BCApiGet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Uri)

    if (-not $script:Bc) { throw 'BC API: relace neni zalozena — nejdriv zavolej Initialize-BCApiSession.' }
    $s = $script:Bc
    $cfg = $s.Config
    $uriNow = $Uri
    if (-not $s.SelectEnabled) { $uriNow = Remove-BCApiSelect $uriNow }

    $attempt = 0
    $tokenRetried = $false
    while ($true) {
        $attempt++
        Wait-BCApiSlot
        try {
            $s.Requests = $s.Requests + 1
            $r = Invoke-RestMethod -Method Get -Uri $uriNow -Headers (Get-BCApiHeaders) -TimeoutSec ([int]$cfg.timeoutSeconds)
            if ($attempt -gt 1) { Write-Host "  BC API: povedlo se az na $attempt. pokus." }
            return $r
        } catch {
            $info = Get-BCApiErrorInfo $_
            $st = [int]$info.Status

            # Vyprsel token uprostred behu -> obnovit a zkusit znovu (nepocita se jako pokus).
            if ($st -eq 401 -and -not $tokenRetried) {
                $tokenRetried = $true; $attempt--
                Write-Host '  BC API: platnost prihlaseni vyprsela (401) — obnovuji token a opakuji.'
                [void](Get-BCApiHeaders -Force)
                continue
            }
            # Endpoint neprijal hlavicku read-only intent -> dal bez ni (jen jednou za beh).
            if ($st -eq 400 -and $s.ReadOnlyIntent) {
                $s.ReadOnlyIntent = $false; $s.IntentDropped = $true; $attempt--
                Write-Host '  BC API: endpoint neprijal hlavicku Data-Access-Intent — pokracuji bez ni (cteni pujde na hlavni databazi BC).'
                continue
            }
            # Endpoint neprijal vyber sloupcu -> stahuj cely zaznam (jen jednou za beh).
            if ($st -eq 400 -and $s.SelectEnabled -and $uriNow -match '\$select=') {
                $s.SelectEnabled = $false; $s.SelectDropped = $true
                $uriNow = Remove-BCApiSelect $uriNow
                $attempt--
                Write-Host '  BC API: endpoint neprijal vyber sloupcu ($select) — stahuji cely zaznam.'
                continue
            }

            $retriable = ($st -eq 429 -or $st -eq 408 -or $st -ge 500 -or $st -eq 0)
            if (-not $retriable -or $attempt -ge [int]$cfg.maxAttempts) {
                $what = 'spojeni selhalo'
                if ($st -gt 0) { $what = "HTTP $st" }
                $hint = ''
                if ($st -eq 429) { $hint = ' Limit BC je 6000 pozadavku / 5 min na identitu — pokud vedle telemetrie bezi dalsi aplikace, musi mit vlastni service principal.' }
                if ($st -eq 403) { $hint = ' Aplikace nema v BC prava na tato data (stranka Aplikace Microsoft Entra -> sady opravneni).' }
                throw ("BC API: pozadavek se nepodaril ({0}) ani na {1}. pokus — {2}.{3} URL: {4}" -f $what, $attempt, $info.Message, $hint, $uriNow)
            }

            if ($st -eq 429) {
                $s.Throttled = $s.Throttled + 1
                $w = ConvertTo-BCApiWait $info.RetryAfter 20 ([double]$cfg.maxWaitSeconds)
                Write-Host ("  BC API: Business Central docasne odmita dalsi pozadavky (429 = vycerpany limit rychlosti). Cekam {0} s, pokus {1} z {2}." -f `
                    [int]$w, ($attempt + 1), $cfg.maxAttempts)
            } else {
                $s.Transient = $s.Transient + 1
                $w = [Math]::Min([double]$cfg.maxWaitSeconds, 5 * [Math]::Pow(2, $attempt - 1))
                $w = $w + (Get-Random -Minimum 0 -Maximum 3)
                $what = $info.Message
                if ($st -gt 0) { $what = "HTTP $st" }
                Write-Host ("  BC API: docasny problem na strane BC ({0}). Cekam {1} s, pokus {2} z {3}." -f `
                    $what, [int]$w, ($attempt + 1), $cfg.maxAttempts)
            }
            $s.Retries = $s.Retries + 1
            $s.WaitSeconds = $s.WaitSeconds + $w
            Start-Sleep -Seconds ([int][Math]::Ceiling($w))
        }
    }
}

<#
.SYNOPSIS
    Jednoradkovy souhrn komunikace s BC — aby bylo i bez znalosti vnitrnosti videt, jak si beh vedl.
#>
function Get-BCApiSummary {
    if (-not $script:Bc) { return 'BC API: relace nebyla zalozena.' }
    $s = $script:Bc
    $t = ("BC API souhrn [{0}]: {1} pozadavku" -f $s.Label, $s.Requests)
    if ($s.Throttled -gt 0)      { $t = $t + (", {0}x odmitnuto kvuli limitu rychlosti (429)" -f $s.Throttled) }
    if ($s.Transient -gt 0)      { $t = $t + (", {0}x docasna chyba serveru" -f $s.Transient) }
    if ($s.TokenRefreshes -gt 0) { $t = $t + (", {0}x obnoveno prihlaseni" -f $s.TokenRefreshes) }
    if ($s.Retries -gt 0) { $t = $t + (", cekani pri opakovani celkem {0} s" -f [int]$s.WaitSeconds) }
    else                  { $t = $t + ', bez jedineho opakovani' }
    $t = $t + '.'
    if ($s.IntentDropped) { $t = $t + ' Endpoint neprijal hlavicku Data-Access-Intent, cteni tedy slo na hlavni databazi BC.' }
    if ($s.SelectDropped) { $t = $t + ' Endpoint neprijal vyber sloupcu, stahoval se cely zaznam.' }
    return $t
}

function Write-BCApiSummary { Write-Host (Get-BCApiSummary) }

Export-ModuleMember -Function Initialize-BCApiSession, Invoke-BCApiGet, Get-BCApiSummary,
    Write-BCApiSummary, Get-BCApiConfig, Get-BCApiHeaders, Write-BCApiStatus
