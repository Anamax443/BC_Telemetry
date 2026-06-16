# Deploy dashboardu na 10.8.2.225 (B-S-W-SQL-04)

Hostování admin dashboardu **co-located se SQL serverem**. Výhoda: snapshot exportér
běží proti `localhost` SQL — žádný síťový hop, žádný file share.

```
10.8.2.225 (B-S-W-SQL-04)
├── SQL Server                    ← dbo.BCPageDaily, vw_Dash*  (pokud je BC_Telemetry DB zde)
├── Task Scheduler
│     └── Export-DashboardSnapshot.ps1  → C:\Apps\BC_Telemetry_Web\public\data.json
└── Windows služba BC_Telemetry_Web (Node + NSSM, LocalSystem — NEsahá na SQL/BC)
        ├── servíruje index.html + data.json + exports/* (anonymně, bez loginu)
        ├── /firewall/whitelist (GET/PUT) ← čte/zapisuje firewall rule (jako ITDashboard)
        ├── /firewall/domain-profile      ← stav Domain firewall profilu
        ├── /access-check                 ← formální visibility gate
        ├── /refresh (POST)               ← spustí denní úlohu (oneshot)
        ├── /activity /logs /logfiles     ← terminál: aktivita služby + logy importu
        ├── /usermap (GET/PUT)            ← mapování GUID → reálné jméno
        ├── /changelog-companies (GET/PUT) ← výběr sledovaných firem (modul B)
        ├── /changelog-purge (POST)       ← purge change logu (přes ops frontu)
        ├── /ops-status (GET) /tasks (GET) ← stav ops fronty + stav OS úloh
        ├── /import-stop (POST)           ← Stop-ScheduledTask běžícího importu
        ├── /restart (POST)               ← process.exit() → NSSM nahodí (self-service deploy)
        ├── /retention (GET/PUT)          ← ops/retention.json (čtou importní skripty)
        ├── /schedule (GET/PUT)           ← ops/schedule.json (okno+četnost+dny pro wrapper)
        └── ops fronta C:\Apps\BC_Telemetry_Web\ops\ (web zapíše, svc zpracuje)
        http://10.8.2.225:8080/
```

> **Princip oddělení práv:** web služba běží jako **LocalSystem** a **nesahá** na SQL ani BC API —
> jen servíruje soubory a spravuje firewall + ops frontu. Veškerý přístup k datům (import, purge,
> snapshot) dělá **svc-bc-telemetry** přes denní úlohu / ops frontu. Whitelist = firewall rule;
> veškerá konfigurace = JSON soubory (`ops/*.json`).

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
- **Editace ze stránky:** záložka **⚙ Nastavení** → textarea (na řádek: IP, CIDR maska `x.x.x.x/n`, nebo rozsah `x.x.x.x-y.y.y.y`) + Uložit → `PUT /firewall/whitelist`.
  Banner ukazuje stav Domain firewall profilu (ta honest „firewall disabled = jen formální" hláška).
- **Access-check gate:** při načtení servis porovná IP návštěvníka s whitelistem; mimo seznam se
  zobrazí překryv „Přístup omezen" s editorem (admin si přidá svou IP). API nedostupné → neblokuje.
- **CLI fallback** (bez prohlížeče): `scripts\Set-DashboardWhitelist.cmd "10.8.2.225,10.8.2.181,10.8.2.243"`
  (default = stejná admin sada jako ITDashboard; lze i maska `10.8.2.0/24` nebo rozsah `10.8.2.180-10.8.2.200`).

> **Je to formální / visibility gate, ne security boundary** — přesně jak to má ITDashboard
> ve vlastním kódu okomentované. Firewall *allow* rule platí jen když je **Domain profil Enabled**.
> Na live ITDashboard serveru je Domain profil `Enabled=False` → rule je OS-level inertní a omezení
> je čistě formální. To odpovídá zadání „whitelist jen formálně omezuje zobrazení". Tvrdé vynucení:
> zapnout Domain profil (`Set-NetFirewallProfile -Profile Domain -Enabled True`).

## 1b · Endpointy služby `BC_Telemetry_Web`

Služba na `10.8.2.225:8080` poskytuje (Push #58):

| Endpoint | Metoda | Co dělá |
|---|---|---|
| `/access-check` | GET | formální visibility gate (IP vs whitelist) |
| `/firewall/whitelist` | GET/PUT | čte/zapisuje `remoteip` firewall rule |
| `/firewall/domain-profile` | GET | stav Domain firewall profilu |
| `/refresh` | POST | spustí denní úlohu (oneshot, poll na nový snapshot) |
| `/activity` | GET | aktivita služby (terminál) |
| `/logs` | GET | log posledního importu |
| `/logfiles` | GET | seznam log souborů |
| `/usermap` | GET/PUT | mapování pseudonymní GUID → reálné jméno |
| `/changelog-companies` | GET/PUT | výběr sledovaných firem (modul B) |
| `/changelog-purge` | POST | purge change logu (zapíše request do ops fronty) |
| `/ops-status` | GET | stav ops fronty (poslední zpracování svc) |
| `/tasks` | GET | stav OS úloh (Task Scheduler) |
| `/import-stop` | POST | `Stop-ScheduledTask` běžícího importu |
| `/restart` | POST | `process.exit()` → NSSM službu nahodí |
| `/retention` | GET/PUT | čte/zapisuje `ops/retention.json` |
| `/schedule` | GET/PUT | čte/zapisuje `ops/schedule.json` |

Statické: `index.html`, `data.json`, `exports/*`.

## 1c · Ops fronta (web zapíše, svc zpracuje)

Web služba (LocalSystem) **nesahá na SQL/BC**. Operace, které vyžadují přístup k datům, předává
přes soubory v adresáři `C:\Apps\BC_Telemetry_Web\ops\` — web tam **zapíše request**, daemon/svc
ho při dalším běhu **zpracuje**. ACL na adresáři nastaví **služba na bootu** (aby svc směl číst/psát).

| Soubor | Význam |
|---|---|
| `ops-request.json` | fronta požadavků (např. purge change logu z `/changelog-purge`) |
| `ops-status.json`  | výsledek/stav posledního zpracování (čte `/ops-status`) |
| `retention.json`   | retenční politika (viz §6), čtou importní skripty |
| `schedule.json`    | plán importu (viz §5), čte wrapper |
| `oneshot.flag`     | jednorázové spuštění importu (z `/refresh`) |

## 1d · Restart služby z dashboardu (self-service deploy)

`POST /restart` zavolá `process.exit()`; protože služba běží pod **NSSM**, ten ji automaticky
**nahodí znovu**. Tím lze z dashboardu **nasadit změny `server.js`** (nakopírované na server)
bez nutnosti admina/RDP na 10.8.2.225.

Ovládání je v záložce **⚙ Nastavení → „Správa služby a úloh"**:
- **Restart služby** → `POST /restart`
- **Zastavit import** → `POST /import-stop` (`Stop-ScheduledTask`)
- **Stav úloh** → `GET /tasks`
- **Stav ops** → `GET /ops-status`

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

## 3 · Kde je BC_Telemetry databáze? — ✅ ROZHODNUTO: 10.8.2.225 (co-located)

DB **BC_Telemetry je na 10.8.2.225** (localhost), co-located se SQL serverem i dashboardem.
Import i export sahají na `localhost` — žádný síťový hop, GRANT míří na lokální Windows účet.

- Default ve všech skriptech: `-SqlServer "localhost"` (sjednoceno 2026-06-08; pojmenovaná instance: `".\INSTANCE"`).
- SQL deploy: `sql\deploy.cmd` (vytvoří DB + schema + agregáty + audit + práva, idempotentně, GPO-safe přes `sqlcmd.exe`).
- Varianta BSWNAV01 (DB přes síť) je opuštěná; kdyby se obnovila, stačí `deploy.cmd BSWNAV01 "DOMENA\ucet"` a `-SqlServer "BSWNAV01"` v importech (účet pak potřebuje práva na BSWNAV01).

## 4 · Task Scheduler na 10.8.2.225

```bat
REM GPO-safe: scheduled task spousti podepsany skript primo (ne pres -Bypass)
schtasks /create /tn "BC_Dashboard_Snapshot" /sc DAILY /st 02:30 ^
  /tr "powershell.exe -NonInteractive -File C:\Scripts\Export-DashboardSnapshot.ps1 -OutPath C:\Apps\BC_Telemetry_Web\public\data.json" ^
  /ru "AXINETWORK\svc-bc-telemetry" /rp * /rl HIGHEST
```
(Spustit po importu — import 02:00, snapshot 02:30.)

## 5 · Plán importu — řízený wrapperem (ne nativním triggerem)

Plán je v `ops/schedule.json`:

```json
{ "startTime": "02:00", "endTime": "18:00", "intervalMinutes": 60, "days": ["Mon","Tue","Wed","Thu","Fri"] }
```

> **Proč wrapper a ne nativní repetice OS úlohy:** trigger Task Scheduler úlohy **nejde změnit
> z LocalSystem bez hesla svc** (`Set-ScheduledTask` skončí `HRESULT 0x8007052e` — logon failure).
> Web služba heslo nemá, proto **okno + četnost + dny řídí wrapper**, ne nativní trigger.

**Model:** OS úloha spustí wrapper `Invoke-BCTelemetryDaily.ps1` **jen 1× ve `startTime`** (jako svc).
Wrapper si přečte `schedule.json` a sám **loopuje á `intervalMinutes`** až do `endTime`; mimo `days`
hned skončí. Změna plánu z dashboardu (`PUT /schedule`) tedy nemění OS úlohu — jen JSON, který
wrapper čte při příštím běhu.

Volitelně lze repetici dát **nativně** Windows scheduleru jednorázově (vyžaduje admina + heslo svc):
```bat
schtasks /Change /tn "BC_Telemetry_Daily" /RI 60 /DU 16:00 /RU "AXINETWORK\svc-bc-telemetry" /RP <heslo>
```

## 6 · Retence + whitelist (konfigurace = JSON / firewall rule)

**Retence** je v `ops/retention.json`; čtou ji importní skripty při údržbě:
```json
{ "pageLogMonths": 6, "changeLogMonths": 24, "dailyLogDays": 30 }
```
- `pageLogMonths` — raw `dbo.BCPageLog` (modul A)
- `changeLogMonths` — `dbo.BCChangeLog` (modul B)
- `dailyLogDays` — denní log soubory (čistí wrapper; navíc NSSM rotace 5 MB)

Editace z dashboardu přes `PUT /retention`; ad-hoc purge change logu přes `POST /changelog-purge`
(zapíše request do `ops/ops-request.json`, svc provede při dalším běhu).

**Whitelist** zůstává **jedna Windows Firewall rule** (`remoteip`) editovatelná přes
`/firewall/whitelist` — viz §1. Konfigurace = firewall rule + JSON soubory; žádná DB konfigurace.

## Verifikace
- [ ] služba `BC_Telemetry_Web` běží (`sc query BC_Telemetry_Web` → RUNNING)
- [ ] `http://10.8.2.225:8080/` se načte **bez přihlašování**
- [ ] záložka **⚙ Nastavení** ukáže whitelist + stav firewall profilu; Uložit zapíše do rule
- [ ] `GET /firewall/whitelist` vrací očekávaný `remoteip`
- [ ] po běhu tasku má `data.json` aktuální `generatedUtc`
- [ ] dashboard ukazuje KPI a tabulky se filtrují

> Pozn.: tvrdé „mimo whitelist = zablokováno" se ověří jen pokud je Domain firewall profil Enabled.
> Při formálním režimu (profil off) je whitelist evidenční — port odpoví i mimo seznam.
