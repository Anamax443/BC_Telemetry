@echo off
REM ============================================================================
REM  BC_Telemetry - deploy admin dashboardu na IIS
REM  Cilovy server: 10.8.2.225 (B-S-W-SQL-04) - co-located se SQL
REM
REM  Whitelist "jako v ITDashboard": jedna pojmenovana Windows Firewall rule,
REM  jejiz remoteip seznam = whitelist. Je to VISIBILITY GATE (kdo se na port
REM  dostane), ne tvrda IIS IP restrikce. Anonymous ON -> zadne prihlasovani.
REM
REM  cmd zamerne (ne PowerShell): AXINETWORK domenove servery maji GPO
REM  ExecutionPolicy=AllSigned. netsh i appcmd jsou cmd-native.
REM
REM  Spustit jako Administrator na 10.8.2.225.
REM ============================================================================
setlocal
set SITE=bc-telemetry
set PORT=8080
set ROOT=C:\inetpub\bc-telemetry
set RULE=BC Telemetry Dashboard (%PORT%)
set APPCMD=%windir%\system32\inetsrv\appcmd.exe

REM --- WHITELIST: povolene lokalni rozsahy (uprav dle realne site) ------------
REM   remoteip prijima IP, rozsahy a CIDR oddelene carkou, napr:
REM     10.8.0.0/16            cely 10.8.x
REM     10.8.2.0/24            jen segment SQL/MIKOS
REM     10.8.2.0/24,10.9.0.0/16   vice rozsahu
set WHITELIST=10.8.0.0/16

echo [1/6] Instalace IIS + Static content (DISM)...
dism /online /enable-feature /featurename:IIS-WebServerRole /all /norestart
dism /online /enable-feature /featurename:IIS-StaticContent /all /norestart

echo [2/6] Vytvoreni slozky %ROOT% ...
if not exist "%ROOT%" mkdir "%ROOT%"

echo [3/6] Vytvoreni IIS site %SITE% na portu %PORT% ...
"%APPCMD%" add site /name:%SITE% /physicalPath:"%ROOT%" /bindings:http/*:%PORT%:

echo [4/6] Anonymous ON (zadne prihlasovani pro lokalni uzivatele)...
"%APPCMD%" set config "%SITE%" /section:anonymousAuthentication /enabled:true  /commit:apphost
"%APPCMD%" set config "%SITE%" /section:windowsAuthentication  /enabled:false /commit:apphost

echo [5/6] MIME typ pro .json...
"%APPCMD%" set config "%SITE%" /section:staticContent /+[fileExtension='.json',mimeType='application/json'] 2>nul

echo [6/6] Windows Firewall whitelist rule "%RULE%" (remoteip=%WHITELIST%)...
netsh advfirewall firewall delete rule name="%RULE%" >nul 2>&1
netsh advfirewall firewall add rule name="%RULE%" dir=in action=allow protocol=TCP localport=%PORT% remoteip=%WHITELIST% profile=domain

echo.
echo Hotovo. Nakopiruj web\index.html do %ROOT% a nastav export data.json.
echo     URL (lokalni sit): http://10.8.2.225:%PORT%/
echo.
echo Whitelist rule: "%RULE%"  remoteip=%WHITELIST%
echo Zmena whitelistu pozdeji:  scripts\Set-DashboardWhitelist.cmd "10.8.2.0/24,10.9.0.0/16"
echo.
echo POZN: rule plati jen kdyz je Domain firewall profil Enabled. Pokud je
echo       vyple (jako na live ITDashboard serveru), je to jen UI/visibility
echo       gate - data.json je pak na portu dostupny komukoliv v domene.
echo       Tvrde vynuceni: zapnout Domain profil, nebo doplnit IIS ipSecurity.
endlocal
