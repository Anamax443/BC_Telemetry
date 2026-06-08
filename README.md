# BC_Telemetry

Telemetrie aktivity uživatelů **Business Central Cloud** → **Azure Application Insights** → **SQL** →
**interní admin dashboard**. Sbíraná data slouží k sestavení Permission Setů (kdo co reálně používá).

> Interní nástroj AXIMA spol. s r.o. · BC 27.5 · Production/CZ · Verze 1.1 (2026-06-08)

## Architektura

```
BC Cloud ──telemetrie──▶ Azure App Insights / Log Analytics
                          │  DCR filtr: clientType == "Web"
                          ▼
   PowerShell (denně 02:00, Service Principal, inkrementálně)
                          ▼
   SQL BSWNAV01:  dbo.BCPageLog (raw, miliony, retence 6 měs.)
                          │  usp_BCPageLog_Rollup
                          ▼
   dbo.BCPageDaily + vw_Dash*  (agregáty — malé, kumulují navždy)
                          │  Export-DashboardSnapshot.ps1
                          ▼
   web/data.json ──▶ služba BC_Telemetry_Web (Node+NSSM na 10.8.2.225)
                     ├─ dashboard (anonymně, bez loginu)
                     └─ ⚙ Nastavení → whitelist (firewall rule, jako ITDashboard)
```

Raw log se po retenci maže; **agregáty se kumulují** — dashboard čte jen z nich, takže je rychlý
i při milionech raw záznamů. Web hostuje malá Node služba (kvůli editovatelnému whitelistu);
whitelist je formální visibility gate přes Windows Firewall rule.

## Struktura repa

| Cesta | Co |
|---|---|
| [docs/project-status.html](docs/project-status.html) | **Project status** — milestones + kde jsme (otevři v prohlížeči) |
| [BUILD.md](BUILD.md) | **Krok-za-krokem jak to postavit** (Azure → BC → SQL → scheduler → dashboard) |
| [docs/dokumentace.md](docs/dokumentace.md) | Technická dokumentace (v1.1) |
| [docs/oponentury/](docs/oponentury/) | Archiv oponentury + strukturovaná reakce |
| [sql/01_schema.sql](sql/01_schema.sql) | Raw tabulka, indexy, dedup, retence, analytický view |
| [sql/02_aggregates.sql](sql/02_aggregates.sql) | Rollup tabulky, inkrementální proc, dashboard pohledy |
| [scripts/Install-Prereqs.ps1](scripts/Install-Prereqs.ps1) | Instalace Az + CredentialManager modulů |
| [scripts/BC_PageLog_Import.ps1](scripts/BC_PageLog_Import.ps1) | Import z Azure → SQL (SP auth, staging+MERGE, rollup, retence) |
| [scripts/Export-DashboardSnapshot.ps1](scripts/Export-DashboardSnapshot.ps1) | Agregáty → `web/data.json` |
| [scripts/Register-ScheduledTask.ps1](scripts/Register-ScheduledTask.ps1) | Denní úloha 02:00 (LogonType Password) |
| [scripts/install-service.cmd](scripts/install-service.cmd) | Instalace web služby `BC_Telemetry_Web` (Node+NSSM) na 10.8.2.225 |
| [scripts/Set-DashboardWhitelist.cmd](scripts/Set-DashboardWhitelist.cmd) | CLI změna whitelistu (firewall rule remoteip) |
| [web/index.html](web/index.html) | Admin dashboard — KPI + Aktivita / Kandidáti / Migrace / Trend / ⚙ Nastavení |
| [web/server.js](web/server.js) | Web služba — servíruje dashboard + whitelist API (čte/zapisuje firewall rule) |
| [docs/deploy-10.8.2.225.md](docs/deploy-10.8.2.225.md) | Deploy na SQL box (Node služba, whitelist, GPO AllSigned) |

## Quick start

Viz [BUILD.md](BUILD.md). Stručně: `Install-Prereqs.ps1` → SQL `01`+`02` → Service Principal →
BC Admin Center telemetrie ON → `Register-ScheduledTask.ps1` → IIS + snapshot.

## Stav

Dokumentace + skripty + dashboard hotové (v1.1, zapracována oponentura 2026-06-08). Před nasazením:
doplnit reálné GUID (Workspace, SP ClientId), pilot 1–2 týdny s monitoringem.

## Licence

Private — all rights reserved.
