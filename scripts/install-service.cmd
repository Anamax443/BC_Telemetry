@echo off
REM ============================================================================
REM  BC_Telemetry - instalace web sluzby (Node + NSSM) na 10.8.2.225
REM
REM  Servis servíruje dashboard + data.json a poskytuje whitelist API
REM  (cte/zapisuje Windows Firewall rule). Bezi jako LocalSystem - ma prava
REM  menit firewall a nepotrebuje heslo (SQL nesaha, jen soubory).
REM
REM  cmd zamerne (GPO AllSigned-safe). Node spousti powershell -Command inline,
REM  coz AllSigned NEblokuje (na rozdil od .ps1).
REM
REM  Predpoklady: Node.js LTS + NSSM v C:\Tools\nssm\nssm.exe (viz ITDashboard
REM  SETUP-SERVER.md). Spustit jako Administrator na 10.8.2.225.
REM ============================================================================
setlocal
set SVC=BC_Telemetry_Web
set PORT=8080
set APPDIR=C:\Apps\BC_Telemetry_Web
set PUBLIC=%APPDIR%\public
set LOGS=%APPDIR%\logs
set NSSM=C:\Tools\nssm\nssm.exe
set RULE=BC Telemetry Dashboard (%PORT%)
REM servisni ucet, ktery pise snapshot data.json do public (daily scheduler)
set SVCACCT=AXINETWORK\svc-bc-telemetry
REM Default whitelist = stejna sada admin IP jako ITDashboard (10.8.2.213/181/243),
REM jen localhost = vlastni server 10.8.2.225. remoteip umi i CIDR masku a rozsah:
REM   maska:  10.8.2.0/24    rozsah: 10.8.2.180-10.8.2.200    (lze kombinovat carkou)
set WHITELIST=10.8.2.225,10.8.2.181,10.8.2.243

REM Node.exe - uprav, pokud je jinde
for /f "delims=" %%i in ('where node 2^>nul') do set NODE=%%i
if "%NODE%"=="" set NODE=C:\Program Files\nodejs\node.exe

echo [1/6] Slozky...
if not exist "%APPDIR%" mkdir "%APPDIR%"
if not exist "%PUBLIC%" mkdir "%PUBLIC%"
if not exist "%LOGS%"   mkdir "%LOGS%"
REM servisni ucet musi mit zapis do public (snapshot data.json) i logs
icacls "%PUBLIC%" /grant "%SVCACCT%:(OI)(CI)M" >nul
icacls "%LOGS%"   /grant "%SVCACCT%:(OI)(CI)M" >nul
REM a do usermap.json (BC_Users_Import jej prepisuje z dbo.vw_UserMap)
if not exist "%APPDIR%\usermap.json" echo {}> "%APPDIR%\usermap.json"
icacls "%APPDIR%\usermap.json" /grant "%SVCACCT%:(M)" >nul

echo [2/6] Kopirovani souboru (server + dashboard)...
REM   spousti se z korene repa: scripts\install-service.cmd
copy /Y "%~dp0..\web\server.js"  "%APPDIR%\server.js"  >nul
copy /Y "%~dp0..\web\index.html" "%PUBLIC%\index.html" >nul
if exist "%~dp0..\web\data.json" copy /Y "%~dp0..\web\data.json" "%PUBLIC%\data.json" >nul

echo [3/6] Firewall whitelist rule "%RULE%" (pokud chybi)...
netsh advfirewall firewall show rule name="%RULE%" >nul 2>&1
if errorlevel 1 (
  netsh advfirewall firewall add rule name="%RULE%" dir=in action=allow protocol=TCP localport=%PORT% remoteip=%WHITELIST% profile=domain
) else ( echo     rule uz existuje - ponechavam )

echo [4/6] Instalace NSSM sluzby %SVC%...
"%NSSM%" stop %SVC% >nul 2>&1
"%NSSM%" remove %SVC% confirm >nul 2>&1
"%NSSM%" install %SVC% "%NODE%" "%APPDIR%\server.js"
"%NSSM%" set %SVC% AppDirectory "%APPDIR%"
"%NSSM%" set %SVC% AppEnvironmentExtra "BCT_PORT=%PORT%" "BCT_PUBLIC=%PUBLIC%"
"%NSSM%" set %SVC% AppStdout "%LOGS%\web.out.log"
"%NSSM%" set %SVC% AppStderr "%LOGS%\web.err.log"
REM rotace NSSM logu (web.out/err.log) - jinak rostou bez limitu; rotace pri 5 MB
"%NSSM%" set %SVC% AppRotateFiles 1
"%NSSM%" set %SVC% AppRotateOnline 1
"%NSSM%" set %SVC% AppRotateBytes 5242880
"%NSSM%" set %SVC% Start SERVICE_AUTO_START
"%NSSM%" set %SVC% Description "BC_Telemetry web dashboard + whitelist API"

echo [5/6] Start sluzby...
sc start %SVC%

echo [6/6] Hotovo.
echo     URL: http://10.8.2.225:%PORT%/
echo     Snapshot: nastav Export-DashboardSnapshot.ps1 -OutPath "%PUBLIC%\data.json"
echo     Restart pri update:  sc stop %SVC%  (pockat na STOPPED)  pak  sc start %SVC%
endlocal
