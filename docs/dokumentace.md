# Business Central — Telemetrie (technická dokumentace)

> Interní dokumentace · AXIMA spol. s r.o.
> Verze BC: 27.5 · Prostředí: Production / CZ · Vytvořeno: 2026-04 · Autor: Milan Trnka
> **Dokument v1.2** — zapracována oponentura 2026-06-08 (viz [oponentury/](oponentury/)) + provozní změny
> Push #41→#58 (2026-06-16). Aktuální provozní stav vždy viz [HANDOFF.md](HANDOFF.md).

Sledování aktivity uživatelů v BC Cloud přes Azure Application Insights — sběr, import do SQL
a analýza pro sestavení Permission Setů. Praktické kroky zprovoznění viz [BUILD.md](../BUILD.md).

---

## 01 · Architektura

```
BC Cloud (Production)
  tenant: 2ecd5815-0eb9-4e9a-93be-ac58545cdca6
   │  telemetrie stream (HTTPS) — pouze clientType = Web
   ▼
Azure Application Insights
  resource: appinsights-bc-production · region: West Europe
   │  DCR filtr — zahazuje Background / WebService / API sessions
   ▼
Log Analytics Workspace
  tabulky: AppTraces, AppPageViews · retence: 30 dní
   │  PowerShell job (denně 02:00) — Invoke-AzOperationalInsightsQuery
   │  watermark přes MAX(Timestamp) → žádné duplicity
   ▼
SQL Server — BSWNAV01
  databáze: BC_Telemetry · raw: dbo.BCPageLog · agregáty: dbo.BCPageDaily
```

> ⚠ **Restart prostředí:** Nastavení Connection String v BC Admin Center vyžaduje restart BC prostředí. Provádět mimo pracovní dobu.

## 02 · Náklady

| Položka | Objem | Cena / měsíc | Poznámka |
|---|---|---|---|
| AppInsights ingestion — free tier | 0–5 GB | **$0** | Zahrnuto automaticky |
| AppInsights ingestion — nad free tier | nad 5 GB | ~$2,50 / GB | Po DCR filtru nepravděpodobné |
| Data export z Azure | — | **$0** | Download do lokální sítě zdarma |
| Retence 30 dní | — | **$0** | Default |
| Purge API volání | — | **$0** | — |
| **Reálný odhad (60 uživatelů + DCR filtr)** | ~1–3 GB | **$0** | Ve free tier |

> ℹ Background sessions (Job Queue, Web Services, API) tvoří 60–80 % objemu telemetrie. DCR filtr na `clientType == "Web"` je klíčový pro udržení nákladů na nule.

## 03 · Azure Application Insights — setup

1. **Resource Group** — `rg-bc-telemetry`, region West Europe.
2. **Application Insights** — `appinsights-bc-production`, Resource Mode **Workspace-based**.
3. **Connection String** — Overview → zkopírovat (`InstrumentationKey=…;IngestionEndpoint=…`).
4. **Retence + Daily Cap** — Workspace → Usage and estimated costs → retence 30 dní, Daily Cap 0,5 GB/den.

## 04 · BC Admin Center — setup

1. `https://businesscentral.dynamics.com/2ecd5815-0eb9-4e9a-93be-ac58545cdca6/admin`
2. Environments → Production → Telemetry → Define → Enable **ON** → vložit Connection String → Save.

> ✓ Po uložení začne BC okamžitě odesílat telemetrii. Data v AppInsights se objeví do 5 minut.

## 05 · DCR filtr — pouze interaktivní uživatelé

Data Collection Rule by filtroval záznamy ještě před uložením do Log Analytics — zahazuje Job Queue,
Web Services a API volání, zachovává jen interaktivní uživatele.

> **v1.2 — DCR ODLOŽEN.** Reálný objem je hluboko pod 5 GB free tier → **náklady $0 i bez filtru**.
> DCR transformace je navíc křehká (při chybě tiše zahazuje data). Proto **filtrujeme v importu**
> (clientType whitelist v KQL, §09), což máme pod kontrolou. DCR zapneme jen kdyby se objem blížil 5 GB.

> ⚠ **Oprava v1.2 (reálná data 2026-06-08):** hodnota pro prohlížeč je **`WebClient`/`Desktop`**, NE
> „Web" (ten by nematchnul nic!). Interaktivní whitelist = `clientType in ("WebClient","Web","Desktop","Tablet","Phone")`.
> To potvrdilo původní blacklist přístup z dokumentace v1.0 — oponentura #1 „== Web" byla pro tohle
> prostředí mylná. Background (~95 %) se vyřazuje filtrem v importu.

```kql
// až/pokud se DCR zapne — transformace na AppPageViews i AppTraces:
source
| where clientType in ("WebClient","Web","Desktop","Tablet","Phone")
```

## 06 · SQL schéma — dbo.BCPageLog

Append log každého page view. Veškerá analytika dotazy nad daty. Plný DDL viz [sql/01_schema.sql](../sql/01_schema.sql).

| Sloupec | Typ | Pozn. |
|---|---|---|
| Id | INT IDENTITY PK | clustered |
| Timestamp | DATETIME2(3) | ms přesnost pro watermark |
| UserId | NVARCHAR(100) | aadUserId |
| UserName | NVARCHAR(200) | aadUserName |
| PageId | NVARCHAR(50) | alObjectId |
| PageName | NVARCHAR(200) | alObjectName |
| CompanyName | NVARCHAR(100) | |
| ImportDatum | DATETIME2(3) | default SYSUTCDATETIME() |

## 07 · Indexy

| Index | Účel | Typ |
|---|---|---|
| `PK_BCPageLog` | clustered na Id | Clustered |
| `IX_BCPageLog_UserName_Timestamp` | dotazy per uživatel (covering) | Non-clustered |
| `IX_BCPageLog_Timestamp` | watermark MAX(Timestamp) | Non-clustered |
| `UX_BCPageLog_Dedup` | anti-duplicita (Timestamp, UserId, PageId) | Unique filtered (v1.1) |
| `UX_BCChangeLog_Company_EntryNo` | anti-duplicita auditu (CompanyName, EntryNo) | Unique (modul B, v1.2) |

## 08 · Agregační vrstva (v1.1 — škála)

Raw log má miliony řádků a po retenci (6 měsíců) se maže. Agregáty `dbo.BCPageDaily` jsou malé
a kumulují se navždy — dashboard čte jen z nich. Inkrementální rollup (`usp_BCPageLog_Rollup`)
zpracuje jen nové raw řádky (Id > watermark). Detail viz [sql/02_aggregates.sql](../sql/02_aggregates.sql).

## 09 · KQL dotaz (v1.2 — ověřeno na reálných datech 2026-06-08)

Import jede přes **Log Analytics workspace** → tabulka **`AppPageViews`** (ne classic `pageViews`),
BC custom dimensions v **`Properties.*`** (ne `customDimensions`), identita uživatele v **`UserId`**
(pseudonymní GUID; `UserAuthenticatedId`/`aadUserId` jsou prázdné/neexistují). Interaktivní klienti
jsou **`Desktop`/`WebClient`** (NE „Web"). Stahuje jen nové záznamy od watermarku.

```kql
AppPageViews
| where TimeGenerated > datetime(<lastTimestamp>)
| where tostring(Properties.clientType) in ('WebClient','Web','Desktop','Tablet','Phone')
| extend userId      = tostring(UserId)
| extend userName    = tostring(UserId)
| extend pageId      = tostring(Properties.alObjectId)
| extend pageName    = tostring(Properties.alObjectName)
| extend companyName = tostring(Properties.companyName)
| project timestamp = TimeGenerated, userId, userName, pageId, pageName, companyName
| order by timestamp asc
```

> **userName = GUID** (jméno není v telemetrii). Mapování GUID→osoba se dělá korelací s Entra
> sign-in logy do `dbo.BCUserMap`; pro role-mining stačí grupovat podle GUID. Viz §12 + [reakce](oponentury/2026-06-08-reakce.md).

## 10 · Import + scheduler

- [scripts/BC_PageLog_Import.ps1](../scripts/BC_PageLog_Import.ps1) — SP auth → watermark → SqlBulkCopy do staging → MERGE (dedup) → rollup → retence. Atomicky (try/catch + transakce).
  > 🔧 **Oprava v1.2 (2026-06-16):** duplicity **uvnitř** jedné stažené dávky shazovaly transakci (rollback) → zamrzlý watermark. Fix: ve staging dedup `ROW_NUMBER() OVER (PARTITION BY Timestamp, UserId, ISNULL(PageId,'')) = 1` před MERGE.
- [scripts/BC_ChangeLog_Import.ps1](../scripts/BC_ChangeLog_Import.ps1) — modul B, newest-first + backfill + bulk insert (viz [modules.md](modules.md)).
- [scripts/Register-ScheduledTask.ps1](../scripts/Register-ScheduledTask.ps1) — OS úloha (LogonType **Password**, doménový účet) běží **1× v `startTime`** a předá řízení wrapperu.
- [scripts/Invoke-BCTelemetryDaily.ps1](../scripts/Invoke-BCTelemetryDaily.ps1) — **wrapper řídí repetici/okno/dny** (NE OS scheduler — trigger nejde z LocalSystem měnit bez hesla svc, HRESULT `0x8007052e`) dle `ops/schedule.json` `{startTime,endTime,intervalMinutes,days[0=Ne..6=So]}`; loop á interval do `endTime`, brána dle dnů; manuál `/refresh` → `ops/oneshot.flag` = 1 běh; v loopu drahý cloud sync-status jen 1×/60 min.
- [scripts/Export-DashboardSnapshot.ps1](../scripts/Export-DashboardSnapshot.ps1) — agregáty → `web/data.json`. Rozšířeno (v1.2) o `dbSize`, `dbInfo`, `dbTables`, `changeLogByCompany`, `trendByCompany`; `changeLog` nově `ORDER BY ChangedAt DESC` (nejnovějších 5000) + `CompanyName/TableNo/FieldNo`.
  > 🔧 `vw_DashAudit` měl `TOP 100 PERCENT ORDER BY`, který SQL ignoruje → snapshot ukazoval nejstarší. Opraveno řazením přímo v exportu.

> **Provoz z dashboardu (Push #58):** retenční politika a plán importu se konfigurují přes JSON v `ops/` (`retention.json`, `schedule.json`), importní skripty + wrapper je čtou. Web (LocalSystem) je jen zapisuje — **nesahá na SQL ani BC**, viz §11.

## 11 · RBAC — servisní účet `AXINETWORK\svc-bc-telemetry`

| Oprávnění | Kde |
|---|---|
| Azure role `Log Analytics Reader` | na Service Principal, scope = workspace |
| SQL `db_datareader` + `db_datawriter` | databáze BC_Telemetry |
| EXECUTE na `usp_BCPageLog_Rollup`, `usp_BCPageLog_Purge`, `usp_BCChangeLog_Purge`, `usp_BCAuthFail_Rollup` | databáze BC_Telemetry |
| `Log on as batch job` | lokální policy serveru |

Azure auth přes **Service Principal** (Client Secret v Credential Manageru / Key Vault) — ne interaktivní `Connect-AzAccount`.

> **Princip izolace (Push #41→#58):** veškerý přístup k SQL i BC má **jen `svc-bc-telemetry`** (denní úloha / ops fronta).
> Web služba `BC_Telemetry_Web` běží pod **LocalSystem** a na SQL ani BC **nesahá** — provozní akce (mazání auditu,
> stop/restart importu, plán, retence) vkládá jako požadavky do JSON souborů v `C:\Apps\BC_Telemetry_Web\ops`
> (web zakládá adresář + ACL pro svc na bootu, `runPs` má timeout 90 s); vyřídí je svc. **Reálné vynucení** viditelnosti
> dashboardu = **Windows Firewall rule** (whitelist); ostatní konfigurace jsou jen JSON.
> Access-check (whitelist) je **fail-open při prázdné cache** (po restartu nezamkne přístup) a umí i tečkovou masku CIDR (`10.8.2.0/255.255.255.0`).

## 12 · Workflow sestavení Permission Setů

1. Uživatel pracuje pod plným přístupem → telemetrie loguje vše, co reálně otevírá.
2. Sledovací období ~3 měsíce, data se kumulují v `dbo.BCPageDaily`.
3. Analýza: dashboard → frequently vs. jednou otevřené (≤2 návštěvy = kandidát na vyřazení).
4. Návrh rolí (Fakturace, Sklad, Reporting…) a Permission Set per role v BC.
5. Odebrat plný přístup, přiřadit role; sledovat `RT0031` (Authorization Failed) první 2 týdny.
6. Doladění dle RT0031 chyb.

> ⚠ Pod plným přístupem uživatel negeneruje RT0031 — telemetrie zachytí jen co otevřel, ne co mu chybí. Po odebrání práv sledovat permission errors.
> Pozn. k oponentuře #9: záměrně se sleduje **pod neomezeným přístupem**, aby uživatel mohl normálně pracovat; read-only set by metodiku rozbil. Riziko se řeší time-boxem a monitoringem, ne čtecím setem — viz [reakce](oponentury/2026-06-08-reakce.md).
