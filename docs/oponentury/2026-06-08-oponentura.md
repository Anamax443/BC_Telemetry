# Oponentura: BC Telemetrie — technická dokumentace

**Dokument:** BC_Telemetry_Dokumentace.html (v1.0)
**Autor dokumentu:** Milan Trnka / AXIMA
**Datum oponentury:** 2026-06-08
**Archivováno:** 2026-06-08 (paste z chatu)

> Reakce s rozhodnutími accept/reject/defer: [2026-06-08-reakce.md](2026-06-08-reakce.md)

**Celkové hodnocení:** Dokument strukturovaný, přehledný a obsahově užitečný pro zprovoznění
telemetrie BC → Azure → SQL. Závažné nedostatky v oblasti automatizace, bezpečnosti, robustnosti
importního skriptu a korektnosti DCR filtru.

---

## 🔴 Kritické výhrady

### 1. DCR filtr — logická chyba a rozpor
- AppTraces: `clientType !in ("Background","WebService","ODataV4","Api")` propustí Mobile/Desktop/TeamMember/Management.
- AppPageViews: `clientType == "Web"` — správně, ale nekonzistence vůči AppTraces.
- Text dokumentu říká „pouze interaktivní uživatelé" → vyžaduje whitelist `== "Web"` pro obě tabulky.

### 2. Watermark — může způsobit ztrátu dat
- `MAX(Timestamp)` + `if ($ts -le $lastImport) { continue }`: při dvou záznamech ve stejné ms a přerušení po vložení prvního se druhý ztratí.
- Náprava: `where timestamp > @lastTimestamp` v KQL, nebo unikátní klíč / WatermarkId, řadit vzestupně.

### 3. Skript stahuje zbytečně 90 dní pokaždé
- Po prvním importu se znovu stáhne celých 90 dní; LAW dotaz nad 90 dny není zdarma a s objemem zpomaluje.
- Náprava: dynamicky `where timestamp > datetime($lastTs)`.

### 4. Chybí ošetření chyb a transakce — import není atomický
- Bez try/catch/finally; selhání uprostřed → část vložena, neúspěšné se ztratí (přeskočí watermarkem).
- Náprava: SqlBulkCopy + SqlTransaction, nebo staging tabulka + MERGE / INSERT WHERE NOT EXISTS; try/catch + alert.

## 🟠 Závažné nedostatky

### 5. Azure autentizace není vhodná pro automatizaci
- `Connect-AzAccount -TenantId` vyžaduje interaktivní přihlášení → v Task Scheduleru selže.
- Řešení: Service Principal (Client Secret/Certificate), secret v Key Vault / Credential Manageru.

### 6. Nízký výkon — INSERT po řádcích
- `foreach { INSERT }` při 50k+ řádcích pomalé. Náhrada: SqlBulkCopy.

### 7. Chybí retence / purge starých dat v SQL
- BCPageLog roste neomezeně. Doporučení: smazat záznamy starší 6 měsíců (SQL job).

### 8. Task Scheduler — nesprávný LogonType pro doménový účet
- `-LogonType ServiceAccount` je pro virtuální/gMSA účty, ne doménové → 0x80041315.
- Správně: `-LogonType Password` nebo gMSA.

### 9. SUPER permission set — bezpečnostní riziko
- Návrh přiřadit SUPER pro sběr telemetrie dává plná admin práva i během sledování.
- Doporučení: vlastní Permission Set TELEMETRY (Read + Execute, žádný Write/Modify/Delete/Admin).

## 🟡 Menší nedostatky

| Sekce | Problém | Návrh |
|---|---|---|
| §03 | Chybí vytvoření Service Principal a přiřazení role Log Analytics Reader | přidat krok |
| §04 | Connection string viditelný BC adminům | Key Vault URI / upozornění |
| §08 | `customDimensions['x']` vs `.x` notace | ověřit reálná data, konzistence |
| §09 | Chybí `Import-Module Az` | doplnit |
| §11 | Chybí přiřazení role SP na úrovni workspace | `New-AzRoleAssignment … "Log Analytics Reader" -Scope $workspaceId` |
| Celkově | HTML, neverzované | uložit jako Markdown do Gitu, propojit s Issues/PR |

## 🟢 Doporučení (optional)

1. Monitoring importu — e-mail při chybě, log počtu řádků do Event Logu.
2. Ošetřit rate limiting z Azure — retry s exponenciálním čekáním.
3. Ukázkový SQL pro analýzu permission setů (GROUP BY UserName, PageName).
4. Ověřit osobní údaje v `customDimensions` (GDPR).
5. Vypnout telemetrii / snížit cap pro testovací prostředí.

## 📋 Shrnutí — před nasazením do produkce

| Priorita | Položka |
|---|---|
| 🔴 1 | DCR filtr → `clientType == "Web"` pro AppTraces i AppPageViews |
| 🔴 2 | Watermark → KQL `where timestamp > @lastTimestamp` |
| 🔴 3 | Azure auth → Service Principal |
| 🔴 4 | Ošetření chyb + transakce/staging |
| 🟠 5 | SqlBulkCopy místo řádkového INSERT |
| 🟠 6 | Task Scheduler LogonType Password / gMSA |
| 🟠 7 | Nepoužívat SUPER → Permission Set TELEMETRY |

**Závěr:** Dokument na ~60 %. Po opravě kritických a závažných bodů 90+ %. Doporučen pilot 1–2 týdny s monitoringem.
