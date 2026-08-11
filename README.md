# BC_Telemetry

Telemetrie aktivity uživatelů **Business Central Cloud** → **Azure Application Insights** → **SQL** →
**interní admin dashboard**. Sbíraná data slouží k sestavení Permission Setů (kdo co reálně používá).

> Interní nástroj AXIMA spol. s r.o. · BC Production/CZ · **🟢 LIVE od 2026-06-10** (10.8.2.225) · **Push #65**

## Architektura

```
BC Cloud ──telemetrie──▶ Azure App Insights / Log Analytics
                          │  (Service Principal, neinteraktivně)
        modul A (AppPageViews) · modul C (AppTraces RT0031) · modul B (Change Log → OData)
                          ▼
   wrapper Invoke-BCTelemetryDaily.ps1 jako svc-bc-telemetry (inkrementálně) ──▶ SQL 10.8.2.225 (raw, retence)
                          │  rollup procy
                          ▼
   agregáty (dbo.*Daily + vw_Dash*) + dbo.BCSyncStatus  (kumulují navždy)
                          │  Update-SyncStatus + Export-DashboardSnapshot.ps1
                          ▼
   web/data.json ──▶ služba BC_Telemetry_Web (Node+NSSM na 10.8.2.225, LocalSystem)
                     ├─ dashboard (bez loginu, 🇨🇿/🇬🇧 CS+EN): KPI + velikost DB + běžící čas/stáří dat + indikátor spojení s BC, Aktivita, Uživatelé, Audit (Firma/Table No/Field No), RT0031, Trend (dle firmy), Databáze (stav SQL), Terminál (per-sloupcové filtry + stránkování + ⬇ export CSV/TXT/HTML/PDF celé filtrované sady; responzivní mobil/tablet)
                     ├─ 📊 Manažerská zpráva (grafy + kumulace, HTML/PDF) · 📖 Dokumentace (uživatelská příručka + technická, tisk/PDF)
                     ├─ ⚙ Nastavení auditu → výběr firem modulu B + počty/firma + ↻ refresh + 🗑 mazání audit záznamů
                     └─ ⚙ Nastavení → Spojení s BC (jsme napojení na tenant?) + whitelist (firewall rule; literál + CIDR zobrazení + ☑ neomezený přístup) + ruční obnova + Správa služby/úloh (stop/restart/plán importu/retence)
```

Raw log se po retenci maže; **agregáty se kumulují** — dashboard čte jen z nich, takže je rychlý
i při milionech raw záznamů. Web hostuje malá Node služba (kvůli editovatelnému whitelistu).

> **Architektonický princip (Push #41→#65):** web služba běží pod **LocalSystem** a **NEsahá na SQL ani BC**
> — veškerý přístup k datům jde přes účet **`svc-bc-telemetry`** (denní úloha / ops fronta). Dashboard žádá
> akce přes JSON ops soubory v `C:\Apps\BC_Telemetry_Web\ops`, které vyřídí svc (mazání auditu, import,
> plán). Reálné vynucení viditelnosti = **Windows Firewall rule** (whitelist); ostatní konfigurace
> (výběr firem, retence, plán) jsou jen **JSON soubory**.

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
| [scripts/BCApi.psm1](scripts/BCApi.psm1) | **Jediná cesta k BC API** — token+obnova, brzda požadavků/min, opakování při 429 (`Retry-After`) a 5xx, `Data-Access-Intent: ReadOnly`, `$select`, degradace místo pádu, souhrn v logu |
| [docs/bc-api-integrace-standard.md](docs/bc-api-integrace-standard.md) | **Pravidla pro všechny aplikace čtoucí z BC** — 1 aplikace = 1 service principal, read-only sada, limity BC, registr SP + expirací |
| [scripts/BC_AuthFail_Import.ps1](scripts/BC_AuthFail_Import.ps1) | Modul C — RT0031 z AppTraces → SQL |
| [BUILD.md](BUILD.md) | **Krok-za-krokem jak to postavit** (Azure → BC → SQL → scheduler → dashboard) |
| [docs/dokumentace.md](docs/dokumentace.md) | Technická dokumentace (v1.2) |
| [docs/oponentury/](docs/oponentury/) | Archiv oponentury + strukturovaná reakce |
| [sql/01_schema.sql](sql/01_schema.sql) | Raw tabulka, indexy, dedup, retence, analytický view |
| [sql/02_aggregates.sql](sql/02_aggregates.sql) | Rollup tabulky, inkrementální proc, dashboard pohledy |
| [scripts/Install-Prereqs.ps1](scripts/Install-Prereqs.ps1) | Instalace Az + CredentialManager modulů |
| [scripts/BC_PageLog_Import.ps1](scripts/BC_PageLog_Import.ps1) | Import z Azure → SQL (SP auth, staging+MERGE, rollup, retence) |
| [scripts/Export-DashboardSnapshot.ps1](scripts/Export-DashboardSnapshot.ps1) | Agregáty → `web/data.json` |
| [scripts/Register-ScheduledTask.ps1](scripts/Register-ScheduledTask.ps1) | Denní úloha 02:00 (LogonType Password) |
| [scripts/install-service.cmd](scripts/install-service.cmd) | Instalace web služby `BC_Telemetry_Web` (Node+NSSM) na 10.8.2.225 |
| [scripts/Set-DashboardWhitelist.cmd](scripts/Set-DashboardWhitelist.cmd) | CLI změna whitelistu (firewall rule remoteip) |
| [web/index.html](web/index.html) | Admin dashboard — KPI + velikost DB + běžící čas/stáří dat + Aktivita / Uživatelé / Audit (Firma/Table No/Field No) / RT0031 / Trend (dle firmy) / Databáze / Terminál / Nastavení auditu / Nastavení; per-sloupcové filtry + stránkování tabulek (50/100/200/500/vše, výchozí v ⚙ Nastavení → localStorage) + export CSV celé filtrované sady; responzivní layout (mobil/tablet — KPI 4→2→1, horizontální scroll širokých tabulek, media queries ≤820/≤480 px); dark mode |
| [web/server.js](web/server.js) | Web služba (LocalSystem, nesahá na SQL/BC) — dashboard + API: whitelist, /refresh, /activity, /logs, /logfiles, /usermap, /changelog-companies, /changelog-purge, /ops-status, /tasks, /import-stop, /restart, /retention, /schedule, **/bc-status, /bc-check**; ops dir + ACL pro svc, runPs timeout 90 s |
| [scripts/BCApi.psm1](scripts/BCApi.psm1) | Jediná cesta k BC API — token + obnova, retry 429/5xx dle `Retry-After`, brzda req/min, `Data-Access-Intent: ReadOnly`, `$select`, degradace místo pádu; `Write-BCApiStatus` → `ops/bc-status.json` (stav spojení pro dashboard) |
| [scripts/Test-BCConnection.ps1](scripts/Test-BCConnection.ps1) | Živé ověření spojení s BC na vyžádání (token + `Company?$select=Name`) → `ops/bc-status.json`; spouští ho úloha `BC_Telemetry_BCCheck` jako svc |
| [scripts/Register-BCCheckTask.ps1](scripts/Register-BCCheckTask.ps1) | Jednorázová registrace úlohy `BC_Telemetry_BCCheck` (bez triggeru, kopne do ní dashboard) |
| [scripts/Send-BCTelemetryNotification.ps1](scripts/Send-BCTelemetryNotification.ps1) | E-mailový souhrn + alerty (M365 Direct Send), konfigurace `ops/notify.json` |
| [scripts/BC_ChangeLog_Purge.ps1](scripts/BC_ChangeLog_Purge.ps1) | Modul B — smazání audit záznamů vybraných firem (ops-request od dashboardu, běží jako svc) |
| [sql/deploy.cmd](sql/deploy.cmd) · [sql/deploy-full.sql](sql/deploy-full.sql) | SQL deploy (GPO-safe `sqlcmd` / konsolidovaný blok pro SSMS) |
| [scripts/New-ServiceAccount.ps1](scripts/New-ServiceAccount.ps1) | Založení doménového svc účtu (klon z svc-itdashboard) |
| [scripts/Invoke-BCTelemetryDaily.ps1](scripts/Invoke-BCTelemetryDaily.ps1) | Denní wrapper — řídí repetici/okno/dny dle `ops/schedule.json` (NE OS scheduler): OS úloha 1× v startTime → loop á interval do endTime; 3 importy + sync-status + snapshot + retence logů; purge-only režim přes ops frontu |
| [scripts/Update-SyncStatus.ps1](scripts/Update-SyncStatus.ps1) | Sync-status — cloud vs zesynchronizováno per modul → dbo.BCSyncStatus |
| [docs/deploy-10.8.2.225.md](docs/deploy-10.8.2.225.md) | Deploy na SQL box (Node služba, whitelist, GPO AllSigned) |

## Quick start

Kompletní postup od nuly: **[docs/navod-interni-axima.md](docs/navod-interni-axima.md)** (interní) /
[docs/navod-public.md](docs/navod-public.md) (sanitizovaný). Stručně: Azure App Insights → BC telemetrie ON →
Service Principal (Log Analytics Reader + BC API S2S) → SQL deploy (`sql/deploy.cmd`) → svc účet + secret →
importy + `Register-ScheduledTask.ps1` → dashboard `install-service.cmd`.

## Stav

**🟢 LIVE od 2026-06-10** na 10.8.2.225, aktuálně **verze 78** (2026-08-11) — celý řetězec běží plně automaticky
(wrapper jako `svc-bc-telemetry` dle `ops/schedule.json`): import 3 modulů + rollup + sync-status +
snapshot → dashboard. Hlavní cíl (podklad pro permission sety per uživatel místo SUPER) naplněn — po
namapování jmen (záložka Uživatelé) je vidět, kdo co reálně používá. Dashboard nově umí provozní
ovládání (stop/restart importu, plán, retence, mazání auditu) přes ops frontu vyřizovanou svc účtem.
Modul B přepsán na newest-first + backfill s bulk insertem. Firmy ESHOP/ESHOP02/TEST1/TEST2 vyřazeny
ze sledování (jejich ~340 000 audit řádků smazáno).
**Push #60→#65:** vestavěná **📖 Dokumentace** (uživatelská příručka + technická, tisk/PDF), **rozšířený
export** tabulek (CSV/TXT/HTML/PDF), **📊 Manažerská zpráva** (grafy + kumulace, HTML/PDF), whitelist se
**zachováním literálu**, čitelným CIDR a **checkboxem „Neomezený přístup"** (`*`/`Any`).
**Push #73→#77:** Návrh role (per-firma scope + práh), RT0031 badge *LICENCE* vs *CHYBÍ ROLE* s číslem
tabulky, strop řádků snapshotu až 1M, auto-smazání dat odebrané firmy.
**2026-08-05:** [`BCApi.psm1`](scripts/BCApi.psm1) — odolná vrstva pro volání BC API (retry 429/5xx,
vlastní brzda, čtení z read-only repliky, `$select`, degradace místo pádu) + pravidla pro další
integrace v [`docs/bc-api-integrace-standard.md`](docs/bc-api-integrace-standard.md).
**v78 (2026-08-11):** dashboard je **dvojjazyčný CS/EN včetně vestavěné dokumentace** (přepínač
v hlavičce, přepnutí bez reloadu) a ukazuje **stav spojení s BC tenantem** — zelená/žlutá (>26 h bez
kontaktu)/červená s důvodem, zdroj `ops/bc-status.json` zapisovaný při každém volání BC. V hlavičce
je nově jen číslo verze, bez odkazů ven.

## Licence

Private — all rights reserved.
