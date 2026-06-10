# BC_Telemetry

Telemetrie aktivity uživatelů **Business Central Cloud** → **Azure Application Insights** → **SQL** →
**interní admin dashboard**. Sbíraná data slouží k sestavení Permission Setů (kdo co reálně používá).

> Interní nástroj AXIMA spol. s r.o. · BC Production/CZ · **🟢 LIVE od 2026-06-10** (10.8.2.225)

## Architektura

```
BC Cloud ──telemetrie──▶ Azure App Insights / Log Analytics
                          │  (Service Principal, neinteraktivně)
        modul A (AppPageViews) · modul C (AppTraces RT0031) · modul B (Change Log → OData)
                          ▼
   PowerShell denně 02:00 jako svc (inkrementálně) ──▶ SQL 10.8.2.225 (raw, retence)
                          │  rollup procy
                          ▼
   agregáty (dbo.*Daily + vw_Dash*) + dbo.BCSyncStatus  (kumulují navždy)
                          │  Update-SyncStatus + Export-DashboardSnapshot.ps1
                          ▼
   web/data.json ──▶ služba BC_Telemetry_Web (Node+NSSM na 10.8.2.225)
                     ├─ dashboard (bez loginu): KPI, Aktivita, Kandidáti, Uživatelé, Audit, RT0031, Trend, Terminál
                     └─ ⚙ Nastavení → whitelist (firewall rule) + ruční obnova + údržba logů
```

Raw log se po retenci maže; **agregáty se kumulují** — dashboard čte jen z nich, takže je rychlý
i při milionech raw záznamů. Web hostuje malá Node služba (kvůli editovatelnému whitelistu);
whitelist je formální visibility gate přes Windows Firewall rule.

## Struktura repa

| Cesta | Co |
|---|---|
| [docs/HANDOFF.md](docs/HANDOFF.md) | **Rolling handoff** — aktuální stav, klíčové ID, další kroky (start tady) |
| [docs/navod-interni-axima.md](docs/navod-interni-axima.md) | **Kompletní build návod (INTERNÍ)** — plné hodnoty, 10 fází od Azure po dashboard |
| [docs/navod-public.md](docs/navod-public.md) | **Build návod (sanitizovaný, k publikaci)** — sdílené tělo s placeholdery |
| [docs/SETUP-STEP-BY-STEP.md](docs/SETUP-STEP-BY-STEP.md) | **Detailní runbook** — jak to bylo postaveno (Azure/BC/SP/S2S), reálné schéma |
| [docs/project-status.html](docs/project-status.html) | **Project status** — milestones + kde jsme (otevři v prohlížeči) |
| [docs/modules.md](docs/modules.md) | **3 moduly** — A využití stránek (live), B audit změn (Change Log), C permission errors (RT0031) |
| [sql/04_audit.sql](sql/04_audit.sql) | Modul B (dbo.BCChangeLog) + Modul C (RT0031 raw+rollup) |
| [scripts/BC_ChangeLog_Import.ps1](scripts/BC_ChangeLog_Import.ps1) | Modul B — BC Change Log přes OData → SQL (reálný uživatel) |
| [scripts/BC_AuthFail_Import.ps1](scripts/BC_AuthFail_Import.ps1) | Modul C — RT0031 z AppTraces → SQL |
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
| [web/index.html](web/index.html) | Admin dashboard — KPI + Aktivita / Kandidáti / Uživatelé / Audit / RT0031 / Trend / Terminál / Nastavení; dark mode |
| [web/server.js](web/server.js) | Web služba — dashboard + API (whitelist, /refresh, /activity, /logs, /logfiles, /usermap) |
| [sql/deploy.cmd](sql/deploy.cmd) · [sql/deploy-full.sql](sql/deploy-full.sql) | SQL deploy (GPO-safe `sqlcmd` / konsolidovaný blok pro SSMS) |
| [scripts/New-ServiceAccount.ps1](scripts/New-ServiceAccount.ps1) | Založení doménového svc účtu (klon z svc-itdashboard) |
| [scripts/Invoke-BCTelemetryDaily.ps1](scripts/Invoke-BCTelemetryDaily.ps1) | Denní wrapper — 3 importy + sync-status + snapshot + retence logů |
| [scripts/Update-SyncStatus.ps1](scripts/Update-SyncStatus.ps1) | Sync-status — cloud vs zesynchronizováno per modul → dbo.BCSyncStatus |
| [docs/deploy-10.8.2.225.md](docs/deploy-10.8.2.225.md) | Deploy na SQL box (Node služba, whitelist, GPO AllSigned) |

## Quick start

Kompletní postup od nuly: **[docs/navod-interni-axima.md](docs/navod-interni-axima.md)** (interní) /
[docs/navod-public.md](docs/navod-public.md) (sanitizovaný). Stručně: Azure App Insights → BC telemetrie ON →
Service Principal (Log Analytics Reader + BC API S2S) → SQL deploy (`sql/deploy.cmd`) → svc účet + secret →
importy + `Register-ScheduledTask.ps1` → dashboard `install-service.cmd`.

## Stav

**🟢 LIVE od 2026-06-10** na 10.8.2.225 — celý řetězec běží plně automaticky (denně 02:00 jako svc):
import 3 modulů + rollup + sync-status + snapshot → dashboard. Hlavní cíl (podklad pro permission sety
per uživatel místo SUPER) naplněn — po namapování jmen (záložka Uživatelé) je vidět, kdo co reálně používá.

## Licence

Private — all rights reserved.
