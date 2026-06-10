# Telemetrie, audit a permission-set mining nad Microsoft Dynamics 365 Business Central Cloud

*Referenční návod — jak postavit nákladově nulový telemetrický a auditní systém nad BC SaaS.*

> **O tomto dokumentu.** Jde o sanitizovaný technický návod publikovaný jako ukázka postupu.
> Konkrétní identifikátory prostředí (tenant, subscription, IP adresy, jména serverů, servisní účty,
> credentials) jsou nahrazeny placeholdery `<…>` — doplň je podle svého prostředí. Žádné citlivé
> hodnoty zde nejsou. *(Autor: doplň svůj profesní podpis / značku.)*

## Preambule — záměr a kontext

Microsoft Dynamics 365 Business Central Cloud je výkonné ERP, ale jako SaaS nedává adminovi přímou
odpověď na tři provozně klíčové otázky:

1. **Co uživatelé reálně používají?** — bez toho nelze rozumně nastavit *permission sety* (oprávnění).
   Typicky všichni jedou pod (skoro) plným přístupem „aby to fungovalo", což je bezpečnostní dluh.
2. **Kdo co vytvořil, změnil nebo smazal?** — audit s reálným jménem uživatele (compliance, dohledání).
3. **Komu po zúžení práv něco chybí?** — abys migraci z plného přístupu na role zvládl bez výpadku práce.

Tento návod ukazuje, jak na to **bez licenčních nákladů**: telemetrie BC → **Azure Application Insights**
(free tier 5 GB/měs), odtud neinteraktivně do **SQL** (raw → inkrementální agregáty) a lehký **dashboard**.
Vše zůstává ve vlastní síti, provoz je v podstatě zdarma.

```
BC Cloud ──telemetrie──▶ Azure Application Insights / Log Analytics
                              │   (Service Principal, neinteraktivně)
        ┌─────────────────────┼─────────────────────┐
   modul A (AppPageViews)  modul C (AppTraces)   modul B (BC Change Log → OData)
   využití stránek         permission errors     kdo/co/kdy (reálné jméno)
        └─────────────────────┼─────────────────────┘
                              ▼
                 SQL (raw → inkrementální rollup → agregáty)
                              ▼
                 data.json ──▶ webový dashboard (+ IP whitelist)
```

**Tři moduly:**
- **A — využití stránek** → podklad pro *permission set mining* (seškrtání oprávnění na reálně používané).
- **B — audit změn** → kdo vytvořil/změnil/**smazal** záznam, s reálným jménem.
- **C — permission errors (RT0031)** → komu po zúžení práv chybí oprávnění.

## Klíčové hodnoty — doplň podle svého prostředí

| Placeholder | Co to je |
|---|---|
| `<company>` | tvoje organizace |
| `<DOMAIN>` / `<domain-fqdn>` | NetBIOS doména / FQDN AD domény |
| `<tenant-id>` | Entra (Azure AD) Directory ID |
| `<subscription-id>` | Azure subscription |
| `<resource-group>` / `<region>` | RG a region (např. West Europe) |
| `<appinsights-name>` / `<workspace-id>` | App Insights (workspace-based) + Log Analytics Workspace ID |
| `<sp-name>` / `<client-id>` | Service Principal (App registration) + jeho Application (client) ID |
| `<bc-environment>` | BC prostředí (např. Production) |
| `<changelog-webservice>` | název publikovaného Change Log web service |
| `<sql-server>` / `<db-name>` | SQL server/instance + databáze |
| `<svc-account>` | doménový servisní účet pro běh importů |
| `<dashboard-port>` / `<admin-ips>` | port dashboardu + povolené admin IP |

> Secret Service Principalu se nikam nezapisuje — ukládá se jen do Credential Manageru (Fáze 8).

---

# Fáze 1 — Azure: subscription + Application Insights (moduly A/C)

1. Azure Portal → **Předplatná** → Pay-as-you-go (App Insights běží ve free tieru = $0).
2. **Resource Group** `<resource-group>`, region `<region>`.
3. **Application Insights** `<appinsights-name>`, **Resource Mode: Workspace-based**.
4. Workspace → *Usage and estimated costs* → **Data Retention 31 dní** + **Daily cap 0,5 GB/den** (pojistka nákladů).
5. Workspace → Overview → zkopíruj **Workspace ID** → `<workspace-id>`.
6. App Insights → Overview → zkopíruj **Connection String** (pro Fázi 2).

# Fáze 2 — BC: zapnout telemetrii

1. BC **Admin Center** (`…/<tenant-id>/admin`) → Environments → `<bc-environment>` → Telemetry → **Define** →
   vlož Connection String → Save. (V aktuální verzi **bez restartu** prostředí.)
2. Data tečou do ~5 min při reálné aktivitě uživatelů.

# Fáze 3 — Service Principal (App registration)

1. Entra → **App registrations → New registration** → `<sp-name>`, Single tenant → Register.
2. Zkopíruj **Application (client) ID** → `<client-id>`. *(Pozor: NE „Object ID" — to je jiný identifikátor.)*
3. **Certificates & secrets → New client secret** → **zkopíruj `Value`** (ukáže se jen jednou).
   ⚠ **Častá past:** secret je **`Value`** (cca 40 znaků). **`Secret ID` (36-znakový GUID) NENÍ secret** —
   když ho omylem použiješ, token request vrací **401**. Poznamenej si datum expirace a hlídej ho.

# Fáze 4 — SP → Application Insights (moduly A/C)

Log Analytics workspace → **Access control (IAM) → Add role assignment → Log Analytics Reader** →
member `<sp-name>`.

# Fáze 5 — SP → BC API (modul B, server-to-server) — tři pasti, projdi všechny

### 5a. Redirect URI (jinak „Udělit souhlas" v BC spadne na AADSTS500113)
App registration → **Authentication → Add a platform → Web** → Redirect URI
`https://businesscentral.dynamics.com/OAuthLanding.htm` (Implicit grant NEzaškrtávat).

### 5b. API permission + admin consent (jinak token má prázdné `roles` → 401)
App registration → **API permissions → Add → APIs my organization uses → Dynamics 365 Business Central →
Application permissions → `API.ReadWrite.All`** → **Grant admin consent** (musí svítit *Granted*).

### 5c. App user v BC + permission sety
BC web klient → **Microsoft Entra Applications** (Page 9861) → New → Client ID = `<client-id>` →
přidej permission set `D365 BUS PREMIUM` (nebo vlastní read sadu; **SUPER/SUPER(DATA) nelze**) →
Společnost prázdné (= všechny firmy) → Stav **Povolený** → **Udělit souhlas**.

# Fáze 6 — BC: Change Log + web service (modul B)

1. **Change Log Setup → Change Log Activated = ON**.
2. **Tables** → pro citlivé tabulky zapni Log Insertion/Modification/Deletion (Access Control, User, doklady,
   položky…). *Neloguje zpětně — zapni dřív, než budeš chtít data.*
3. **Web Services → New** → Type Page, Object ID **405**, Service Name `<changelog-webservice>`, **Published**.
   *(Pozn.: publikování UI stránek jako web service Microsoft postupně ruší — durable varianta je vlastní AL API page.)*

# Fáze 7 — SQL: databáze + schéma + práva

Doporučení: DB **co-located** se serverem importu/dashboardu (žádný síťový hop).

Spuštění schématu (tabulky, indexy, inkrementální rollup procedury, dashboard views, retence) +
**login/práva pro `<svc-account>`** (`db_datareader` + `db_datawriter` + `EXECUTE` na ETL procedury).
Skripty pouštěj pod účtem se **sysadmin** právy (zakládá login). Pokud běžný účet nemá DDL práva,
spusť konsolidovaný skript v SSMS jako sysadmin.

> **Tip (GPO AllSigned):** nasazení SQL veď přes nativní **`sqlcmd.exe`** — není to skript, takže
> **nepodléhá** případné politice AllSigned (na rozdíl od `.ps1`).

**Ověření:** počet tabulek / views / procedur odpovídá schématu; servisní účet má role `db_datareader`+`db_datawriter`.

# Fáze 8 — Servisní účet + práva + secret (tři podpasti)

### 8a. Doménový servisní účet (regular; gMSA není nutné)
Na DC založ `<svc-account>` — ideálně **naklonuj OU a flagy z existujícího servisního účtu**
(PasswordNeverExpires + CannotChangePassword + Enabled).
> ⚠ Když skript pro založení účtu **vkládáš do konzole** (ne spouštíš jako soubor), použij variantu
> bez `param()`/`[CmdletBinding()]` — jinak parser hlásí *„Unexpected attribute"*.

### 8b. SQL práva
Login + database user pro `<svc-account>` + `db_datareader` + `db_datawriter` + `EXECUTE` na ETL procedury.
*(Importy se připojují přes Integrated Security → SQL práva potřebuje WINDOWS účet, ne Service Principal.)*

### 8c. User Rights na serveru importu
`secpol.msc → Local Policies → User Rights Assignment` → přidej `<svc-account>` do
**Log on as a service** + **Log on as a batch job**.

### 8d. Secret do Credential Manageru — **per-user past**
Credential Manager je **per-profil** — secret musí ležet ve vaultu `<svc-account>`, ne ve tvém. Ulož dva
generic credentials se **stejnou Value** (jeden pro Azure login, druhý pro BC API). Když nemáš nástroj pro
spuštění pod identitou účtu interaktivně, použij **jednorázový scheduled task běžící jako `<svc-account>`**,
který `New-StoredCredential` zapíše do svého profilu (a pak task smaž).

# Fáze 9 — Importy + scheduler

Tři importní skripty (modul A využití stránek, B audit změn, C permission errors) — inkrementální (watermark),
idempotentní (dedup/MERGE), atomické (transakce), s rollupem do agregátů a retencí. Moduly nad App Insights
potřebují `Az.Accounts` + `Az.OperationalInsights` (Install-Module -Scope AllUsers).
Naplánuj denně (např. 02:00) jako `<svc-account>` (LogonType Password).

> **Execution policy / AllSigned:** zkontroluj `Get-ExecutionPolicy -List`.
> - `RemoteSigned` (běžné na členských serverech): **lokální `.ps1` běží bez podpisu** — po přenosu z internetu
>   spusť `Unblock-File` (jinak je zóna „downloaded" zablokuje).
> - `AllSigned` (zpřísnější GPO): skripty musíš **podepsat** interním code-signing certem
>   (`Set-AuthenticodeSignature`, cert do Trusted Publishers), nebo je pustit z jiného boxu / udělat GPO výjimku.
>   `-ExecutionPolicy Bypass` AllSigned **neobejde** (MachinePolicy má přednost).

# Fáze 10 — Dashboard (lehká služba + IP whitelist)

Dashboard hostuj jako **malou Node službu** (přes NSSM), aby šel whitelist editovat přímo ze stránky.
- **Bez loginu**; přístup omezuje **IP whitelist = jedna Windows Firewall rule** (`remoteip`).
- Whitelist umí **single IP, CIDR masku (`x.x.x.x/n`) i rozsah (`x.x.x.x-y.y.y.y`)**.
- Snapshot exportér čte jen **agregáty** → `data.json` zůstává malý i nad miliony raw řádků.

> **Honest poznámka k bezpečnosti:** IP whitelist přes firewall *allow* rule je *visibility gate*, ne tvrdá
> hranice — platí jen když je Domain firewall profil Enabled. Pro tvrdé vynucení profil zapni. Buď k tomuhle
> ve své dokumentaci upřímný; je to známka, že chápeš rozdíl mezi „omezením zobrazení" a „bezpečnostní hranicí".

# Verifikace (end-to-end smoke test)

Pod identitou `<svc-account>` ověř všechny pilíře najednou:
- čtení obou credentials z vaultu (a že délka secretu odpovídá `Value`, ne 36-znakovému `Secret ID`),
- připojení k SQL jako servisní účet,
- **modul A:** Azure login + dotaz `AppPageViews | summarize count()` vrátí počet > 0,
- **modul B:** BC API token má `roles = API.ReadWrite.All` a OData vrátí seznam firem.

# Workflow permission setů (vlastní byznys přínos)

1. Sledovací období ~3 měsíce pod plným přístupem (data se kumulují v denních agregátech).
2. Z dashboardu: **kandidáti na vyřazení** (málo používané stránky) + **aktivita per uživatel** → návrh rolí.
3. Nasadit permission sety, odebrat plný přístup.
4. Sledovat **modul C (RT0031)** první 2 týdny → doplnit chybějící oprávnění bez výpadku práce.

# Ověřená realita / lessons (na čem se to nejčastěji zadrhne)

Tyhle detaily nejsou v „dokumentaci na první pohled", ale rozhodují o tom, jestli systém vůbec uvidí data:

- Data jsou v **`AppPageViews`** (Log Analytics), **ne** v classic `pageViews`; BC dimenze jsou v `Properties.*`.
- Identita v telemetrii = **`UserId` = pseudonymní GUID** (ne AAD object id) → reálné jméno jen korelací s Entra
  sign-in logy. Audit (modul B) má naopak reálné jméno přímo z Change Logu.
- Interaktivní klienti = **`Desktop` / `WebClient`** (hodnota „Web" neexistuje → starý filtr by nematchnul nic).
- Audit `Entry No.` je **per-firma** sekvence → watermark a deduplikaci dělej **per firma**.
- Čtyři klasické bumy: **Credential Manager je per-user**, **secret = `Value`, ne `Secret ID`**,
  **AllSigned neobejdeš `-Bypass`em**, a **`sqlcmd.exe` AllSigned nepodléhá** (využij to pro SQL deploy).

---

*Tento návod popisuje ověřený postup. Implementaci, code review nebo nasazení na míru rád zajistím —
[doplň kontakt / odkaz na profesní stránky].*
