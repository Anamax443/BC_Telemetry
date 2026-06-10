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
| **SP → BC API (S2S)** | ✅ funguje: Redirect URI `OAuthLanding.htm` + **API.ReadWrite.All** (Application) + admin consent + BC app user (`8de43095-…`, sady D365 BUS PREMIUM) Enabled. OData čte **všech 12 firem**. Detail [SETUP-STEP-BY-STEP.md](SETUP-STEP-BY-STEP.md). |

## Ověřená realita (POZOR — docs v1.0 i oponentura byly mylné)
- Import sahá na **Log Analytics** → tabulka **`AppPageViews`** (NE classic `pageViews`), BC dims v **`Properties.*`**.
- Uživatel telemetrie = **`UserId`** = **pseudonymní GUID** (NE AAD object id — Entra 404). Jméno jen korelací s Entra sign-in logy.
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
6. ~~Založit servisní účet~~ ✅ `AXINETWORK\svc-bc-telemetry` založen na DC (`New-ServiceAccount.ps1`, klon OU+flagů z svc-itdashboard).
   **Zbývá secret** do Credential Manageru **v profilu toho účtu** (cíl `BC_Telemetry_SP` i `BC_Telemetry_BCAPI`,
   stejná hodnota) — Cred Manager je per-user → přes `PsExec -u AXINETWORK\svc-bc-telemetry`. ← **PŘÍŠTÍ KROK**
7. **User Rights** na 10.8.2.225 pro účet: `Log on as a service` + `Log on as a batch job` (secpol/GPO).
8. **Spustit importy** (3 moduly) + scheduler (`Register-ScheduledTask.ps1`); **dashboard** přes Node službu (install-service.cmd).
9. Volitelně: zúžit BC permission set z D365 BUS PREMIUM na custom read (least-privilege); vlastní AL API page místo deprecated UI-page web service.

## Otevřená rozhodnutí (operator)
- ~~BC_Telemetry DB: 10.8.2.225 (localhost) vs BSWNAV01~~ ✅ **localhost (co-located na 10.8.2.225)** — všechny importy sjednoceny na `localhost`, GRANT míří na lokální Windows účet.
- ~~Whitelist rozsah dashboardu: `/24` vs `/16`~~ ✅ **stejně jako ITDashboard** — konkrétní admin IP (`10.8.2.225` vlastní server, `10.8.2.181` dev PC, `10.8.2.243` IT specialista); whitelist editor umí navíc CIDR masku i pomlčkový rozsah.
- GPO AllSigned: podpis PS skriptů vs jiný box vs GPO výjimka. (SQL deploy už AllSigned obchází přes `sqlcmd.exe`; týká se ještě importních `.ps1` v Task Scheduleru.)
- Servisní účet: navrženo `AXINETWORK\svc-bc-telemetry` (dedikovaný doménový) — operator ho zatím nemá, čeká na založení.

## Plánované featury
- ⏰ **Monitor expirace SP secretu/certifikátu** v dashboardu (KPI/alert; current 2028-06-07) — operator request.
- Modul B durable: vlastní AL API page místo deprecated UI-page web service.
- Modul A jména: korelace GUID ↔ Entra sign-in logy → `dbo.BCUserMap`.
- 📖 **Anonymizovaný public step-by-step návod** (na maxferit web, jako showcase/lead-gen) —
  samostatný deliverable, **bez identifikace firmy**: nahradit AXIMA / company names / tenant+subscription
  GUIDy / SP client ID / iKey / reálná jména (MTRNKA) / interní IP (10.8.2.225, BSWNAV01) za placeholdery
  (`<tenant-id>`, `<company>`, `<server>`…). Interní docs proto píšeme sanitizovatelně (firemní hodnoty
  v oddělených tabulkách „klíčové ID" + parametrech skriptů). Repo se celé nepublikuje.
