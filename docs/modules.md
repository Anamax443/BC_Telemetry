# BC_Telemetry — 3 moduly

Projekt sbírá tři různé pohledy na BC, každý z **jiného zdroje** a s jinou identitou uživatele.

| Modul | Otázka | Zdroj | Identita | Stav |
|---|---|---|---|---|
| **A · Využití stránek** | Co kdo otevírá → Permission Set mining | App Insights `AppPageViews` | pseudonymní GUID (`UserId`) | **LIVE** |
| **B · Audit změn** | Kdo vytvořil / změnil / **smazal** záznam | **BC Change Log** přes API/OData | **reálný uživatel** (UPN) | **LIVE** |
| **C · Permission errors** | Kdo narazil na chybějící oprávnění (RT0031) | App Insights `AppTraces` | pseudonymní GUID | ingest LIVE (čeká na data) |

```
                 ┌─ App Insights ─ AppPageViews ──▶ [A] dbo.BCPageLog → BCPageDaily
BC Cloud ────────┤                 AppTraces(RT0031) ▶ [C] dbo.BCAuthFailDaily
(Production)     │
                 └─ BC API/OData ─ ChangeLogEntries ─▶ [B] dbo.BCChangeLog
                                                        ▼
                              SQL (10.8.2.225) → snapshot → dashboard (záložky A/B/C)
```

---

## Modul A — Využití stránek (LIVE)
App Insights telemetrie, ověřená pipeline. Viz [dokumentace.md](dokumentace.md). Identita = pseudonymní GUID.

> 🔧 **Oprava dedup (2026-06-16):** duplicity **uvnitř** jedné stažené dávky shazovaly celou transakci
> (rollback) → zamrzlý watermark a žádný postup importu. Fix: ve staging se před MERGE deduplikuje přes
> `ROW_NUMBER() OVER (PARTITION BY Timestamp, UserId, ISNULL(PageId,'')) = 1`.

> **Mapování GUID → jméno (vyřešeno 2026-06-10):** telemetrický `UserId` = BC pole **„Telemetry User ID"**
> (sloupec „ID telemetrie" na Page 9800 Users) — NE AAD object id, NE User Security ID. Jméno se získá
> přímo z **BC Users OData** (publikovaný web service), ne korelací s Entra sign-in logy.
> `scripts/BC_Users_Import.ps1` (stejný SP jako modul B) → SQL **`dbo.BCUser`** (`sql/03_users.sql`)
> → `dbo.vw_UserMap` → `web/usermap.json` (GUID → Full Name). Běží v denním wrapperu po modulu B;
> dashboard záložka 👤 Uživatelé to zobrazí v Aktivitě / Kandidátech / RT0031.

## Modul B — Audit změn (BC Change Log) (LIVE)

**Reálný uživatel** — Change Log loguje INSERT/MODIFY/DELETE s BC User ID (mapovatelný na osobu).

### Operátorské kroky (jednorázově v BC)
1. **Zapnout Change Log:** v BC vyhledej *„Change Log Setup"* → zaškrtni **Change Log Activated**.
2. **Vybrat tabulky:** *„Tables"* → pro citlivé tabulky zaškrtni **Log Insertion / Modification / Deletion**
   (selektivně — ne všechno; každá sledovaná změna = zápis navíc). Doporučeno: doklady, položky,
   nastavení, uživatelé/oprávnění.
3. **Publikovat jako web service:** vyhledej *„Web Services"* → New → Object Type **Page**,
   Object ID **405** (Change Log Entries), Service Name např. `ChangeLogEntries`, **Published = ON**.
   → vznikne OData URL `…/ODataV4/Company('AXIMA_CZ_ESHOP')/ChangeLogEntries`.
4. **Přístup pro Service Principal k BC API:** BC Admin Center → **Microsoft Entra Apps** → New →
   Client ID = náš SP `03c2f43a…`? (pozn.: BC API SP = App registration, ne AI ApplicationId) →
   přiřadit permission set (např. `D365 BASIC` + read na Change Log) → **State = Enabled**.

### Ingest (přepsáno 2026-06-16 — newest-first + backfill + bulk insert)
[scripts/BC_ChangeLog_Import.ps1](../scripts/BC_ChangeLog_Import.ps1) — OAuth2 client-credentials
(scope `https://api.businesscentral.dynamics.com/.default`) → **projde sledované firmy** (auto-list
přes `/ODataV4/Company`, filtr dle `enabled`) → `…/Company('X')/ChangelogEntry` → `dbo.BCChangeLog`.

Import jede ve **třech fázích** (per firma), protože BC OData vrací max ~50000 řádků/dotaz a sekvence
`Entry_No` je u velkých firem v řádu stovek milionů → ascending backfill od nuly je nereálný:

| Fáze | Spouští se když | Dotaz | Strop / běh |
|---|---|---|---|
| **0 — seed** | firma v DB ještě prázdná | nejnovější blok `orderby Entry_No desc` | 1 blok |
| **A — dosync k současnosti** | máme data | `Entry_No gt MAX(EntryNo)` **asc** | `ForwardRowsPerRun` = **150 000** |
| **B — backfill historie** | máme data | `Entry_No lt MIN(EntryNo)` **desc** | `BackfillRowsPerRun` = **50 000** |

> **Bulk insert:** místo row-by-row se řádky nahrají přes `SqlBulkCopy` do `#Staging`, pak jedním
> `INSERT … WHERE NOT EXISTS` s `ROW_NUMBER() OVER (PARTITION BY CompanyName, EntryNo)` (dedup uvnitř
> dávky) + `LEFT()` ořezem délek řetězců. Dedup unikát na disku = index **`UX_BCChangeLog_Company_EntryNo`**.

> **Per-firma:** Change Log je company-bound, `Entry_No` je samostatná sekvence v každé firmě →
> watermark `MAX/MIN(EntryNo) WHERE CompanyName=…` a dedup unikát na **(CompanyName, EntryNo)**.

> ⏱ **Dlouhý běh:** BC OAuth token se v běhu **obnovuje po 45 min**, jinak dlouhý backfill spadne na 401.

> **Auth:** browser na OData endpoint ukáže Basic-auth dialog (BC online ho přes prohlížeč neudělá) →
> ověření a běh **jen přes Service Principal** (client-credentials). Browser test = Zrušit.

> ✅ Názvy OData polí ověřeny proti `$metadata` přes SP (2026-06-08): `Entry_No` / `Date_and_Time` /
> `User_ID` (reálné jméno) / `Table_No` / `Field_No` / `Type_of_Change` / `Old_Value` / `New_Value` /
> `Primary_Key`. Import opraven na tato pole; produkční běh LIVE 2026-06-10 (BCChangeLog=42665, 12 firem).

> **Výběr firem (záložka „⚙ Nastavení auditu"):** přesunuto do vlastní záložky — `changelog-companies.json`
> (`{all,enabled}`), u každé firmy se zobrazí **počet záznamů**, tlačítko **„↻ Aktualizovat seznam firem"**.
> Odškrtnutím firmy se její Change Log přestane stahovat. `BC_ChangeLog_Import` zapíše `all` a importuje
> jen `enabled` (jinak vše). Firmy **ESHOP / ESHOP02 / TEST1 / TEST2** vyřazeny + jejich audit smazán (~340 000 řádků).

### Mazání audit záznamů (purge)
Danger-zone v dashboardu → `POST /changelog-purge` → web zapíše požadavek do `ops/ops-request.json` →
**denní úloha (svc)** se příští běh spustí v **purge-only režimu**:
`DELETE FROM dbo.BCChangeLog WHERE CompanyName IN (…)` + snapshot, import se přeskočí. Vykonává
[scripts/BC_ChangeLog_Purge.ps1](../scripts/BC_ChangeLog_Purge.ps1); stav purge je vidět přes `GET /ops-status`.
(Web sám na SQL nesahá — jen vloží požadavek do ops fronty, viz architektonický princip.)

## Modul C — Permission errors (RT0031)

RT0031 = *Authorization Failed* v `AppTraces`. **Vzniká až po odebrání plného přístupu** a nasazení
omezených rolí — teď (pod plným přístupem) žádné nejsou. Ingest reuse App Insights infra (stejný SP / Log Analytics).

[scripts/BC_AuthFail_Import.ps1](../scripts/BC_AuthFail_Import.ps1) — `AppTraces | where Properties.eventId == 'RT0031'`
→ `dbo.BCAuthFailDaily`. Identita = pseudonymní GUID (jako modul A).

> ⚠ Pole RT0031 v `AppTraces` (eventId, alObjectId, UserId) ověřit, až nějaké RT0031 vzniknou.

---

## Společné
- **Auth:** moduly A/C přes Service Principal + Log Analytics Reader (workspace). Modul B přes SP + BC API access (Entra Apps v BC Admin Center) — jiné oprávnění, stejná App registration.
- **Volání BC API jde výhradně přes [`scripts/BCApi.psm1`](../scripts/BCApi.psm1)** (modul B, Users, sync-status): obnova tokenu, brzda na počet požadavků/min, opakování při 429 (`Retry-After`) a 5xx, `Data-Access-Intent: ReadOnly`, `$select`, degradace místo pádu, souhrn v logu. Důvod: prostředí BC je sdílené s dalšími aplikacemi a limit **6000 požadavků / 5 min** platí na identitu. Pravidla pro nové integrace → [bc-api-integrace-standard.md](bc-api-integrace-standard.md).
- **Hosting/dashboard:** vše do SQL na 10.8.2.225, snapshot → dashboard se záložkami A/B/C.
- **Retence:** raw moduly mažeme (A 6 měs.), agregáty/audit držíme dle potřeby (audit může mít delší retenci kvůli compliance).
