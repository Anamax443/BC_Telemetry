# BC_Telemetry — HANDOFF (rolling)

Aktuální stav projektu pro pokračování v další session. Updatuje se průběžně.
Poslední update: **2026-06-08** · repo `Anamax443/BC_Telemetry`.

> Doplňující docs: [modules.md](modules.md) (3 moduly) · [dokumentace.md](dokumentace.md) (technicky) ·
> [BUILD.md](../BUILD.md) (postup) · [deploy-10.8.2.225.md](deploy-10.8.2.225.md) (dashboard hosting) ·
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

## Ověřená realita (POZOR — docs v1.0 i oponentura byly mylné)
- Import sahá na **Log Analytics** → tabulka **`AppPageViews`** (NE classic `pageViews`), BC dims v **`Properties.*`**.
- Uživatel telemetrie = **`UserId`** = **pseudonymní GUID** (NE AAD object id — Entra 404). Jméno jen korelací s Entra sign-in logy.
- Interaktivní klienti = **`Desktop`/`WebClient`** (hodnota „Web" NEexistuje → starý filtr by nematchnul nic).
- Change Log naopak má **reálné jméno** (MTRNKA) → modul B jména řeší nativně.
- DCR filtr **odložen** (free tier $0; filtruje import).
- BC SaaS NEMÁ Windows eventlog → „kdo co smazal" jen přes Change Log.

## Hotovo
- Repo, 3 moduly (SQL + skripty + dashboard záložky A/B/C), dokumentace, oponentura+reakce, status HTML (dark mode + Push #).
- Azure onboarding LIVE, BC telemetrie ON, Change Log ON + web service, Service Principal založen.
- Import KQL ověřen na reálných datech a opraven (AppPageViews/UserId/Desktop).

## Další kroky (pořadí)
1. ~~Workspace ID~~ ✅ `484e3038-…` doplněn do skriptů.
2. ~~Azure: SP → Log Analytics Reader na workspace~~ ✅ (moduly A/C mají auth).
3. **BC Admin Center → Microsoft Entra Apps** → registrovat client ID `4eda9e64-…` + permission set (čtení Change Log) + Enabled (modul B). ← **PŘÍŠTÍ KROK**
4. **Ověřit OData pole** přes SP (`ChangelogEntry?$top=3`, `$metadata`) → doladit mapování v BC_ChangeLog_Import.ps1 (pozn.: primární klíč rozdělen do 3 polí).
5. **SQL na 10.8.2.225** — vytvořit DB + spustit `sql/01..04` + práva pro SP/servisní účet.
6. **Spustit importy** + scheduler; **dashboard** přes Node službu (install-service.cmd).

## Otevřená rozhodnutí (operator)
- Whitelist rozsah dashboardu: `/24` vs `/16`.
- BC_Telemetry DB: na 10.8.2.225 (localhost) vs BSWNAV01.
- GPO AllSigned: podpis PS skriptů vs jiný box vs GPO výjimka.

## Plánované featury
- ⏰ **Monitor expirace SP secretu/certifikátu** v dashboardu (KPI/alert; current 2028-06-07) — operator request.
- Modul B durable: vlastní AL API page místo deprecated UI-page web service.
- Modul A jména: korelace GUID ↔ Entra sign-in logy → `dbo.BCUserMap`.
- 📖 **Anonymizovaný public step-by-step návod** (na maxferit web, jako showcase/lead-gen) —
  samostatný deliverable, **bez identifikace firmy**: nahradit AXIMA / company names / tenant+subscription
  GUIDy / SP client ID / iKey / reálná jména (MTRNKA) / interní IP (10.8.2.225, BSWNAV01) za placeholdery
  (`<tenant-id>`, `<company>`, `<server>`…). Interní docs proto píšeme sanitizovatelně (firemní hodnoty
  v oddělených tabulkách „klíčové ID" + parametrech skriptů). Repo se celé nepublikuje.
