# Deploy dashboardu na 10.8.2.225 (B-S-W-SQL-04)

Hostování admin dashboardu **co-located se SQL serverem**. Výhoda: snapshot exportér
běží proti `localhost` SQL — žádný síťový hop, žádný file share.

```
10.8.2.225 (B-S-W-SQL-04)
├── SQL Server                    ← dbo.BCPageDaily, vw_Dash*  (pokud je BC_Telemetry DB zde)
├── Task Scheduler
│     └── Export-DashboardSnapshot.ps1  → C:\Apps\BC_Telemetry_Web\public\data.json
└── Windows služba BC_Telemetry_Web (Node + NSSM, LocalSystem)
        ├── servíruje index.html + data.json (anonymně, bez loginu)
        ├── /firewall/whitelist (GET/PUT) ← čte/zapisuje firewall rule (jako ITDashboard)
        ├── /firewall/domain-profile      ← stav Domain firewall profilu
        └── /access-check                 ← formální visibility gate
        http://10.8.2.225:8080/
```

## 1 · Web služba (Node + NSSM) — jako ITDashboard

Dashboard hostuje malá **Node služba** (ne IIS), aby šel whitelist **editovat přímo ze stránky**
(záložka Nastavení) — stejný model jako ITDashboard. Servis spouští `powershell -Command` inline
pro čtení/zápis firewall rule; inline `-Command` **NEpodléhá** GPO AllSigned (na rozdíl od `.ps1`).

Předpoklad: Node.js LTS + NSSM v `C:\Tools\nssm\nssm.exe` (viz ITDashboard `SETUP-SERVER.md`).
Instalace jako Administrator na 10.8.2.225:

```bat
scripts\install-service.cmd
```
Zkopíruje `server.js` + `index.html` do `C:\Apps\BC_Telemetry_Web\`, vytvoří firewall rule (pokud
chybí) a zaregistruje službu `BC_Telemetry_Web` (LocalSystem, auto-start). Servis běží jako
LocalSystem — má práva měnit firewall a nepotřebuje heslo (SQL nesahá, jen servíruje soubory).

**Přístupový model — bez přihlašování, formální IP whitelist (jako ITDashboard):**
- **Žádný login, žádná auth** — anonymní přístup, uživatel jen otevře URL.
- **Whitelist = jedna Windows Firewall rule** `"BC Telemetry Dashboard (8080)"`, jejíž `remoteip`
  seznam definuje povolené IP / rozsahy. Source of truth je ta rule — servis ji čte/zapisuje
  přes `Get/Set-NetFirewallRule -RemoteAddress` (1:1 jako ITDashboard `getAllowedIPs`/`setAllowedIPs`).
- **Editace ze stránky:** záložka **⚙ Nastavení** → textarea (IP/CIDR na řádek) + Uložit → `PUT /firewall/whitelist`.
  Banner ukazuje stav Domain firewall profilu (ta honest „firewall disabled = jen formální" hláška).
- **Access-check gate:** při načtení servis porovná IP návštěvníka s whitelistem; mimo seznam se
  zobrazí překryv „Přístup omezen" s editorem (admin si přidá svou IP). API nedostupné → neblokuje.
- **CLI fallback** (bez prohlížeče): `scripts\Set-DashboardWhitelist.cmd "10.8.2.0/24,10.9.0.0/16"`.

> **Je to formální / visibility gate, ne security boundary** — přesně jak to má ITDashboard
> ve vlastním kódu okomentované. Firewall *allow* rule platí jen když je **Domain profil Enabled**.
> Na live ITDashboard serveru je Domain profil `Enabled=False` → rule je OS-level inertní a omezení
> je čistě formální. To odpovídá zadání „whitelist jen formálně omezuje zobrazení". Tvrdé vynucení:
> zapnout Domain profil (`Set-NetFirewallProfile -Profile Domain -Enabled True`).

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
  /tr "powershell.exe -NonInteractive -File C:\Scripts\Export-DashboardSnapshot.ps1 -OutPath C:\Apps\BC_Telemetry_Web\public\data.json" ^
  /ru "AXIMA\svc_bc_telemetry" /rp * /rl HIGHEST
```
(Spustit po importu — import 02:00, snapshot 02:30.)

## Verifikace
- [ ] služba `BC_Telemetry_Web` běží (`sc query BC_Telemetry_Web` → RUNNING)
- [ ] `http://10.8.2.225:8080/` se načte **bez přihlašování**
- [ ] záložka **⚙ Nastavení** ukáže whitelist + stav firewall profilu; Uložit zapíše do rule
- [ ] `GET /firewall/whitelist` vrací očekávaný `remoteip`
- [ ] po běhu tasku má `data.json` aktuální `generatedUtc`
- [ ] dashboard ukazuje KPI a tabulky se filtrují

> Pozn.: tvrdé „mimo whitelist = zablokováno" se ověří jen pokud je Domain firewall profil Enabled.
> Při formálním režimu (profil off) je whitelist evidenční — port odpoví i mimo seznam.
