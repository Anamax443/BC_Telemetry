# Business Central — Telemetrie (technická dokumentace)

> Interní dokumentace · AXIMA spol. s r.o.
> Verze BC: 27.5 · Prostředí: Production / CZ · Vytvořeno: 2026-04 · Autor: Milan Trnka
> **Dokument v1.1** — zapracována oponentura 2026-06-08 (viz [oponentury/](oponentury/)).

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

Data Collection Rule filtruje záznamy ještě před uložením do Log Analytics — zahazuje Job Queue,
Web Services a API volání. Zachovává pouze akce reálných uživatelů v prohlížeči.

**Navigace:** Azure Portal → Log Analytics Workspace → Settings → Tables → pravý klik → Create Transformation.

```kql
source
| where clientType == "Web"
```

> ⚠ **Oprava v1.1 (oponentura #1):** jednotný whitelist `== "Web"` pro **AppTraces i AppPageViews**.
> Původní blacklist `!in ("Background","WebService","ODataV4","Api")` u AppTraces propouštěl Mobile/Desktop/TeamMember.

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

## 08 · Agregační vrstva (v1.1 — škála)

Raw log má miliony řádků a po retenci (6 měsíců) se maže. Agregáty `dbo.BCPageDaily` jsou malé
a kumulují se navždy — dashboard čte jen z nich. Inkrementální rollup (`usp_BCPageLog_Rollup`)
zpracuje jen nové raw řádky (Id > watermark). Detail viz [sql/02_aggregates.sql](../sql/02_aggregates.sql).

## 09 · KQL dotaz

Stahuje **jen nové** záznamy od watermarku (v1.1 — ne fixních 90 dní). Plná verze v importním skriptu.

```kql
pageViews
| where timestamp > datetime(<lastTimestamp>)
| where clientType == "Web"
| extend userId      = tostring(customDimensions["aadUserId"])
| extend userName    = tostring(customDimensions["aadUserName"])
| extend pageId      = tostring(customDimensions["alObjectId"])
| extend pageName    = tostring(customDimensions["alObjectName"])
| extend companyName = tostring(customDimensions["companyName"])
| project timestamp, userId, userName, pageId, pageName, companyName
| order by timestamp asc
```

## 10 · Import + scheduler

- [scripts/BC_PageLog_Import.ps1](../scripts/BC_PageLog_Import.ps1) — SP auth → watermark → SqlBulkCopy do staging → MERGE (dedup) → rollup → retence. Atomicky (try/catch + transakce).
- [scripts/Register-ScheduledTask.ps1](../scripts/Register-ScheduledTask.ps1) — denní úloha 02:00, LogonType **Password** (doménový účet).
- [scripts/Export-DashboardSnapshot.ps1](../scripts/Export-DashboardSnapshot.ps1) — agregáty → `web/data.json`.

## 11 · RBAC — servisní účet `AXIMA\svc_bc_telemetry`

| Oprávnění | Kde |
|---|---|
| Azure role `Log Analytics Reader` | na Service Principal, scope = workspace |
| SQL `db_datareader` + `db_datawriter` | databáze BC_Telemetry |
| EXECUTE na `usp_BCPageLog_Rollup`, `usp_BCPageLog_Purge` | databáze BC_Telemetry |
| `Log on as batch job` | lokální policy serveru |

Azure auth přes **Service Principal** (Client Secret v Credential Manageru / Key Vault) — ne interaktivní `Connect-AzAccount`.

## 12 · Workflow sestavení Permission Setů

1. Uživatel pracuje pod plným přístupem → telemetrie loguje vše, co reálně otevírá.
2. Sledovací období ~3 měsíce, data se kumulují v `dbo.BCPageDaily`.
3. Analýza: dashboard → frequently vs. jednou otevřené (≤2 návštěvy = kandidát na vyřazení).
4. Návrh rolí (Fakturace, Sklad, Reporting…) a Permission Set per role v BC.
5. Odebrat plný přístup, přiřadit role; sledovat `RT0031` (Authorization Failed) první 2 týdny.
6. Doladění dle RT0031 chyb.

> ⚠ Pod plným přístupem uživatel negeneruje RT0031 — telemetrie zachytí jen co otevřel, ne co mu chybí. Po odebrání práv sledovat permission errors.
> Pozn. k oponentuře #9: záměrně se sleduje **pod neomezeným přístupem**, aby uživatel mohl normálně pracovat; read-only set by metodiku rozbil. Riziko se řeší time-boxem a monitoringem, ne čtecím setem — viz [reakce](oponentury/2026-06-08-reakce.md).
