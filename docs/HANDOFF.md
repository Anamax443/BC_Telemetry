# BC_Telemetry — HANDOFF (rolling)

Aktuální stav projektu pro pokračování v další session. Updatuje se průběžně.
Poslední update: **2026-06-10** · repo `Anamax443/BC_Telemetry`.

> **Kompletní build návod:** [navod-interni-axima.md](navod-interni-axima.md) (INTERNÍ, plné hodnoty) ·
> [navod-public.md](navod-public.md) (sanitizovaný, k publikaci) — sdílené tělo, liší se jen tabulka hodnot.
> Doplňující docs: [modules.md](modules.md) (3 moduly) · [dokumentace.md](dokumentace.md) (technicky) ·
> [BUILD.md](../BUILD.md) (legacy postup) · [deploy-10.8.2.225.md](deploy-10.8.2.225.md) (dashboard hosting) ·
> [project-status.html](project-status.html) (milestones) · [oponentury/](oponentury/).

---

## Co projekt dělá — 3 moduly
- **A · Využití stránek** (LIVE) — App Insights `AppPageViews` → Permission Set mining. Uživatel = pseudonymní GUID.
- **B · Audit změn** — kdo vytvořil/změnil/**smazal** (BC Change Log → OData). Uživatel = **reálné jméno** (MTRNKA…).
- **C · Permission errors RT0031** — z `AppTraces`. Vzniká až po odebrání plného přístupu.

## LIVE stav (Azure + BC)
| Co | Hodnota |
|---|---|
| Azure subscription | `4313b649-868c-4b13-a5d2-8a0519f99d75` (Pay-as-you-go, role Owner) |
| Tenant | `2ecd5815-0eb9-4e9a-93be-ac58545cdca6` (axima.cz) |
| Resource Group | `rg-bc-telemetry` (West Europe) |
| App Insights | `appinsights-bc-production` (workspace-based); iKey `06cb351f-…`, AppId `03c2f43a-…` |
| Log Analytics workspace | `DefaultWorkspace-4313b649-…-WEU` (RG `DefaultResourceGroup-WEU`, retence 31d/90d-AI free, daily cap 0,5 GB) |
| **Workspace ID (GUID)** | `484e3038-d41f-4c92-991c-cb71ecb54590` (do `-WorkspaceId` v modulech A/C) ✅ |
| SP role (Azure) | **Log Analytics Reader** na workspace přiřazena `BC_Telemetry_SP` ✅ (SP object id `d578b3a2-…`) |
| BC telemetrie | Production → ON (connection string vložen, bez restartu) — **data tečou** |
| Change Log | **zapnutý**, web service `ChangelogEntry` (Page 405) publikovaný; loguje i Access Control |
| Service Principal | `BC_Telemetry_SP`, client ID `4eda9e64-ead7-4aac-9631-ef4703c10135`; secret **expiruje 2028-06-07** |
| **SP → BC API (S2S)** | ✅ funguje: Redirect URI `OAuthLanding.htm` + **API.ReadWrite.All** (Application) + admin consent + BC app user (`8de43095-…`, sady D365 BUS PREMIUM) Enabled. OData čte **všech 12 firem**. Detail [SETUP-STEP-BY-STEP.md](SETUP-STEP-BY-STEP.md). |

## Ověřená realita (POZOR — docs v1.0 i oponentura byly mylné)
- Import sahá na **Log Analytics** → tabulka **`AppPageViews`** (NE classic `pageViews`), BC dims v **`Properties.*`**.
- Uživatel telemetrie = **`UserId`** = **pseudonymní GUID** (NE AAD object id — Entra 404; NE ani BC „User Security ID").
  **VYŘEŠENO 2026-06-10:** tenhle GUID = BC pole **„Telemetry User ID"** (sloupec „ID telemetrie" na Page 9800 Users).
  Mapování na jméno → BC Users OData (publikovaný web service), NE korelace s Entra sign-in logy.
  `scripts/BC_Users_Import.ps1` (stejný SP jako modul B) → **`dbo.BCUser`** (`sql/03_users.sql`) → `dbo.vw_UserMap` → `web/usermap.json`. Běží v denním wrapperu po modulu B.
- Interaktivní klienti = **`Desktop`/`WebClient`** (hodnota „Web" NEexistuje → starý filtr by nematchnul nic).
- Change Log naopak má **reálné jméno** (User_ID = LSOKOL…) → modul B jména řeší nativně.
- DCR filtr **odložen** (free tier $0; filtruje import).
- BC SaaS NEMÁ Windows eventlog → „kdo co smazal" jen přes Change Log.
- **S2S pasti (vyřešené):** (1) Redirect URI `OAuthLanding.htm` nutné pro BC Grant Consent (jinak AADSTS500113); (2) **API.ReadWrite.All + admin consent** nutné, jinak token má `roles` prázdné → **401** i s BC permission sety; (3) SUPER/SUPER(DATA) NELZE přiřadit Entra app userovi.
- **Change Log OData pole** (Page 405): `Entry_No`, `Date_and_Time`, `User_ID`, `Table_No/Caption`, `Field_No/Caption`, `Type_of_Change`, `Old_Value`/`New_Value`, `Primary_Key`. Per-firma `Entry_No` sekvence. Import opraven na tato pole 2026-06-08.

## Hotovo
- Repo, 3 moduly (SQL + skripty + dashboard záložky A/B/C), dokumentace, oponentura+reakce, status HTML (dark mode + Push #).
- Azure onboarding LIVE, BC telemetrie ON, Change Log ON + web service, Service Principal založen.
- Import KQL ověřen na reálných datech a opraven (AppPageViews/UserId/Desktop).

## Další kroky (pořadí)
1. ~~Workspace ID~~ ✅ `484e3038-…` doplněn do skriptů.
2. ~~Azure: SP → Log Analytics Reader na workspace~~ ✅ (moduly A/C mají auth).
3. ~~SP → BC API (S2S): Redirect URI + API.ReadWrite.All + consent + BC app user~~ ✅ (modul B čte OData).
4. ~~Ověřit OData pole + doladit BC_ChangeLog_Import~~ ✅ (pole Entry_No/Date_and_Time/User_ID/… opravena).
5. ~~SQL na 10.8.2.225~~ ✅ **LIVE 2026-06-10** — schéma+agregáty+audit+práva nasazeny do `BC_Telemetry`
   (verifikováno: 6 tabulek / 6 views / 4 procy; login+user `svc-bc-telemetry` s `db_datareader+db_datawriter`).
   DB **co-located** na 10.8.2.225 (DEFAULT instance, SQL 2022). Deploy přes SSMS (`sql/deploy-full.sql`) —
   `trnkam` nemá na SQL DDL práva, pustil to admintrnka (sysadmin). `sql/deploy.cmd` je alternativa, když je repo na serveru.
6. ~~Servisní účet + secret~~ ✅ `AXINETWORK\svc-bc-telemetry` založen na DC (`New-ServiceAccount.ps1`, klon z svc-itdashboard);
   secret uložen do Credential Manageru **v profilu svc účtu** (`BC_Telemetry_SP` + `BC_Telemetry_BCAPI`) přes jednorázový
   scheduled task (PsExec na serveru není). ⚠ **Past:** ukládat **Value `mzm8Q~…`**, NE Secret ID (`4b1f…`, 36 znaků GUID).
7. ~~User Rights~~ ✅ `svc-bc-telemetry` má `Log on as a service` + `Log on as a batch job` (secpol; `Lock pages in memory` omylem → odebráno).
8. ~~**Funkční ověření end-to-end**~~ ✅ **2026-06-10**: pod identitou svc — CRED OK, SQL OK (jako svc), **modul A** Azure/Log Analytics
   `AppPageViews count=421`, **modul B** BC API `roles=API.ReadWrite.All` → `firmy=12`. Az moduly (Az.Accounts/OperationalInsights) doinstalovány AllUsers.
9. ~~**Ruční běh importů — DATA LIVE**~~ ✅ **2026-06-10**: všechny 3 moduly naimportovaly reálná data
   (`BCPageLog=500`, `BCPageDaily=185`, `BCChangeLog=42665`, `BCAuthFailRaw=0`). Skripty deploynuty na server přes
   SMB share `\\10.8.2.225\BC_Telemetry` (trnkam Modify; Claude píše, svc spouští). Importy se pouští jako svc přes scheduled task.
   ⚠ **Opraveno při ostrém běhu:** (a) `.ps1` ukládat **s UTF-8 BOM** (5.1 jinak čte CP1250 → parse error u PageLogu);
   (b) `??` → if/else (PS7-only); (c) rollup procy: popisný sloupec přes `MAX()`, ne v `GROUP BY` (jinak duplicate PK).
10. ~~**Web dashboard LIVE**~~ ✅ **2026-06-10**: služba `BC_Telemetry_Web` (Node+NSSM, NSSM z ITDashboard serveru) běží na
    `http://10.8.2.225:8080/` — KPI + 6 záložek + **dark mode** (🌙/☀, prefers-color-scheme + localStorage) +
    **↻ Obnovit** (POST `/refresh` → spustí denní task, poll na nový snapshot → auto-reload).
    Whitelist `10.8.2.225/181/243`. ⚠ Změna `server.js` vyžaduje **restart služby** (`sc stop` → čekat STOPPED → `sc start`;
    NSSM jinak drží starý PID); `index.html` ne (no-store, stačí Ctrl+F5).
11. ~~**Denní scheduler LIVE**~~ ✅ **2026-06-10**: `Invoke-BCTelemetryDaily.ps1` (3 importy + snapshot, child procesy) + `Register-ScheduledTask.ps1`
    (`BC_Telemetry_Daily`, denně 02:00 jako svc). Ověřen plný běh: 4× `exit=0`, snapshot přegeneroval `data.json`.
    ⚠ **Opraveno při ostrém běhu scheduleru:** (a) child volání explicitně (ne splat `@($s.a)`); (b) `ScriptDir` hardcoded
    (`$PSScriptRoot` byl v task kontextu prázdný); (c) **EXECUTE na `SCHEMA::dbo`** (per-proc grant zanikl při DROP/CREATE rollup proc);
    (d) svc potřebuje **Modify na `…_Web\public`** (snapshot píše `data.json`) — zapracováno do `install-service.cmd`.
12. ~~**Dashboard UX + hlavní cíl (permission mining)**~~ ✅ **2026-06-10**:
    - **👤 Uživatelé** (záložka): mapování **pseudonymní GUID → reálné jméno** (`usermap.json` přes `/usermap`), s nápovědou
      (firmy / top stránka / otevření / naposledy). Jméno se aplikuje v Aktivitě / Kandidátech / RT0031 a dá se podle něj filtrovat
      → **základ pro definici permission setů per uživatel** (modul A/C má jen pseudonym — MS nerozkrývá; Audit/B má reálné jméno nativně).
    - **🖥 Terminál** (záložka): aktivita služby (`/activity`, ring-buffer) + log posledního importu (`/logs`), auto-refresh 10 s.
    - **Údržba logů** (Nastavení): retence denních logů **30 dní** (wrapper) + **NSSM rotace 5 MB** + okno se seznamem (`/logfiles`).
    - **Sync-status** (pruh pod KPI): kolik cloud obsahuje vs zesynchronizováno per modul. Plní `Update-SyncStatus.ps1`
      (cloud: AppPageViews / AppTraces RT0031 / OData `$count`) → `dbo.BCSyncStatus` → snapshot. Krok ve wrapperu před snapshotem.
    - **↻ Ruční obnova** (Nastavení): POST `/refresh` spustí denní task. UI: default řazení newest-first, proklikávací KPI dlaždice, název→domů, favicon.

## 🟢 STATUS: LIVE / kompletní (2026-06-10)
Celý řetězec **BC → Azure App Insights → SQL (3 moduly) → rollup → snapshot → dashboard** běží **plně automaticky**
(denně 02:00 jako `AXINETWORK\svc-bc-telemetry`). Data ověřena, dashboard servíruje, dokumentace (interní + public) hotová.
**Hlavní cíl** (podklad pro permission sety per uživatel místo SUPER) je naplněn: po namapování jmen v záložce Uživatelé
ukazuje Aktivita/Kandidáti **kdo** co reálně používá → z toho se sestaví role; RT0031 pak po zúžení práv hlídá chybějící oprávnění.

### Dashboard endpointy (Node služba)
`/access-check` · `/firewall/whitelist` (GET/PUT) · `/firewall/domain-profile` · `/refresh` (POST) ·
`/activity` · `/logs` · `/logfiles` · `/usermap` (GET/PUT). Statické: `index.html`, `data.json`.

### Zbývá jen volitelné
- Zúžit BC permission set z D365 BUS PREMIUM na custom read (least-privilege); vlastní AL API page místo deprecated UI-page web service.
- ⏰ Monitor expirace SP secretu v dashboardu (current expiry **2028-06-07**).
- Sledovat objem Change Logu (denně tisíce záznamů) vs retence 24 měs. + daily cap App Insights.

## Otevřená rozhodnutí (operator)
- ~~BC_Telemetry DB: 10.8.2.225 (localhost) vs BSWNAV01~~ ✅ **localhost (co-located na 10.8.2.225)** — všechny importy sjednoceny na `localhost`, GRANT míří na lokální Windows účet.
- ~~Whitelist rozsah dashboardu: `/24` vs `/16`~~ ✅ **stejně jako ITDashboard** — konkrétní admin IP (`10.8.2.225` vlastní server, `10.8.2.181` dev PC, `10.8.2.243` IT specialista); whitelist editor umí navíc CIDR masku i pomlčkový rozsah.
- ~~GPO AllSigned~~ ✅ na `10.8.2.225` je `LocalMachine=RemoteSigned` (ne AllSigned, ověřeno 2026-06-10) → importní `.ps1` běží bez podpisu (po přenosu z internetu `Unblock-File`). Žádné podpisování netřeba.
- ~~Servisní účet~~ ✅ `AXINETWORK\svc-bc-telemetry` založen.

## Plánované featury
- ⏰ **Monitor expirace SP secretu/certifikátu** v dashboardu (KPI/alert; current 2028-06-07) — operator request.
- Modul B durable: vlastní AL API page místo deprecated UI-page web service.
- ~~Modul A jména: korelace GUID ↔ Entra sign-in logy~~ ✅ **VYŘEŠENO jinak (2026-06-10):** telemetrický GUID = BC „Telemetry User ID" → BC Users OData → **SQL `dbo.BCUser`** (`BC_Users_Import.ps1`, v denním wrapperu) → `vw_UserMap` → `usermap.json`. **Zbývá nasadit na serveru** — runbook [deploy-users-2026-06-10.md](deploy-users-2026-06-10.md): (1) deploy `sql/03_users.sql` (admintrnka, DDL); (2) `schtasks /run /tn BC_Telemetry_Daily` jako svc; (3) ověřit OData pole (auto-detekce, jinak vypíše dostupná pole).
- ~~Import: stahovat z cloudu od nejnovějších po nejstarší~~ ✅ A/C KQL `order by timestamp desc`. Modul B ponechán `asc` (watermark + `$top=5000` — desc by při >5000 nových vynechal starší → díra).
- ~~Dashboard: celkový počet záznamů cloud vs SQL~~ ✅ sync pruh má teď „Celkem SQL / cloud (%)" jako součet přes moduly z `BCSyncStatus`.
- 📖 **Anonymizovaný public step-by-step návod** (na maxferit web, jako showcase/lead-gen) —
  samostatný deliverable, **bez identifikace firmy**: nahradit AXIMA / company names / tenant+subscription
  GUIDy / SP client ID / iKey / reálná jména (MTRNKA) / interní IP (10.8.2.225, BSWNAV01) za placeholdery
  (`<tenant-id>`, `<company>`, `<server>`…). Interní docs proto píšeme sanitizovatelně (firemní hodnoty
  v oddělených tabulkách „klíčové ID" + parametrech skriptů). Repo se celé nepublikuje.
