@echo off
REM ============================================================================
REM  BC_Telemetry - zmena whitelistu (remoteip) firewall rule dashboardu.
REM  Ekvivalent ITDashboard setAllowedIPs() - source of truth je firewall rule.
REM
REM  Pouziti:
REM    Set-DashboardWhitelist.cmd "10.8.2.0/24"
REM    Set-DashboardWhitelist.cmd "10.8.2.0/24,10.9.0.0/16,10.8.5.17"
REM    Set-DashboardWhitelist.cmd            (bez parametru -> vypise soucasny stav)
REM
REM  Spustit jako Administrator na 10.8.2.225.
REM ============================================================================
setlocal
set PORT=8080
set RULE=BC Telemetry Dashboard (%PORT%)

if "%~1"=="" (
  echo Soucasny whitelist rule "%RULE%":
  netsh advfirewall firewall show rule name="%RULE%" verbose ^| findstr /i "RemoteIP Enabled Profiles"
  goto :eof
)

echo Nastavuji remoteip = %~1
netsh advfirewall firewall set rule name="%RULE%" new remoteip=%~1
if errorlevel 1 (
  echo CHYBA: rule "%RULE%" neexistuje? Spust nejdriv deploy-iis.cmd.
  goto :eof
)
echo Hotovo. Novy stav:
netsh advfirewall firewall show rule name="%RULE%" ^| findstr /i "RemoteIP"
endlocal
