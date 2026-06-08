# BC_Telemetry — kroky jak to postavit

Konec-do-konce postup zprovoznění: BC Cloud → Azure Application Insights → SQL (BSWNAV01) → admin dashboard.
Verze 1.1 (zapracována oponentura 2026-06-08).

```
BC Cloud ──telemetrie──▶ Azure App Insights / Log Analytics
                              │  DCR filtr (clientType == "Web")
                              ▼
        PowerShell (denně 02:00, Service Principal) ──▶ SQL: dbo.BCPageLog (raw)
                              │  usp_BCPageLog_Rollup
                              ▼
                  dbo.BCPageDaily + vw_Dash* (agregáty, kumulují navždy)
                              │  Export-DashboardSnapshot.ps1
                              ▼
                  web\data.json ──▶ index.html (IIS, interní, admin)
```

---

## Fáze 0 — Předpoklady

| Co | Kde | Pozn. |
|----|-----|-------|
| BC Admin práva | `…/admin` na tenantu `2ecd5815-…` | nastavení telemetrie |
| Azure subscription + práva tvořit resources | Azure Portal | Resource Group, App Insights |
| SQL Server `BSWNAV01` | on-prem | databáze `BC_Telemetry` |
| Server pro Task Scheduler + IIS | doménový | běh importu + hosting dashboardu |
| PowerShell moduly | server | `Install-Module Az.Accounts, Az.OperationalInsights, CredentialManager -Scope AllUsers` |

---

## Fáze 1 — Azure Application Insights

1. **Resource Group** — Azure Portal → Resource Groups → `rg-bc-telemetry`, region **West Europe**.
2. **Application Insights** — + Vytvořit → Application Insights → `appinsights-bc-production`, Resource Mode **Workspace-based**.
3. **Connection String** — App Insights → Overview → zkopírovat (`InstrumentationKey=…;IngestionEndpoint=…`).
4. **Retence + Daily Cap** — Log Analytics Workspace → Usage and estimated costs → retence **30 dní**, Daily Cap **0,5 GB/den**.
5. **DCR filtr (klíčové pro náklady)** — Workspace → Tables → pro **AppTraces** i **AppPageViews** → Create Transformation:
   ```kql
   source
   | where clientType == "Web"
   ```
   > Oponentura #1: jednotný whitelist `== "Web"` pro **obě** tabulky (ne blacklist u AppTraces).

## Fáze 2 — Service Principal (neinteraktivní auth)

> Oponentura #3/#5: scheduled task se nesmí spoléhat na interaktivní `Connect-AzAccount`.

```powershell
# 1) Vytvořit App registration / SP
az ad sp create-for-rbac --name "sp-bc-telemetry" --skip-assignment
#   → vrátí appId (ClientId), password (secret), tenant

# 2) Přiřadit roli Log Analytics Reader na workspace
az role assignment create --assignee <appId> `
  --role "Log Analytics Reader" `
  --scope "/subscriptions/<sub>/resourceGroups/rg-bc-telemetry/providers/Microsoft.OperationalInsights/workspaces/<workspace>"

# 3) Uložit secret na server do Credential Manageru (ne do skriptu)
Install-Module CredentialManager -Scope AllUsers
New-StoredCredential -Target "BC_Telemetry_SP" -UserName "<appId>" -Password "<secret>" -Persist LocalMachine
```

## Fáze 3 — BC Admin Center

1. Otevřít `https://businesscentral.dynamics.com/2ecd5815-0eb9-4e9a-93be-ac58545cdca6/admin`.
2. Environments → **Production** → Telemetry → Define → Enable **ON** → vložit Connection String → Save.
3. **Restart prostředí mimo pracovní dobu** (nastavení Connection String to vyžaduje).
4. Ověření: data v App Insights do ~5 minut (`pageViews | take 10`).

## Fáze 4 — SQL (BSWNAV01)

```sql
-- 1) databáze
CREATE DATABASE BC_Telemetry;
-- 2) schéma + indexy + dedup + retence + analytický view
:r sql\01_schema.sql
-- 3) agregační vrstva (rollup tabulky, proc, dashboard views)
:r sql\02_aggregates.sql
-- 4) práva servisního účtu
CREATE USER [AXIMA\svc_bc_telemetry] FOR LOGIN [AXIMA\svc_bc_telemetry];
ALTER ROLE db_datareader ADD MEMBER [AXIMA\svc_bc_telemetry];
ALTER ROLE db_datawriter ADD MEMBER [AXIMA\svc_bc_telemetry];
GRANT EXECUTE ON dbo.usp_BCPageLog_Rollup TO [AXIMA\svc_bc_telemetry];
GRANT EXECUTE ON dbo.usp_BCPageLog_Purge  TO [AXIMA\svc_bc_telemetry];
```

## Fáze 5 — Import + rollup (PowerShell)

1. Nakopírovat `scripts\BC_PageLog_Import.ps1` → `C:\Scripts\`.
2. Vyplnit `-WorkspaceId`, `-ClientId` (a tenant, je-li jiný) — secret se čte z `BC_Telemetry_SP`.
3. Test ručně:
   ```powershell
   C:\Scripts\BC_PageLog_Import.ps1 -WorkspaceId <guid> -ClientId <appId>
   ```
   Skript: SP auth → watermark → KQL jen nové záznamy → SqlBulkCopy do staging → MERGE (dedup) → rollup → retence. Atomicky (try/catch + transakce).

## Fáze 6 — Scheduler

> Oponentura #8: doménový účet vyžaduje **LogonType Password**, ne ServiceAccount.

```powershell
# spustit jako admin na serveru
scripts\Register-ScheduledTask.ps1 -RunAs "AXIMA\svc_bc_telemetry"
#   → vyžádá heslo, registruje denní úlohu 02:00
```
Doplnit právo **Log on as batch job** pro `AXIMA\svc_bc_telemetry` (gpedit → Local Policies → User Rights Assignment).

## Fáze 7 — Dashboard (IIS, interní, admin)

1. **IIS site** — nová site `bc-telemetry`, physical path `C:\inetpub\bc-telemetry`, jen interní síť.
2. **Auth** — vypnout Anonymous, zapnout **Windows Authentication**; omezit na AD skupinu adminů (je to admin nástroj).
3. Nakopírovat `web\index.html` → `C:\inetpub\bc-telemetry\`.
4. **Snapshot** — naplánovat `Export-DashboardSnapshot.ps1` (druhá akce stejné úlohy nebo navazující task po importu):
   ```powershell
   C:\Scripts\Export-DashboardSnapshot.ps1 -OutPath C:\inetpub\bc-telemetry\data.json
   ```
   Čte jen agregáty `vw_Dash*` → `data.json` zůstává malý i při milionech raw řádků.
5. Otevřít `http://<server>/` interně → KPI + 4 záložky (Aktivita, Kandidáti, Migrace, Trend).

## Fáze 8 — Workflow permission setů

1. Uživatel pracuje pod plným přístupem → sledovací období ~3 měsíce (data se kumulují v `BCPageDaily`).
2. Dashboard → **Kandidáti na vyřazení** (≤2 otevření) + **Aktivita** → návrh rolí (Fakturace/Sklad/Reporting).
3. Nasadit Permission Sety, odebrat plný přístup.
4. Sledovat **Migrace SUPER→role** (RT0031) první 2 týdny → doplnit chybějící práva.
   > RT0031 jsou v AppTraces → vyžaduje fázi-2 ingest do `dbo.BCAuthFailDaily` (sekce dashboardu funguje, jakmile data dorazí).

---

## Verifikace

- [ ] `pageViews | take 10` v App Insights vrací jen `clientType == "Web"`
- [ ] `SELECT COUNT(*) FROM dbo.BCPageLog` roste po denním běhu
- [ ] `SELECT * FROM dbo.vw_DashKPI` vrací nenulové hodnoty
- [ ] `data.json` se přepisuje s aktuálním `generatedUtc`
- [ ] dashboard se načte interně a tabulky se filtrují/řadí
- [ ] druhý běh importu nevloží duplicity (dedup MERGE)

## Bezpečnost / GDPR

- `customDimensions` může nést čísla dokladů / jména — snapshot ber jako interní, neexponovat ven (Windows auth, interní síť).
- Connection String v BC Admin Center je viditelný BC adminům — drž okruh adminů úzký.
- Pro testovací prostředí telemetrii vypnout nebo snížit Daily Cap.
