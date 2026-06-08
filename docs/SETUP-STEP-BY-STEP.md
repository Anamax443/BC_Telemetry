# BC_Telemetry — Setup krok za krokem (jak to bylo postaveno)

Reálný postup zprovoznění, ověřený 2026-06-08. Slouží jako runbook a základ pro
budoucí anonymizovaný public návod (firemní hodnoty jsou jen v tabulce „Klíčové ID" níže —
pro public verzi je nahraď placeholdery).

> Tři moduly: **A** využití stránek (App Insights), **B** audit změn (BC Change Log/OData),
> **C** permission errors RT0031 (App Insights). Viz [modules.md](modules.md).

## Klíčové ID (interní — pro public verzi → placeholdery)
| Co | Hodnota | Public placeholder |
|---|---|---|
| Tenant (Directory) ID | `2ecd5815-0eb9-4e9a-93be-ac58545cdca6` | `<tenant-id>` |
| Subscription ID | `4313b649-868c-4b13-a5d2-8a0519f99d75` | `<subscription-id>` |
| App Insights iKey / AppId | `06cb351f-…` / `03c2f43a-…` | `<ikey>` / `<app-id>` |
| Log Analytics Workspace ID | `484e3038-d41f-4c92-991c-cb71ecb54590` | `<workspace-id>` |
| Service Principal (client) ID | `4eda9e64-ead7-4aac-9631-ef4703c10135` | `<client-id>` |
| BC environment | `Production` | `<environment>` |
| Company (příklad) | `AXIMA_CZ_ESHOP` | `<company>` |
| Server (SQL + dashboard) | `10.8.2.225` | `<server>` |

---

# Fáze 1 — Azure: subscription + Application Insights (modul A/C)

1. **Azure subscription** — portál → *Předplatná* → **Pay-as-you-go** (App Insights jede ve free tieru 5 GB/měs = $0; karta jen pro ověření identity).
2. **Resource Group** → `rg-bc-telemetry`, region **West Europe**.
3. **Application Insights** → `appinsights-bc-production`, **Resource Mode: Workspace-based** (auto vytvoří Log Analytics workspace `DefaultWorkspace-…-WEU`).
4. **Retence + cap** — workspace → *Usage and estimated costs* → Data Retention **31 dní** (App Insights tabulky stejně 90 dní zdarma) + **Daily cap 0,5 GB/den**.
5. **Connection String** — App Insights → Overview → zkopíruj.

# Fáze 2 — BC: zapnout telemetrii

1. BC **Admin Center** (`…/admin`) → Environments → **Production** → Details → **Telemetry → Define**.
2. Vlož **Connection String** → Save. (V aktuální verzi **bez restartu** prostředí.)
3. Ověření: data tečou do ~5 min při reálné aktivitě uživatelů ve web/desktop klientu.

# Fáze 3 — Service Principal (App registration)

1. **Entra → App registrations → New registration** → `BC_Telemetry_SP`, **Single tenant**, Redirect URI zatím prázdné → Register.
2. Zkopíruj **Application (client) ID** + **Directory (tenant) ID**.
3. **Certificates & secrets → New client secret** (24 měs.) → **zkopíruj Value** (jen jednou!). ⏰ *sleduj expiraci.*

# Fáze 4 — Zmocnit SP pro App Insights (modul A/C)

1. Log Analytics workspace → **Access control (IAM)** → Add role assignment → **Log Analytics Reader** → member `BC_Telemetry_SP` → Review + assign.
2. Workspace → **Overview** → zkopíruj **Workspace ID** (GUID) → do `$WorkspaceId` v importních skriptech.

# Fáze 5 — Zmocnit SP pro BC API (modul B) — S2S

> Tady byly tři pasti, projdi VŠECHNY tři kroky:

### 5a. Redirect URI (jinak „Udělit souhlas" v BC spadne na AADSTS500113)
App registration → **Authentication** → Add a platform → **Web** → Redirect URI:
```
https://businesscentral.dynamics.com/OAuthLanding.htm
```
Implicit grant **nezaškrtávat** → Configure.

### 5b. API permission + admin consent (jinak token má `roles: prázdné` → 401)
App registration → **API permissions** → Add a permission → **APIs my organization uses** →
**Dynamics 365 Business Central** → **Application permissions** → **`API.ReadWrite.All`** → Add.
Pak **Grant admin consent for <tenant>** → Status musí být zelené **Granted**.

### 5c. Registrace app usera v BC + permission sety
BC **web klient** (Production) → vyhledej **„Aplikace Microsoft Entra"** (Page 9861):
1. New → **Client ID** = `<client-id>` → Description.
2. **Sady oprávnění uživatele** → přidej **`D365 BUS PREMIUM`** (a/nebo vlastní read sadu).
   ⚠ **SUPER ani SUPER (DATA) nejdou app userovi přiřadit** — BC je odmítne. Použij D365 sady / custom.
   - **Společnost** nech prázdné = platí pro všechny firmy.
3. **Stav → Povolený** → **Udělit souhlas** (přihlas se jako admin) → naplní se **ID uživatele**.

# Fáze 6 — BC: zapnout Change Log + web service (modul B)

1. BC → **Change Log Setup** → **Change Log Activated** = ON.
2. **Tables** → pro citlivé tabulky **Log Insertion / Modification / Deletion** (selektivně; např. Access Control 2000000053, User 2000000120, doklady, položky). *Neloguje zpětně.*
3. **Web Services** → New → Type **Page**, Object ID **405**, Service Name **`ChangelogEntry`**, **Published**.
   - ⚠ Microsoft postupně ruší publikování UI stránek jako web service → durable varianta = vlastní AL API page (TODO).

# Ověření S2S (test)
Token: `POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`, body
`client_id`, `client_secret`, `grant_type=client_credentials`, `scope=https://api.businesscentral.dynamics.com/.default`.
Token musí mít **`aud = https://api.businesscentral.dynamics.com`** a **`roles = API.ReadWrite.All`**.
OData: `GET …/v2.0/<tenant>/<environment>/ODataV4/Company('<company>')/ChangelogEntry?$top=3`.
(Diagnostický skript byl `C:\temp\bct_odata_test.ps1` — scratch, ne v repu.)

## Reálné schéma — ověřeno na datech

### Modul A — App Insights (Log Analytics, tabulka `AppPageViews`)
- Identita uživatele = **`UserId`** (pseudonymní GUID, NE AAD object id; `UserAuthenticatedId` prázdný).
- BC dimensions v **`Properties.*`** (`alObjectId`, `alObjectName`, `companyName`, `clientType`).
- Interaktivní klienti = **`Desktop` / `WebClient`** (hodnota „Web" NEexistuje).

### Modul B — Change Log OData (Page 405) — pole
`Entry_No`, `Date_and_Time` (ISO, jedno pole), **`User_ID` (reálné jméno, např. LSOKOL)**, `Table_No`,
`Table_Caption`, `Field_No`, `Field_Caption`, `Type_of_Change` (Insertion/Modification/Deletion),
`Old_Value`/`Old_Value_Local`, `New_Value`/`New_Value_Local`, `Primary_Key`, `Primary_Key_Field_{1,2,3}_{No,Caption,Value}`.
- **Per-firma:** `Entry_No` je samostatná sekvence v každé firmě → filtr `Entry_No gt <watermark>`, watermark per company, dedup (CompanyName, Entry_No).
- Filtr nového od watermarku: `?$filter=Entry_No gt <n>&$orderby=Entry_No`.

# Fáze 7 — SQL deploy (DB co-located na 10.8.2.225)

> DB rozhodnutá: **localhost na 10.8.2.225** (B-S-W-SQL-04, co-located s dashboardem). Všechny
> importy mají default `-SqlServer localhost`. Deploy je **GPO-safe** — `sqlcmd.exe` je nativní
> binárka a NEpodléhá AllSigned (na rozdíl od `.ps1`), takže ho lze spustit i na serveru s AllSigned.

1. Nakopíruj složku `sql\` na server (např. `C:\Scripts\sql\`).
2. Spusť jako **administrator**:
   ```bat
   cd C:\Scripts\sql
   deploy.cmd
   REM   = deploy.cmd localhost "AXINETWORK\svc-bc-telemetry"  (defaulty)
   REM   jiny ucet:  deploy.cmd localhost "DOMENA\jiny_ucet"
   ```
   Idempotentně vytvoří DB `BC_Telemetry` a spustí `00_database` → `01_schema` → `02_aggregates` →
   `04_audit` → `05_grants` (login + user + db_datareader/writer + EXECUTE na všechny ETL procy).
   Pozn.: `03` neexistuje (číslovací mezera); modul C je v `04_audit.sql`.
3. **Servisní účet + secret** (Credential Manager je **per-user** → ulož v profilu servisního účtu):
   ```powershell
   # v session/profilu uctu AXINETWORK\svc-bc-telemetry (napr. pres PsExec -u ...):
   New-StoredCredential -Target "BC_Telemetry_SP"    -UserName "<client-id>" -Password "<secret>" -Persist LocalMachine
   New-StoredCredential -Target "BC_Telemetry_BCAPI" -UserName "<client-id>" -Password "<secret>" -Persist LocalMachine
   ```
   (Stejná secret hodnota pro oba targety — `BC_Telemetry_SP` = Azure auth moduly A/C, `BC_Telemetry_BCAPI` = BC API modul B.)
4. **Spustit importy** + scheduler:
   [BC_PageLog_Import](../scripts/BC_PageLog_Import.ps1), [BC_ChangeLog_Import](../scripts/BC_ChangeLog_Import.ps1),
   [BC_AuthFail_Import](../scripts/BC_AuthFail_Import.ps1) → [Register-ScheduledTask](../scripts/Register-ScheduledTask.ps1).
   (Importní `.ps1` v Task Scheduleru AllSigned ŘEŠÍ samostatně — viz [deploy-10.8.2.225.md](deploy-10.8.2.225.md) §2.)
5. **Dashboard** — Node služba (`scripts/install-service.cmd`).
