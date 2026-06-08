# Deploy dashboardu na 10.8.2.225 (B-S-W-SQL-04)

Hostování admin dashboardu **co-located se SQL serverem**. Výhoda: snapshot exportér
běží proti `localhost` SQL — žádný síťový hop, žádný file share.

```
10.8.2.225 (B-S-W-SQL-04)
├── SQL Server                 ← dbo.BCPageDaily, vw_Dash*  (pokud je BC_Telemetry DB zde)
├── Task Scheduler
│     └── Export-DashboardSnapshot.ps1  → C:\inetpub\bc-telemetry\data.json
└── IIS site "bc-telemetry"    → servíruje index.html + data.json (anonymně, bez loginu)
        http://10.8.2.225:8080/   ← whitelist = firewall rule remoteip (formální)
```

## 1 · IIS hosting (statika — GPO AllSigned se NETÝKÁ)

IIS servíruje jen soubory, žádný PowerShell se nespouští → GPO ExecutionPolicy je tu irelevantní.
Setup přes `appcmd.exe` / `dism` (cmd, ne PS), jako Administrator na 10.8.2.225:

```bat
scripts\deploy-iis.cmd
```

Pak nakopírovat [web/index.html](../web/index.html) do `C:\inetpub\bc-telemetry\`.

**Přístupový model — bez přihlašování, formální IP whitelist (jako ITDashboard):**
- **Žádný login, žádná auth** — Anonymous ON, lokální uživatel jen otevře URL.
- **Whitelist = jedna Windows Firewall rule** `"BC Telemetry Dashboard (8080)"`, jejíž `remoteip`
  seznam definuje povolené IP / rozsahy. Source of truth je ta rule (stejně jako ITDashboard
  `getAllowedIPs` / `setAllowedIPs` čtou/píší `Get/Set-NetFirewallRule -RemoteAddress`).
  Nastaví `deploy-iis.cmd` (proměnná `WHITELIST`, default `10.8.0.0/16`).
- **Změna whitelistu** kdykoliv: `scripts\Set-DashboardWhitelist.cmd "10.8.2.0/24,10.9.0.0/16"`.

> **Je to formální / visibility gate, ne security boundary** — přesně jak to má ITDashboard
> ve vlastním kódu okomentované. Firewall *allow* rule platí jen když je **Domain profil Enabled**.
> Na live ITDashboard serveru je Domain profil `Enabled=False` → rule je OS-level inertní a omezení
> je čistě formální (port je fakticky dostupný komukoliv v doméně). To odpovídá zadání „whitelist
> jen formálně omezuje zobrazení". Pokud by se někdy chtělo **tvrdé** vynucení, zapnout Domain
> profil nebo doplnit IIS ipSecurity — ale to teď není cílem.

## 2 · Snapshot export — POZOR na GPO AllSigned ⚠

Tady je jediný reálný háček. `Export-DashboardSnapshot.ps1` (i `BC_PageLog_Import.ps1`) jsou
PowerShell a běží v Task Scheduleru na doménovém serveru, kde **GPO vynucuje ExecutionPolicy = AllSigned**.
`-ExecutionPolicy Bypass` to **neobejde** — GPO scope (MachinePolicy) má vyšší prioritu než proces.

**Možnosti (vyber jednu):**

| Varianta | Jak | Pozn. |
|---|---|---|
| **A · Podepsat skripty** (doporučeno) | interní code-signing cert → `Set-AuthenticodeSignature` | čisté, GPO-compliant; viz níže |
| **B · Běh z boxu bez AllSigned GPO** | import/export pustit z B-S-W-MIKOS (10.8.2.213) proti SQL přes síť | data.json pak zapsat na share / IIS folder |
| **C · Výjimka z GPO** | OU s RemoteSigned pro tento server | vyžaduje doménového admina, mění bezpečnostní baseline |

### Varianta A — podepsání (jednorázově)
```powershell
# na stroji s pristupem k internimu code-signing certu
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Set-AuthenticodeSignature -FilePath C:\Scripts\BC_PageLog_Import.ps1       -Certificate $cert -TimestampServer http://timestamp.digicert.com
Set-AuthenticodeSignature -FilePath C:\Scripts\Export-DashboardSnapshot.ps1 -Certificate $cert -TimestampServer http://timestamp.digicert.com
```
Cert vydavatele musí být v **Trusted Publishers** na serveru (GPO / certlm.msc).

## 3 · Kde je BC_Telemetry databáze?

Export skript se připojuje parametrem `-SqlServer`:

- **DB na 10.8.2.225** (co-located): `-SqlServer "localhost"` nebo `-SqlServer ".\INSTANCE"`
- **DB na BSWNAV01** (dle původní dokumentace): `-SqlServer "BSWNAV01"` — export běží na 10.8.2.225 a sahá na BSWNAV01 přes síť (servisní účet potřebuje práva tam).

> Vyjasnit: je BC_Telemetry SQL DB na 10.8.2.225, nebo zůstává na BSWNAV01 a na 225 je jen web?
> Podle toho se nastaví `-SqlServer` a kde poběží import.

## 4 · Task Scheduler na 10.8.2.225

```bat
REM GPO-safe: scheduled task spousti podepsany skript primo (ne pres -Bypass)
schtasks /create /tn "BC_Dashboard_Snapshot" /sc DAILY /st 02:30 ^
  /tr "powershell.exe -NonInteractive -File C:\Scripts\Export-DashboardSnapshot.ps1 -OutPath C:\inetpub\bc-telemetry\data.json" ^
  /ru "AXIMA\svc_bc_telemetry" /rp * /rl HIGHEST
```
(Spustit po importu — import 02:00, snapshot 02:30.)

## Verifikace
- [ ] `http://10.8.2.225:8080/` se načte **bez přihlašování** (Anonymous ON)
- [ ] firewall rule `"BC Telemetry Dashboard (8080)"` existuje s očekávaným `remoteip` (`Set-DashboardWhitelist.cmd` bez parametru)
- [ ] po běhu tasku má `data.json` aktuální `generatedUtc`
- [ ] dashboard ukazuje KPI a tabulky se filtrují

> Pozn.: tvrdé „mimo whitelist = zablokováno" se ověří jen pokud je Domain firewall profil Enabled.
> Při formálním režimu (profil off) je whitelist evidenční — port odpoví i mimo seznam.
