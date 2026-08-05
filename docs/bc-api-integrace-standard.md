# Standard pro integrace čtoucí z BC cloudu

Platí pro **každou** aplikaci, službu, BI report nebo skript, který sahá na Business Central online
(`api.businesscentral.dynamics.com`). Vzniklo, protože vedle telemetrie bude z BC tahat data víc
aplikací a jedna neukázněná integrace umí položit ostatní.

## Proč pravidla vůbec jsou

BC online má **limity na identitu**, ne na aplikaci:

| Limit | Hodnota | Co to znamená |
|---|---|---|
| Rychlost | **6 000 požadavků / 5 min** na identitu (uživatel nebo service principal) | dvě aplikace pod jedním SP si limit **dělí** |
| Souběžnost | **5 zpracovávaných + 95 ve frontě** na identitu | víc paralelních vláken nic nezrychlí, jen čekají |
| Překročení | HTTP **429** + hlavička `Retry-After` | klient musí počkat; kdo to neumí, spadne |

Sdílená je i výkonnost prostředí — těžký report běžící přes den zpomalí uživatele v BC.

## Pravidla

1. **Jedna aplikace = jeden service principal.** Nikdy nepřidávej novou integraci na cizí app
   registration. Důvody: limit se počítá na identitu, práva jdou zúžit per aplikace, a když jedna
   appka zlobí, odstřihneš ji bez dopadu na ostatní.
2. **Práva jen na čtení**, pokud aplikace nezapisuje. Rozhoduje **permission set app usera v BC**
   (stránka *Aplikace Microsoft Entra*), ne oprávnění v Entra — `API.ReadWrite.All` je jen vstupenka.
   `SUPER` app userovi přiřadit nejde a `D365 BUS PREMIUM` je na čtení zbytečně široká.
3. **Klient musí umět 429 a 5xx** — respektovat `Retry-After`, exponenciální backoff, konečný počet
   pokusů a **čitelnou hlášku** do logu. Vzor: [`scripts/BCApi.psm1`](../scripts/BCApi.psm1).
4. **Čti z read-only repliky** — na GET posílej hlavičku `Data-Access-Intent: ReadOnly`.
   Odlehčí to primární databázi BC. (Dokumentované pro API pages/queries; jinde se hlavička ignoruje,
   takže neuškodí — jen ověř, že endpoint nevrací 400.)
5. **Stahuj jen co potřebuješ** — `$select` na sloupce, `$filter` na straně BC, ne až v Power Query.
6. **Přírůstkově, ne pořád znovu** — watermark (`systemModifiedAt`, `Entry_No`, …) a stránkování přes
   `@odata.nextLink` / `$top`. Plný pull tabulky patří leda do prvního naplnění.
7. **Zapisuješ?** Povinně `If-Match` s ETagem, jinak si dvě aplikace přepíší záznam navzájem.
8. **Nové endpointy dělej jako API page / query v AL**, ne publikováním UI stránky. Stabilnější,
   rychlejší, a Microsoft publikování UI stránek postupně omezuje.
9. **Těžké a historické věci netahej živě** — extrahuj do SQL a nad ním stav report. Živý OData nech
   pro malé a aktuální dotazy.
10. **Provozní okno** — dávkové pully plánuj mimo pracovní dobu. Telemetrie jede v okně z
    `ops/schedule.json`.

## Registrace nové integrace — checklist

1. Entra → **App registrations → New registration** (název `BC_<aplikace>_SP`, single tenant).
2. **Certificates & secrets** → secret (24 měs.) nebo **certifikát** (u dlouhoběžících služeb lepší —
   nevyprší tiše). Zapiš expiraci do registru níže.
3. **Authentication → Web → Redirect URI** `https://businesscentral.dynamics.com/OAuthLanding.htm`
   (bez toho spadne „Udělit souhlas" v BC na `AADSTS500113`).
4. **API permissions** → Dynamics 365 Business Central → **Application permissions** →
   `API.ReadWrite.All` → **Grant admin consent** (musí být zeleně Granted, jinak token nemá `roles` → 401).
5. **BC → Aplikace Microsoft Entra** (page 9861) → Client ID → permission set (read-only sada) →
   **Povolený** → **Udělit souhlas**.
6. Secret **nikdy do kódu ani do repa** — Credential Manager v profilu servisního účtu, Key Vault,
   nebo secret store dané platformy.
7. Zapiš aplikaci do registru níže a nastav hlídání expirace.

## Registr integrací

| Aplikace | Service principal | Práva v BC | Secret/cert do | Poznámka |
|---|---|---|---|---|
| BC_Telemetry (modul B, Users, sync-status) | `BC_Telemetry_SP` `4eda9e64-…-c10135` | `D365 BUS PREMIUM` (zúžit na read) | **2028-06-07** | čte Change Log + Users, denní dávka |
| _(doplnit při založení další)_ | | | | |

> Registr drž aktuální — až se bude řešit „kdo nám vytěžuje BC", tohle je první místo, kam se kouká.

## Když BC začne odmítat

| Příznak | Co se děje | Co s tím |
|---|---|---|
| HTTP **429** | vyčerpaný limit rychlosti té identity | zkontroluj, jestli na SP nevisí víc aplikací; sniž frekvenci; rozděl na víc SP |
| HTTP **401** uprostřed běhu | vypršel access token (max 1 h) | obnovit token a pokračovat, ne padat |
| HTTP **401** hned na začátku | vypršel secret nebo chybí admin consent | Entra → secret, API permissions |
| HTTP **403** | app user nemá v BC práva na ta data | BC → Aplikace Microsoft Entra → sady oprávnění |
| Pomalé odpovědi, timeouty | zatížené prostředí | `Data-Access-Intent: ReadOnly`, menší `$top`, přesun mimo pracovní dobu |

## Jak to má zařízené telemetrie

Veškeré volání BC jde přes [`scripts/BCApi.psm1`](../scripts/BCApi.psm1):
token s automatickou obnovou, brzda na počet požadavků za minutu, opakování při 429 (dle `Retry-After`)
i při 5xx, `Data-Access-Intent: ReadOnly`, `$select` jen na ukládané sloupce, a když endpoint hlavičku
nebo `$select` nepřijme, běh **degraduje místo pádu**. Na konci každého importu je v logu souhrn
(kolik požadavků, kolik čekání kvůli limitu).

Nastavení (nepovinné) v `C:\Apps\BC_Telemetry_Web\ops\bcapi.json`:

```json
{ "requestsPerMinute": 90, "maxAttempts": 6, "timeoutSeconds": 300,
  "maxWaitSeconds": 120, "readOnlyIntent": true, "useSelect": true, "tokenMinutes": 45 }
```

Bez souboru platí tyto hodnoty jako výchozí.
