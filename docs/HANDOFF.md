# BC_Telemetry — HANDOFF (rolling)

Aktuální stav projektu pro pokračování v další session. Updatuje se průběžně.
Poslední update: **2026-06-16** (Push #64 / `3c7d81f`) · repo `Anamax443/BC_Telemetry`.
Push #64: **rozšířený export** tabulek (Aktivita/Audit/RT0031/Databáze/Uživatelé) — dropdown **CSV / TXT / HTML / PDF** (klientsky, `doExport`/`exportTableDocHtml`/`openPrint`); **📊 Manažerská zpráva** (tlačítko v hlavičce → nové okno, `buildMgmtReportHtml`): KPI souhrn, **grafy** (bar) + **kumulace** trendu, top uživatelé/stránky/firmy, audit dle typu/firmy, RT0031; uvnitř tlačítka 🖨 Tisk/PDF + ⬇ Uložit HTML. Vše z `data.json` (global `DATA`), bez serveru/restartu.
Push #63: **zarovnání hlaviček číselných/datových sloupců vpravo** (`th.num` + atributové selektory data-sort → hlavička sedí nad `td.num`); KPI **„Aktivní uživatelé" i „Otevření" → vedou na Aktivitu uživatelů** (dřív users/trend). Pozn.: aktivních uživatelů 30d = 19, ale modul A má data jen od 8.6. (~8 dní) → krátké okno, poroste.
Záložka **📖 Dokumentace** přímo v dashboardu má **přepínač** *👤 Uživatelská příručka* (default — orientace, záložky, workflow oprávnění na míru, práce s tabulkami, provoz, potíže) / *🛠 Technická dokumentace* (architektura + **registrace u Microsoftu/Entra a v BC**, 3 moduly, klíčové ID maskovaně, endpointy). **🖨 Tisk/PDF** vytiskne **právě zobrazenou** příručku (`@media print`, vždy světle). Jen `index.html` (no-store, bez restartu).
Tabulky: **stránkování** (50/100/200/500/vše, default v Nastavení = localStorage) + **responzivní** layout (mobil/tablet; široký Audit horizontálně scrolluje). Záložka **🗄 Databáze** (stav SQL).
Modul B = **bulk insert** (SqlBulkCopy→#Staging→dedup, `fa08d7e`) místo row-by-row. Plán importu (okno+četnost+**dny**, auto-start v okně) řídí wrapper (viz níže). Uživatelé filtr+export, KPI „Aktivní uživatelé"→záložka Uživatelé.
Filtry tabulek = zalamovací lišta `.filterbar` (popisky + „Vyčistit"); datum `2026.06.07`; filtr data rozmezí `od..do`; běžící čas + stáří dat v hlavičce.

### Záložka 📖 Dokumentace v dashboardu (2026-06-16, Push #60–62)
- **Push #62:** záložka má **přepínač view** (`.doc-switch` → `.doc-view#docUser` / `#docTech`, JS `docViews()`):
  *👤 Uživatelská příručka* (default) = netechnický návod k používání dashboardu (orientace v hlavičce/KPI,
  popis všech záložek, **krok-za-krokem workflow tvorby permission setů**, práce s tabulkami/filtry/exportem,
  provozní úkony v ⚙ Nastavení, tipy & řešení potíží vč. firewall timeoutu) · *🛠 Technická dokumentace* = původní
  build/registrace obsah. Tisk/PDF tiskne **jen viditelný view** (skrytý má `[hidden]` → `display:none`).
- **Push #61:** tlačítko **🖨 Tisk/PDF** (`window.print()`) + `@media print` — vytiskne jen `#panel-docs`, vždy
  světle (override `--var` i pro dark), skryje header/taby/KPI, `break-inside` u karet, skrytý tiskový titulek.
- **Push #60 (technický obsah):** kompletní technická dokumentace přímo na homepage:
  přehled (3 moduly), architektura (tok dat + princip 2 identit), **§3 Registrace u Microsoftu** (Azure/App Insights +
  Entra App registration `BC_Telemetry_SP`: secret/Value vs Secret ID, Redirect URI OAuthLanding.htm, `API.ReadWrite.All`
  + admin consent, Log Analytics Reader), **§4 Registrace v BC** (telemetry connection string, Change Log + web service
  Page 405 `ChangelogEntry`, app user Page 9861 + `D365 BUS PREMIUM`, SUPER nelze), 3 moduly detailně, data/servisní účet,
  tabulka klíčových ID, bezpečnost/endpointy + caveat firewall Domain profil.
- **Citlivé ID maskovaná** (posl. znaky, např. client ID `…0135`, tenant `…dca6`); plné hodnoty zůstávají jen v
  `docs/navod-interni-axima.md`, **secret nikde**. Čistě klientská statická sekce (žádný endpoint) → **bez restartu** služby.
- Styl: scoped CSS `.doc*` (karty, flow diagram, callouty, TOC kotvy) — respektuje dark/light přes `--var`.

### Plán importu (okno/četnost/dny) — řídí wrapper, ne OS scheduler (2026-06-16, Push #54–56)
- **Proč:** trigger OS úlohy nejde z LocalSystem měnit bez **hesla svc** (`Set-ScheduledTask`/`schtasks /Change` → 0x8007052e / prompt na heslo → request visel). Proto OS úloha zůstává **1× denně v 02:00** a repetici/okno/dny řeší **wrapper**.
- `PUT /schedule` jen zapíše `ops/schedule.json` `{startTime,endTime,intervalMinutes,days:[0=Ne..6=So]}` (instant). `Invoke-BCTelemetryDaily.ps1`: brána dle `days` (neplánovaný den → skip), pak `do{import}while` opakuje á `intervalMinutes` do `endTime`.
- **Manuál /refresh** = `ops/oneshot.flag` → wrapper proběhne **1×** (neloopuje, ignoruje dny).
- **Auto-start:** uložení plánu, když `startTime` už minul a jsme v okně + dnešní den je v plánu → spustí import hned (windowed). `runPs` má timeout 90 s.
- **Perf v loopu (`e773d88`):** import+snapshot každý cyklus, ale `Update-SyncStatus` (drahý cloud `$count` ~3 min) jen 1×/60 min → cyklus ~4 min → ~1 min, lze jet á 2–5 min bez zátěže.
- Chceš-li, aby repetici řídil **nativně Windows scheduler** (vidět v „příští běh"): jednorázově `schtasks /Change … /RI … /RU svc /RP <heslo>` na serveru (admin) — viz reakce v chatu.

### Správa služby + retence z dashboardu (2026-06-16, Push #51, „dávka A")
- **Nastavení → Správa služby a úloh:** `GET /tasks` (stav BC_Telemetry* úloh), `POST /import-stop` (Stop-ScheduledTask — zastaví i zaseknutý import), `POST /restart` (web `process.exit` → NSSM nahodí službu = self-service deploy server.js).
- **Nastavení → Retenční politika:** `GET/PUT /retention` → `ops/retention.json` `{pageLogMonths:6, changeLogMonths:24, dailyLogDays:30}`. Importní skripty (modul A/B + wrapper) si ji čtou a přebijí defaulty.
- ⚠ **Aktivace:** `/restart`+`/import-stop`+`/retention`+`/tasks` jsou nové v `server.js` → potřeba **jeden ruční restart služby** (Stop/Start-Service `BC_Telemetry_Web` jako admin), pak je vše self-service.

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
- **Modul A dedup past (opraveno 2026-06-16, `32b76e6`):** AppPageViews vrací víc událostí se **stejným** (Timestamp ms, UserId, PageId). Původní import dedupoval jen proti cílové tabulce (`WHERE NOT EXISTS`), takže duplicity **uvnitř jedné dávky** prošly a srazily se na `UX_BCPageLog_Dedup` → **rollback celé transakce** → watermark zamrzl (modul A bez nových dat 2026-06-11→16, snapshot/ostatní moduly přitom OK = vypadalo to živě). Fix: `ROW_NUMBER() OVER (PARTITION BY Timestamp,UserId,ISNULL(PageId,''))=1` ve staging před insertem. ⚠ Při podobném „zamrzlém modulu" koukni do `bct-daily-*.log` na `Import ROLLBACK`.
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

## 🟢 STATUS: LIVE / kompletní (2026-06-10, rozšířeno 2026-06-16 — Push #58)
Celý řetězec **BC → Azure App Insights → SQL (3 moduly) → rollup → snapshot → dashboard** běží **plně automaticky**
(wrapper `Invoke-BCTelemetryDaily.ps1` jako `AXINETWORK\svc-bc-telemetry` dle `ops/schedule.json` — OS úloha 1× v 02:00,
wrapper pak loopuje á interval v okně). Data ověřena, dashboard servíruje, dokumentace (interní + public) hotová.
**Hlavní cíl** (podklad pro permission sety per uživatel místo SUPER) je naplněn: po namapování jmen v záložce Uživatelé
ukazuje Aktivita **kdo** co reálně používá → z toho se sestaví role (export CSV); RT0031 pak po zúžení práv hlídá chybějící oprávnění.

**Přidáno 2026-06-16 (Push #41→#58):** modul A dedup fix; modul B newest-first + backfill + **bulk insert** + token-refresh;
**mazání audit záznamů** (purge přes ops frontu); **provozní ovládání z dashboardu** (stav úloh / stop import / restart služby /
retence / plán importu okno+četnost+dny+auto-start); záložky **Databáze** (stav SQL) a **Nastavení auditu**; per-sloupcové filtry,
datum `2026.06.07`, filtr data rozmezí, export CSV, velikost DB, běžící čas+stáří dat; access-check fail-open + tečková maska.
Web služba (LocalSystem) **nesahá na SQL/BC** — vše přes svc/ops; whitelist = firewall rule, ostatní config = JSON.
ESHOP/ESHOP02/TEST1/TEST2 vyřazeny + jejich audit (~340 000 řádků) smazán.

### Dashboard endpointy (Node služba)
`/access-check` · `/firewall/whitelist` (GET/PUT) · `/firewall/domain-profile` · `/refresh` (POST) ·
`/activity` · `/logs` · `/logfiles` · `/usermap` (GET/PUT) · `/changelog-companies` (GET/PUT) ·
`/changelog-purge` (POST) · `/ops-status` (GET) · `/tasks` (GET) · `/import-stop` (POST) · `/restart` (POST) ·
`/retention` (GET/PUT) · `/schedule` (GET/PUT). Statické: `index.html`, `data.json`, `exports/*`.

### Modul B — výběr firem + backfill (2026-06-10, rozšířeno 2026-06-16)
- **Záložka „⚙ Nastavení auditu"** (od 2026-06-16 samostatná, dřív sekce v ⚙ Nastavení): checkboxy per firma → `changelog-companies.json` (`{all,enabled}`).
  `BC_ChangeLog_Import` zapíše `all` (všech 12) a importuje jen `enabled` (když nastaveno; jinak vše). Umožní vypnout obří firmy.
  U každé firmy se zobrazuje **počet záznamů** (z `data.json.changeLogByCompany`); tlačítko **↻ Aktualizovat seznam firem** (spustí import → přepíše `all`).
- **Backfill past:** BC OData vrací max **~50000 řádků/dotaz** → import bere 50000/firma/běh, watermark `Entry_No gt MAX` **vzestupně** (od nejstarších).
  `AXIMA_CZ_ESHOP` má `EntryNo ~814M` → ascending backfill k současnosti nereálný.
- **Mazání záznamů (od 2026-06-16):** danger-zone „🗑 Smazat audit záznamy" (checkbox firem + potvrzení „SMAZAT") → `POST /changelog-purge` zapíše `ops/ops-request.json` → denní úloha (svc) v **purge-only režimu** provede `DELETE FROM dbo.BCChangeLog WHERE CompanyName IN(...)` + snapshot a **přeskočí import** (jinak by se smazané hned natáhly zpět); web na SQL nesahá. Skript `BC_ChangeLog_Purge.ps1`, hook v `Invoke-BCTelemetryDaily.ps1`, status přes `GET /ops-status`. ⚠ „Jen smazat" — pokud firma zůstává v `enabled`, příští normální import ji natáhne znovu od nejstarších; pro trvalé odstranění ji nejdřív odškrtni.
- **ESHOP vyřešeno 2026-06-16:** ESHOP je v `enabled` odškrtnutý (netáhne se) a jeho záznamy v `dbo.BCChangeLog` smazány přes purge (**85000 řádků**).

### Modul B import: newest-first + backfill (2026-06-16, Push #47)
- **Problém:** import jel jen `Entry_No gt MAX` vzestupně → u firmy s velkým objemem (0002 měl burst 7.6.) se zasekl ve staré historii a **k dnešku nedojel** (audit „nesynchronizoval" reálně, ne jen v zobrazení).
- **Nová strategie** (`BC_ChangeLog_Import.ps1`, gap-free, bez resetu, MAX/MIN drží hrany souvislého rozsahu):
  - **Phase 0** — prázdná firma → seed `orderby Entry_No desc top 5000` (nejnovější blok hned).
  - **Phase A** — dosync k současnosti: `Entry_No gt MAX` vzestupně, re-query do vyčerpání (gap-free, dojede k dnešku; jednorázový catch-up u 0002 ~100k).
  - **Phase B** — backfill historie: `Entry_No lt MIN` sestupně, **bounded `-BackfillRowsPerRun` (default 50000/firma/běh)** → historie se doplní za N běhů.
- **Optimální objem:** `BackfillRowsPerRun` = strop backfillu/firma/běh (50000); **`ForwardRowsPerRun`** = strop dosyncu/firma/běh (150000, pojistka proti zaseknutí — `2579999`). Catch-up velké firmy se dokončí za víc běhů.
- **Bulk insert** (SqlBulkCopy→#Staging→dedup, `fa08d7e`) — catch-up/backfill statisíců řádků za minuty. `ForwardRowsPerRun`=150000 strop dosyncu/firma/běh. **Token-refresh** (`4f22bce`): BC OAuth se po 45 min obnoví (dlouhý běh KVE jinak vypršel → 401).
- ⚠ **(starý) Výkon:** insert byl **řádek-po-řádku** (try/catch dedup). U velkého catch-upu (KVE) to trvá minuty až déle. **TODO: přepsat na bulk insert (staging + MERGE jako modul A)** — zásadní zrychlení. 0002 dosync ověřen: `forward +73290 → max=120219, min=1` (kompletní). KVE = velký objem, catch-up po dávkách.
- **Audit Table/Field No:** snapshot+UI+export doplněn o `TableNo` (Číslo tabulky, např. 2000000053 = Access Control) a `FieldNo` (Číslo pole) — důležité pro permission mining (přiřazení rolí). Access Control změny se logují a stahují.

### Audit — nejnovější + filtr Firma (2026-06-16, Push #46)
- **Bug:** `vw_DashAudit` = `TOP 100 PERCENT ... ORDER BY ChangedAt DESC` → SQL pořadí **ignoruje**; snapshot `SELECT TOP 5000 FROM vw_DashAudit` **bez ORDER BY** bral nejstarší blok (na dashboardu chyběl dnešek, audit „nesynchronizoval"). Fix: snapshot `SELECT TOP 5000 ... FROM dbo.BCChangeLog ORDER BY ChangedAt DESC` (+ `CompanyName`).
- **Audit tab:** přidán sloupec **Firma** (dropdown filtr) + ve vyhledávání + v export CSV.
- **Pozn. k importu:** modul B jede `Entry_No gt watermark` a **následuje nextLink → stáhne všechny nové nad watermarkem** (ne jen 5000) → enabled (malé) firmy jsou dosync. včetně dneška. „Newest-first" by mělo smysl jen u obřích firem (ESHOP), které jsou vyřazené. **Hluboká historie / objem stahování = otevřené téma** (viz „Plánované featury").
- **Trend** má dropdown firmy (Všechny / konkrétní) → sparkline + tabulka se přepočítají per firma. Data: `trendByCompany` (`BCPageDaily` GROUP BY DateKey,CompanyName) ve snapshotu.
- **Odebrána záložka „Kandidáti na vyřazení"** — byla redundantní (= Aktivita s `≤2` otevřeními, dnes řešitelné řazením sloupce Otevření / filtrem / exportem). SQL pohled `vw_DashTrimCandidates` v `sql/` ponechán (neškodný orphan, drop by chtěl DDL); snapshot už pole `trimCandidates` negeneruje.

### Export CSV pro permission mining (2026-06-16, Push #44)
- Tlačítko **⬇ Export CSV** v tabulkách Aktivita / Kandidáti / Audit / RT0031 → stáhne **aktuálně filtrované + seřazené** řádky jako CSV
  (**UTF-8 BOM + oddělovač `;`** = otevře se rovnou v českém Excelu), s **reálnými jmény** (z `usermap`) místo GUID.
- **Workflow role miningu:** vyfiltruj (Firma / uživatel) → Export CSV → v Excelu kontingenční tabulka (řádky = Page ID/Stránka, sloupce/filtr = uživatel)
  → seznam objektů, kam uživatel/role reálně chodí → z toho permission set v BC. Generuje se klientsky z `data.json` (žádný server/restart).
- ⚠ Pozor na strop snapshotu `TopRows=5000`/sekce (teď ~400 řádků, bez dopadu); kdyby kombinací user×page přibylo přes 5000, dlouhý ocas (málo používané stránky) by se ořízl → řešit server-side CSV endpointem.

### Dashboard rozšíření (2026-06-16, Push #43)
- **Velikost lokální DB** v sync pruhu (data využito/alok. + log MB). Exportér počítá ze `sys.database_files` → `data.json.dbSize`.
- **Per-sloupcové filtry** v tabulkách Aktivita / Kandidáti / Audit / RT0031: řádek pod hlavičkou; Firma a Akce = dropdown (kategorie), text/datum = „obsahuje", číselné sloupce bez filtru (`SELECT_FILTER` / `NO_FILTER` v index.html).
- **Patička** `© Milan Trnka, IT`.
- **Ops fronta:** web (LocalSystem) zapisuje požadavky do `C:\Apps\BC_Telemetry_Web\ops\` (ACL pro svc nastaví `ensureOpsDir()` na bootu služby); denní úloha (svc) je zpracuje. ⚠ Změna `server.js` = **restart služby** (`Stop-Service`/wait STOPPED/`Start-Service` jako admin; `trnkam` nemá práva na vzdálený `sc` → restart dělá operátor na serveru).

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
- ~~Modul A jména: korelace GUID ↔ Entra sign-in logy~~ ✅ **VYŘEŠENO jinak (2026-06-10):** telemetrický GUID = BC „Telemetry User ID" → BC Users OData → **SQL `dbo.BCUser`** (`BC_Users_Import.ps1`, v denním wrapperu) → `vw_UserMap` → `usermap.json`. **LIVE 2026-06-10** — nasazeno + ověřeno **63 jmen** na dashboardu (runbook [deploy-users-2026-06-10.md](deploy-users-2026-06-10.md)). Cesta past, co kously: filtrovaný index → `SET QUOTED_IDENTIFIER ON` (sqlcmd OFF); `server.js` musel dojet na server + restart služby (jinak `/usermap` 404); svc potřeboval `icacls (M)` na `usermap.json` (WriteAllText „Access denied"). OData pole: `User_Telemetry_ID`/`Full_Name`/… auto-detekováno.
- ~~Import: stahovat z cloudu od nejnovějších po nejstarší~~ ✅ A/C KQL `order by timestamp desc`. Modul B ponechán `asc` (watermark + `$top=5000` — desc by při >5000 nových vynechal starší → díra).
- ~~Dashboard: celkový počet záznamů cloud vs SQL~~ ✅ sync pruh má teď „Celkem SQL / cloud (%)" jako součet přes moduly z `BCSyncStatus`.
- 📖 **Anonymizovaný public step-by-step návod** (na maxferit web, jako showcase/lead-gen) —
  samostatný deliverable, **bez identifikace firmy**: nahradit AXIMA / company names / tenant+subscription
  GUIDy / SP client ID / iKey / reálná jména (MTRNKA) / interní IP (10.8.2.225, BSWNAV01) za placeholdery
  (`<tenant-id>`, `<company>`, `<server>`…). Interní docs proto píšeme sanitizovatelně (firemní hodnoty
  v oddělených tabulkách „klíčové ID" + parametrech skriptů). Repo se celé nepublikuje.
