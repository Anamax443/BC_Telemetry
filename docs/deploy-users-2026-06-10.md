# Deploy runbook — uživatelé do DB + import desc + totals (Push #37–#38)

Cílový server: **10.8.2.225 (B-S-W-SQL-04)**. Provádí **admintrnka** (krok 2 vyžaduje SQL DDL =
sysadmin; `trnkam` ani `svc-bc-telemetry` DDL práva nemají — jen `db_datareader/writer`).

## Co se nasazuje

| Soubor | Cíl na serveru | Pozn. |
|---|---|---|
| `sql/03_users.sql` | `C:\Apps\BC_Telemetry\sql\` | **NOVÁ** tabulka `dbo.BCUser` + `vw_UserMap` → DDL |
| `sql/deploy.cmd`, `sql/deploy-full.sql` | `C:\Apps\BC_Telemetry\sql\` | aktualizované (zařazen 03_users) |
| `scripts/BC_Users_Import.ps1` | `C:\Apps\BC_Telemetry\scripts\` | **NOVÝ** — OData Users → `dbo.BCUser` → `usermap.json` |
| `scripts/Invoke-BCTelemetryDaily.ps1` | `C:\Apps\BC_Telemetry\scripts\` | + krok „uživatelé" po modulu B |
| `scripts/BC_PageLog_Import.ps1`, `BC_AuthFail_Import.ps1` | `C:\Apps\BC_Telemetry\scripts\` | KQL `order by … desc` |
| `web/server.js` | `C:\Apps\BC_Telemetry_Web\` | **endpoint `/usermap`** — bez něj dashboard nezobrazí jména (404). **Po nasazení RESTART služby!** |
| `web/index.html` | `C:\Apps\BC_Telemetry_Web\` | sync pruh „Celkem SQL / cloud" |
| `web/usermap.json` | `C:\Apps\BC_Telemetry_Web\` | 38 jmen (seed; přepíše ho import z DB na 63) |

> ⚠ **`server.js` = nejčastější opomenutí.** Změna `server.js` vyžaduje **restart služby**
> (`sc.exe stop` → čekat `STOPPED` → `sc.exe start`; NSSM jinak drží starý PID). `index.html`
> a `usermap.json` restart nepotřebují. Bez aktuálního `server.js` vrací `/usermap` **404** a jména se nezobrazí.

> **Kódování:** `.ps1` se srovnanou diakritikou mají UTF-8 BOM (ověřeno). `BC_Users_Import.ps1`
> je čisté ASCII → BOM nepotřebuje. Při kopii přes SMB se obsah nemění, BOM zůstává.

## Krok 1 — zkopírovat soubory (z dev PC, trnkam má Modify na share)

```powershell
$src = 'D:\git\foundations\BC_Telemetry'
$dst = '\\10.8.2.225\BC_Telemetry'          # = C:\Apps\BC_Telemetry
Copy-Item "$src\sql\03_users.sql","$src\sql\deploy.cmd","$src\sql\deploy-full.sql" "$dst\sql\" -Force
Copy-Item "$src\scripts\BC_Users_Import.ps1","$src\scripts\Invoke-BCTelemetryDaily.ps1",`
          "$src\scripts\BC_PageLog_Import.ps1","$src\scripts\BC_AuthFail_Import.ps1" "$dst\scripts\" -Force
```

Web soubory (`C:\Apps\BC_Telemetry_Web`): admin share `c$` často **nejde** („síťový název nelze nalézt") →
odlož je na `\\10.8.2.225\BC_Telemetry\web\` a přesuň je **na serveru** (Krok 3a):

```powershell
New-Item -ItemType Directory -Force "$d\web" | Out-Null
Copy-Item "$src\web\server.js","$src\web\index.html","$src\web\usermap.json" "$d\web\" -Force
```

## Krok 2 — deploy SQL `03_users.sql` (admintrnka, DDL)

**SSMS** (doporučeno): připoj se na `10.8.2.225` jako **admintrnka**, otevři
`C:\Apps\BC_Telemetry\sql\03_users.sql`, **Execute**. Idempotentní — vytvoří jen `dbo.BCUser`
+ `vw_UserMap`, pokud chybí. (Alternativně celý `deploy-full.sql` — taky idempotentní.)

**nebo CLI na serveru** (v session přihlášené jako admintrnka):
```cmd
sqlcmd -S localhost -E -b -d BC_Telemetry -i C:\Apps\BC_Telemetry\sql\03_users.sql
```
> `-E` = trusted connection pod **aktuálním** uživatelem → musí běžet jako **admintrnka**
> (sysadmin), ne `trnkam`. Jinak `CREATE TABLE` selže na právech.

## Krok 3a — web soubory na místo + RESTART služby (na serveru, admintrnka)

```powershell
Copy-Item C:\Apps\BC_Telemetry\web\server.js,C:\Apps\BC_Telemetry\web\index.html,C:\Apps\BC_Telemetry\web\usermap.json C:\Apps\BC_Telemetry_Web\ -Force
# svc musi mit pravo prepsat usermap.json (BC_Users_Import) — jinak WriteAllText padne na "Access denied"
icacls C:\Apps\BC_Telemetry_Web\usermap.json /grant "AXINETWORK\svc-bc-telemetry:(M)"
# server.js se projevi az po restartu (NSSM jinak drzi stary PID); 'sc' v PS je alias Set-Content -> sc.exe!
sc.exe stop BC_Telemetry_Web
do { Start-Sleep 1 } until ((sc.exe query BC_Telemetry_Web | Select-String 'STATE') -match 'STOPPED')
sc.exe start BC_Telemetry_Web
Start-Sleep 2; (Invoke-WebRequest http://localhost:8080/usermap -UseBasicParsing).Content   # ma vratit JSON, ne 404
```

> Bez aktuálního `server.js` + restartu vrací `/usermap` **404** a dashboard ukazuje GUID místo jmen.

## Krok 3 — první běh importu uživatelů (jako svc)

Skript čte SP secret z Credential Manageru **v profilu `svc-bc-telemetry`** → musí běžet v jeho
kontextu. Nejjednodušší: spustit celý denní task (zahrnuje teď i krok uživatelé + snapshot):

```cmd
schtasks /run /tn "BC_Telemetry_Daily"
```

Pak zkontrolovat log běhu (řádek `--- uzivatele … ---` + `uzivatele exit=0`).

> **Auto-detekce OData pole:** skript hledá pole „Telemetry User ID" podle názvu. Když ho
> standardní `Users` page přes OData nevystavuje, **vypíše dostupná pole a skončí chybou** —
> v tom případě pošli ten výpis polí, doladíme název (případně přidat pole na Page 9800).

## Krok 4 — ověření

```sql
SELECT COUNT(*) AS users FROM dbo.BCUser;
SELECT TOP 10 UserId, Name FROM dbo.vw_UserMap ORDER BY Name;
```
- Dashboard `http://10.8.2.225:8080/` → záložka **👤 Uživatelé**: u GUID jsou jména (Ctrl+F5).
- Pruh pod KPI: **„Celkem SQL X / cloud Y (%)"** + per modul.
- Aktivita/Kandidáti/RT0031: místo GUID reálná jména.

## Rollback

- Skripty/web: zkopírovat zpět předchozí verze z gitu (`git checkout <commit>~1 -- <soubor>`).
- `dbo.BCUser` lze ponechat (nepoužívají ho ostatní moduly) nebo `DROP TABLE dbo.BCUser; DROP VIEW dbo.vw_UserMap;`.
- `usermap.json`: dashboard funguje i prázdný (jen nezobrazí jména).

## Pořadí (shrnutí)

1. Kopie souborů (Krok 1).
2. **admintrnka**: SQL deploy `03_users.sql` (Krok 2).
3. **svc**: `schtasks /run /tn BC_Telemetry_Daily` (Krok 3).
4. Ověřit dashboard + SQL (Krok 4).
