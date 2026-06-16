# BC_Telemetry — kompletní návod k vybudování (INTERNÍ · AXIMA)

> **Klasifikace: INTERNÍ.** Obsahuje reálné identifikátory prostředí AXIMA (tenant, subscription,
> IP, servisní účty). **Nepublikovat.** Veřejná, sanitizovaná verze stejného postupu je
> [navod-public.md](navod-public.md) — to je ta, co jde na web.

## Preambule — záměr

Cílem je postavit nad **Microsoft Dynamics 365 Business Central Cloud** systém, který odpovídá
na tři otázky, na něž BC SaaS sám nedá přímou odpověď:

- **Co uživatelé reálně používají?** (modul A — využití stránek → podklad pro *permission set mining*,
  tj. seškrtání oprávnění na to, co je skutečně potřeba)
- **Kdo co vytvořil / změnil / smazal?** (modul B — audit změn s reálným jménem uživatele)
- **Komu po zúžení práv chybí oprávnění?** (modul C — permission errors RT0031)

Architektura záměrně stojí na **free tieru** (Application Insights 5 GB/měs zdarma) a on-prem SQL +
lehkém dashboardu, takže provoz je v podstatě zdarma a data zůstávají v doméně.

```
BC Cloud ──telemetrie──▶ Azure Application Insights / Log Analytics
                              │   (Service Principal, neinteraktivně)
        ┌─────────────────────┼─────────────────────┐
   modul A (AppPageViews)  modul C (AppTraces)   modul B (BC Change Log → OData)
        └─────────────────────┼─────────────────────┘
                              ▼
                 SQL (raw → inkrementální rollup → agregáty)
                              ▼
                 data.json ──▶ Node služba (dashboard + IP whitelist)
```

## Klíčové hodnoty (INTERNÍ — pro public verzi → placeholdery)

| Placeholder v textu | Reálná hodnota (AXIMA) |
|---|---|
| `<company>` | AXIMA spol. s r.o. |
| `<DOMAIN>` (NetBIOS) | `AXINETWORK` |
| `<domain-fqdn>` | `axinetwork.loc` |
| `<tenant-id>` | `2ecd5815-0eb9-4e9a-93be-ac58545cdca6` |
| `<subscription-id>` | `4313b649-868c-4b13-a5d2-8a0519f99d75` |
| `<resource-group>` / `<region>` | `rg-bc-telemetry` / West Europe |
| `<appinsights-name>` | `appinsights-bc-production` (workspace-based) |
| `<workspace-id>` | `484e3038-d41f-4c92-991c-cb71ecb54590` |
| `<sp-name>` / `<client-id>` | `BC_Telemetry_SP` / `4eda9e64-ead7-4aac-9631-ef4703c10135` |
| `<sp-secret-expiry>` | 2028-06-07 (⏰ sledovat) |
| `<bc-environment>` | `Production` (12 firem) |
| `<changelog-webservice>` | `ChangelogEntry` (Page 405) |
| `<sql-server>` | `10.8.2.225` (B-S-W-SQL-04), DEFAULT instance, SQL Server 2022 |
| `<db-name>` | `BC_Telemetry` |
| `<svc-account>` | `AXINETWORK\svc-bc-telemetry` (vzor: `svc-itdashboard`) |
| `<dashboard-port>` | `8080` |
| `<admin-ips>` (whitelist) | `10.8.2.225, 10.8.2.181, 10.8.2.243` |

> **Secret se do dokumentace NIKDY nepíše** — jen se odkazuje „Value z Azure". Aktuální Value je
> uložená v Credential Manageru servisního účtu (viz Fáze 8).

---

# Fáze 1 — Azure: subscription + Application Insights (moduly A/C)

1. Azure Portal → **Předplatná** → Pay-as-you-go (App Insights jede ve free tieru = $0; karta jen kvůli identitě).
2. **Resource Group** `<resource-group>`, region `<region>`.
3. **Application Insights** `<appinsights-name>`, **Resource Mode: Workspace-based** (vytvoří se Log Analytics workspace).
4. Workspace → *Usage and estimated costs* → **Data Retention 31 dní** + **Daily cap 0,5 GB/den** (pojistka nákladů).
5. Workspace → Overview → zkopíruj **Workspace ID** → `<workspace-id>`.
6. App Insights → Overview → zkopíruj **Connection String** (pro Fázi 2).

# Fáze 2 — BC: zapnout telemetrii

1. BC **Admin Center** (`https://businesscentral.dynamics.com/<tenant-id>/admin`) → Environments →
   `<bc-environment>` → Telemetry → **Define** → vlož Connection String → Save.
2. V aktuální verzi BC **bez restartu** prostředí. Data tečou do ~5 min při reálné aktivitě.

# Fáze 3 — Service Principal (App registration)

1. Entra → **App registrations → New registration** → `<sp-name>`, Single tenant → Register.
2. Zkopíruj **Application (client) ID** → `<client-id>`. *(Pozor: NE „Object ID" — to je něco jiného.)*
3. **Certificates & secrets → New client secret** → **zkopíruj `Value`** (ukáže se jen jednou!).
   ⚠ **Past:** `Value` (cca 40 znaků, např. `mzm8Q~…`) je secret. **`Secret ID` (36-znakový GUID, `4b1f…`)
   NENÍ secret** — když ho omylem použiješ, token request vrací **401**. Sleduj expiraci `<sp-secret-expiry>`.

# Fáze 4 — SP → Application Insights (moduly A/C)

1. Log Analytics workspace → **Access control (IAM) → Add role assignment → Log Analytics Reader** →
   member `<sp-name>` → Review + assign.

# Fáze 5 — SP → BC API (modul B, S2S) — tři pasti, projdi všechny

### 5a. Redirect URI (jinak „Udělit souhlas" v BC spadne na AADSTS500113)
App registration → **Authentication → Add a platform → Web** → Redirect URI:
`https://businesscentral.dynamics.com/OAuthLanding.htm` (Implicit grant NEzaškrtávat).

### 5b. API permission + admin consent (jinak token má prázdné `roles` → 401 i s BC sadami)
App registration → **API permissions → Add → APIs my organization uses → Dynamics 365 Business Central
→ Application permissions → `API.ReadWrite.All`** → Add → **Grant admin consent** (musí být zelené *Granted*).

### 5c. App user v BC + permission sety
BC web klient → **Microsoft Entra Applications** (Page 9861) → New → Client ID = `<client-id>` →
**Permission Sets** přidej `D365 BUS PREMIUM` (nebo custom read; **SUPER/SUPER(DATA) NELZE**) →
Společnost prázdné (= všechny firmy) → Stav **Povolený** → **Udělit souhlas**.

# Fáze 6 — BC: Change Log + web service (modul B)

1. **Change Log Setup → Change Log Activated = ON**.
2. **Tables** → pro citlivé tabulky zapni Log Insertion/Modification/Deletion (např. Access Control 2000000053,
   User 2000000120, doklady, položky). *Neloguje zpětně.*
3. **Web Services → New** → Type Page, Object ID **405**, Service Name `<changelog-webservice>`, **Published**.
   ⚠ Microsoft postupně ruší publikování UI stránek jako web service → durable varianta = vlastní AL API page (TODO).

# Fáze 7 — SQL: databáze + schéma + práva

DB běží **co-located** na `<sql-server>` (žádný síťový hop; servisní účet má práva lokálně).

**Varianta A — repo na serveru** (GPO-safe, `sqlcmd.exe` nepodléhá AllSigned):
```bat
cd <repo>\sql
deploy.cmd localhost "<svc-account>"
```
Pustí idempotentně `00_database → 01_schema → 02_aggregates → 04_audit → 05_grants`.

**Varianta B — bez repa / běžný účet nemá DDL práva** (náš případ): jeden konsolidovaný skript
[`sql/deploy-full.sql`](../sql/deploy-full.sql) vlož do **SSMS jako sysadmin** a spusť (F5).
*(U nás `trnkam` měl jen `CONNECT SQL`; deploy pustil `admintrnka` jako sysadmin.)*

**Ověření** (jako sysadmin):
```sql
USE <db-name>;
SELECT 'tables',COUNT(*) FROM sys.tables UNION ALL SELECT 'views',COUNT(*) FROM sys.views
UNION ALL SELECT 'procs',COUNT(*) FROM sys.procedures;   -- čekej 6 / 6 / 4
```
Objekty: `BCPageLog, BCPageDaily, BCAuthFailRaw, BCAuthFailDaily, BCChangeLog, ETLWatermark` (+ rollup/purge procy + `vw_Dash*`).

# Fáze 8 — Servisní účet + práva + secret (3 podpasti)

### 8a. Doménový servisní účet (regular, NE gMSA)
Na DC (Domain Admin) — naklonuj OU + flagy ze vzoru (`svc-itdashboard`):
[`scripts/New-ServiceAccount.ps1`](../scripts/New-ServiceAccount.ps1) → vznikne `<svc-account>`
(PasswordNeverExpires + CannotChangePassword + Enabled).
> ⚠ Když vkládáš skript do **konzole** (ne spouštíš jako soubor), použij verzi bez `param()` —
> jinak parser hodí *„Unexpected attribute 'CmdletBinding'"*.

### 8b. SQL práva
`05_grants.sql` (součást deploye) vytvoří **login + user** pro `<svc-account>` + `db_datareader` +
`db_datawriter` + `EXECUTE` na 4 ETL procy. *(Importy se připojují přes Integrated Security → práva
potřebuje WINDOWS účet, NE Service Principal.)*

### 8c. User Rights na `<sql-server>`
`secpol.msc → Local Policies → User Rights Assignment` → přidej `<svc-account>` do
**Log on as a service** + **Log on as a batch job**. *(Pozor neklikni omylem do „Lock pages in memory".)*

### 8d. Secret do Credential Manageru — **per-user past**
Credential Manager je **per-profil**. Secret musí ležet ve vaultu `<svc-account>`, ne ve tvém.
Dva cíle, **stejná Value**: `BC_Telemetry_SP` (Azure, moduly A/C) a `BC_Telemetry_BCAPI` (BC API, modul B).

PsExec na serveru nebyl → použili jsme **jednorázový scheduled task běžící jako `<svc-account>`** (batch logon),
který creds zapíše do svého profilu:
```powershell
Install-Module CredentialManager -Scope AllUsers -Force   # jednorázově, machine-wide
$cid='<client-id>'; $secret=Read-Host 'SP secret (Value)'; $svcPw=Read-Host 'heslo svc uctu'
$cmd="Import-Module CredentialManager;"+
 "New-StoredCredential -Target BC_Telemetry_SP    -UserName '$cid' -Password '$secret' -Persist LocalMachine;"+
 "New-StoredCredential -Target BC_Telemetry_BCAPI -UserName '$cid' -Password '$secret' -Persist LocalMachine"
$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -Command `"$cmd`""
Register-ScheduledTask -TaskName BCT_StoreCred -Action $a -User '<svc-account>' -Password $svcPw -RunLevel Highest -Force
Start-ScheduledTask BCT_StoreCred; Start-Sleep 6; Unregister-ScheduledTask BCT_StoreCred -Confirm:$false
```

# Fáze 9 — Importy + scheduler

Tři skripty (`BC_PageLog_Import.ps1` A, `BC_ChangeLog_Import.ps1` B, `BC_AuthFail_Import.ps1` C) —
inkrementální (watermark), idempotentní (dedup/MERGE), atomické (transakce), retence + rollup.
Moduly A/C vyžadují `Az.Accounts` + `Az.OperationalInsights` (Install-Module -Scope AllUsers).

Scheduler: [`scripts/Register-ScheduledTask.ps1`](../scripts/Register-ScheduledTask.ps1) (denně 02:00, LogonType Password).

✅ **Execution policy na `<sql-server>` ověřena 2026-06-10: `LocalMachine = RemoteSigned`, MachinePolicy = Undefined
— tj. NE AllSigned.** Lokální `.ps1` (včetně importů) tu běží **bez podpisu**; po přenosu přes internet
spusť `Unblock-File` (RemoteSigned blokuje skripty se zónou „downloaded"). Žádné podpisování tedy není potřeba.
> Obecná poznámka (jiné AXINETWORK servery mívají AllSigned): tam by importní `.ps1` musely být podepsané
> (`Set-AuthenticodeSignature` + cert do Trusted Publishers), nebo běžet z boxu bez AllSigned, nebo GPO výjimka;
> `-ExecutionPolicy Bypass` AllSigned **neobejde** (MachinePolicy má přednost). SQL deploy se tomu vyhýbá vždy
> (`sqlcmd.exe` je nativní binárka, ne skript).

# Fáze 10 — Dashboard (Node služba + IP whitelist)

[`scripts/install-service.cmd`](../scripts/install-service.cmd) (jako admin) — Node + NSSM, služba
`BC_Telemetry_Web` (LocalSystem, auto-start), `http://<sql-server>:<dashboard-port>/`.
- **Bez loginu**, přístup omezuje **IP whitelist = Windows Firewall rule** (`remoteip`). Default `<admin-ips>`.
- Editace whitelistu přímo ze stránky (záložka ⚙ Nastavení) nebo `Set-DashboardWhitelist.cmd`.
- Whitelist umí **single IP, CIDR masku (`x.x.x.x/n`) i rozsah (`x.x.x.x-y.y.y.y`)**.
- Snapshot: `Export-DashboardSnapshot.ps1` → `data.json` (čte jen agregáty → malý i nad miliony raw).

**Funkce dashboardu (záložky + endpointy):**
- **👤 Uživatelé** — mapování pseudonymní GUID → reálné jméno (`usermap.json` přes `/usermap`), s nápovědou
  (firmy/top stránka/otevření/naposledy). **Klíč k hlavnímu cíli** (komu nastavit práva). Modul A/C má jen
  pseudonym (MS nerozkrývá ani přes Graph); Audit/B má reálné jméno nativně z Change Logu.
- **Sync-status** (pruh pod KPI) — cloud vs zesynchronizováno per modul (`Update-SyncStatus.ps1` → `dbo.BCSyncStatus` → snapshot).
- **🖥 Terminál** — aktivita služby (`/activity`) + log posledního importu (`/logs`), auto-refresh.
- **↻ Ruční obnova** (Nastavení) — `/refresh` spustí denní task; **Údržba logů** — retence 30d (wrapper) + NSSM rotace 5 MB (`/logfiles`).
- Endpointy: `/access-check`, `/firewall/whitelist`, `/firewall/domain-profile`, `/refresh`, `/activity`, `/logs`, `/logfiles`, `/usermap`.
- ⚠ Změna `server.js` → **restart služby** (`sc stop`→STOPPED→`sc start`); `index.html`/`usermap.json` ne (no-store / soubor).

> **Honest poznámka:** whitelist je *formální / visibility gate*, ne tvrdá hranice — firewall *allow* rule
> platí jen když je Domain profil Enabled. Tvrdé vynucení = zapnout Domain profil.

# Fáze 11 — Provozní featury dashboardu (self-service z UI, přidáno 2026-06-16)

> **Stav: LIVE.** Cílem této vrstvy je provozovat celý systém z UI dashboardu **bez RDP/zásahu na serveru**.

**Bezpečnostní princip (proč to běží přes frontu, ne přímo):** web služba `BC_Telemetry_Web`
(LocalSystem / servisní účet s nízkými právy) **nesahá přímo na SQL ani BC API**. Mazání, import, plán
a stav DB obstarává **servisní účet `AXINETWORK\svc-bc-telemetry`** přes **denní úlohu / „ops" frontu** —
požadavky z UI se zapisují jako soubory do `ops/` a wrapper/denní task je pod servisním účtem vykoná.
Whitelist přístupu zůstává **Windows Firewall rule** (viz Fáze 10); ostatní konfigurace = **JSON soubory** v repu.

**Správa služby a úloh (z UI):**
- Stav naplánovaných úloh (kdy poběží, kdy naposledy běžely).
- Zastavení právě běžícího importu.
- **Restart web služby** — proces skončí, NSSM ho automaticky znovu nahodí → **self-service nasazení změn
  `server.js`** bez `sc stop`/`sc start` z konzole.

**Plán importu (okno + četnost + dny v týdnu):**
OS úloha startuje **1× v čase „Od"**; wrapper pak opakuje import **každých N minut v okně Od–Do** ve vybrané
dny v týdnu. Pokud čas „Od" už toho dne minul, import se spustí **hned**.
> Změnu OS triggeru z účtu služby nelze udělat bez hesla servisního účtu `svc-bc-telemetry`, proto repetici
> v okně řídí wrapper (ne sám Task Scheduler).

**Retenční politika (z UI):** kolik **měsíců/dní** se drží raw page log, change log a denní logy. Hodnoty
čtou přímo importní skripty (`BC_PageLog_Import.ps1`, `BC_ChangeLog_Import.ps1`, `BC_AuthFail_Import.ps1`).

**Mazání audit záznamů** vybraných firem (s potvrzením) — neproběhne z web procesu, ale **pod servisním
účtem přes denní úlohu** (ops fronta).

**Výběr sledovaných firem pro Audit změn** ve vlastní záložce, s počty záznamů per firma.

**Záložka Databáze:**
- Stav SQL serveru `10.8.2.225` (B-S-W-SQL-04): verze (SQL Server 2022), recovery model, stav, collation.
- Velikost datového a log souboru DB `BC_Telemetry`.
- Seznam tabulek s počty řádků a velikostí.

**Tabulky (vylepšené zobrazení):**
- **Per-sloupcové filtry:** kategorie jako rozbalovací seznam, text jako „obsahuje", datum jako rozmezí od–do.
- Datum ve formátu **rok.měsíc.den**.
- **Export do CSV** — UTF-8 **BOM**, oddělovač `;` (otevře se rovnou v Excelu). Slouží jako **podklad pro tvorbu
  permission setů**.
- Trend dle společnosti; v auditu sloupce **Číslo tabulky / Číslo pole**.

**Hlavička:** běžící čas (**heartbeat** — když stojí, stránka zamrzla) + **stáří dat**.

**Výkon a spolehlivost importu (2026-06-16):**
- Vkládání přes **hromadnou kopii (bulk copy)** — řádově rychlejší u velkých objemů.
- **Průběžná obnova autentizačního tokenu** u dlouhých běhů (token nevyprší uprostřed importu).
- Change log se nově stahuje **„od nejnovějšího"** + postupné doplňování historie.
- **Dedup oprava** u page-view importu.

# Verifikace (end-to-end smoke test)

Pod identitou `<svc-account>` (jednorázový task) ověř všechny pilíře — výsledky u nás 2026-06-10:
- **CRED OK** (čtení obou targetů), **secret_len ~40** (Value, ne 36 = Secret ID)
- **SQL OK** (připojení jako svc)
- **modul A:** `AppPageViews count = 421`
- **modul B:** token `roles = API.ReadWrite.All` → `firmy = 12`

# Workflow permission setů (vlastní byznys přínos)

1. Uživatel jede pod plným přístupem → sledovací období ~3 měsíce (data se kumulují v `BCPageDaily`).
2. Dashboard → **Kandidáti na vyřazení** (≤2 otevření) + **Aktivita** → návrh rolí (Fakturace/Sklad/Reporting).
3. Nasadit permission sety, odebrat plný přístup.
4. Sledovat **modul C (RT0031)** první 2 týdny → doplnit chybějící práva.

# Ověřená realita / lessons (proč to vypadá jinak než „dokumentace na první pohled")

- Data jsou v **`AppPageViews`** (Log Analytics), NE classic `pageViews`; BC dimenze v `Properties.*`.
- Identita telemetrie = **`UserId` = pseudonymní GUID** (ne AAD object id). Jméno jen korelací s Entra sign-in logy.
- Interaktivní klienti = **`Desktop` / `WebClient`** (hodnota „Web" neexistuje).
- Audit (modul B) má naopak **reálné jméno** (Change Log `User_ID`).
- `Entry_No` je **per-firma** sekvence → watermark + dedup per firma.
- **Credential Manager je per-user**, **secret = Value ne Secret ID**, **AllSigned neobejdeš Bypassem**,
  **sqlcmd.exe AllSigned nepodléhá** — čtyři věci, na kterých se to nejčastěji zadrhne.

---
*Rolling stav: [HANDOFF.md](HANDOFF.md) · [project-status.html](project-status.html). Tato příručka shrnuje
ověřený postup k 2026-06-10 (systém LIVE: SQL nasazen, účet+práva+creds hotové, oba moduly funkčně ověřené).*
