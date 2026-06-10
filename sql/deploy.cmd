@echo off
setlocal
REM ============================================================================
REM  BC_Telemetry — SQL deploy (GPO-safe)
REM  sqlcmd.exe je nativni binarka -> NEpodleha GPO AllSigned (na rozdil od .ps1),
REM  takze tenhle deploy jde spustit i na domenovem serveru s AllSigned politikou.
REM
REM  Pouziti (jako admin na cilovem serveru, z adresare sql\):
REM     deploy.cmd                              -> localhost, AXINETWORK\svc-bc-telemetry
REM     deploy.cmd localhost  "DOMENA\ucet"     -> jiny servisni ucet
REM     deploy.cmd BSWNAV01   "DOMENA\ucet"     -> jiny SQL server
REM
REM  Idempotentni: kazdy skript jen vytvori, co chybi. Bezpecne spustit opakovane.
REM ============================================================================

set "SQLSERVER=%~1"
if "%SQLSERVER%"=="" set "SQLSERVER=localhost"
set "SVCACCT=%~2"
if "%SVCACCT%"=="" set "SVCACCT=AXINETWORK\svc-bc-telemetry"
set "DB=BC_Telemetry"
set "HERE=%~dp0"

echo === BC_Telemetry SQL deploy ===
echo   SQL server : %SQLSERVER%
echo   Databaze   : %DB%
echo   Svc ucet   : %SVCACCT%
echo.

REM -b = ukoncit s chybou pri SQL erroru; -E = trusted (Windows) connection
sqlcmd -S "%SQLSERVER%" -E -b -i "%HERE%00_database.sql"                                   || goto :err
sqlcmd -S "%SQLSERVER%" -E -b -d %DB% -i "%HERE%01_schema.sql"                             || goto :err
sqlcmd -S "%SQLSERVER%" -E -b -d %DB% -i "%HERE%02_aggregates.sql"                         || goto :err
sqlcmd -S "%SQLSERVER%" -E -b -d %DB% -i "%HERE%03_users.sql"                              || goto :err
sqlcmd -S "%SQLSERVER%" -E -b -d %DB% -i "%HERE%04_audit.sql"                              || goto :err
sqlcmd -S "%SQLSERVER%" -E -b -d %DB% -v ServiceAccount="%SVCACCT%" -i "%HERE%05_grants.sql" || goto :err

echo.
echo === HOTOVO: databaze + schema + agregaty + audit + prava nasazeny ===
endlocal
exit /b 0

:err
echo.
echo *** CHYBA pri deploy (exit %errorlevel%) — viz vystup vyse ***
endlocal
exit /b 1
