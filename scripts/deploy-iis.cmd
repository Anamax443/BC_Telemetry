@echo off
REM ============================================================================
REM  BC_Telemetry - deploy admin dashboardu na IIS
REM  Cilovy server: 10.8.2.225 (B-S-W-SQL-04) - co-located se SQL
REM
REM  Pristupovy model: ANONYMOUS zapnuty (bez prihlasovani), ale omezeno
REM  IP whitelistem - vidi to kdokoliv v lokalni siti, zvenku NIC.
REM
REM  cmd zamerne (ne PowerShell): AXINETWORK domenove servery maji GPO
REM  ExecutionPolicy=AllSigned. IIS servíruje jen statiku -> zadny PS.
REM
REM  Spustit jako Administrator na 10.8.2.225.
REM ============================================================================
setlocal
set SITE=bc-telemetry
set PORT=8080
set ROOT=C:\inetpub\bc-telemetry
set APPCMD=%windir%\system32\inetsrv\appcmd.exe

REM --- WHITELIST: povolene lokalni rozsahy (uprav dle realne site) ------------
REM   format: ipAddress + subnetMask. Pridej radek na kazdy rozsah.
set WL1_IP=10.8.0.0
set WL1_MASK=255.255.0.0
REM   priklad uzsi /24:   set WL1_IP=10.8.2.0   & set WL1_MASK=255.255.255.0
REM   dalsi rozsah:       viz krok [5b] nize

echo [1/7] Instalace IIS + IP Security + Static content (DISM)...
dism /online /enable-feature /featurename:IIS-WebServerRole /all /norestart
dism /online /enable-feature /featurename:IIS-StaticContent /all /norestart
dism /online /enable-feature /featurename:IIS-IPSecurity /all /norestart

echo [2/7] Vytvoreni slozky %ROOT% ...
if not exist "%ROOT%" mkdir "%ROOT%"

echo [3/7] Vytvoreni IIS site %SITE% na portu %PORT% ...
"%APPCMD%" add site /name:%SITE% /physicalPath:"%ROOT%" /bindings:http/*:%PORT%:

echo [4/7] Anonymous ON (zadne prihlasovani pro lokalni uzivatele)...
"%APPCMD%" set config "%SITE%" /section:anonymousAuthentication /enabled:true  /commit:apphost
"%APPCMD%" set config "%SITE%" /section:windowsAuthentication  /enabled:false /commit:apphost

echo [5/7] Odemknout ipSecurity sekci pro per-site konfiguraci...
"%APPCMD%" set config /section:ipSecurity /overrideMode:Allow

echo [5a] Default DENY + povolit whitelist rozsah...
"%APPCMD%" set config "%SITE%" /section:ipSecurity /allowUnlisted:false /commit:apphost
"%APPCMD%" set config "%SITE%" /section:ipSecurity /+"[ipAddress='%WL1_IP%',subnetMask='%WL1_MASK%',allowed='true']" /commit:apphost

REM [5b] Dalsi rozsahy - odkomentuj/duplikuj:
REM "%APPCMD%" set config "%SITE%" /section:ipSecurity /+"[ipAddress='10.9.0.0',subnetMask='255.255.0.0',allowed='true']" /commit:apphost

echo [6/7] MIME typ pro .json...
"%APPCMD%" set config "%SITE%" /section:staticContent /+[fileExtension='.json',mimeType='application/json'] 2>nul

echo [7/7] Hotovo. Nakopiruj web\index.html do %ROOT% a nastav export data.json.
echo     URL (lokalni sit): http://10.8.2.225:%PORT%/
echo.
echo Whitelist: povolen %WL1_IP% / %WL1_MASK% , vse ostatni DENY (allowUnlisted=false).
echo Doporuceni: pridat i firewall pravidlo na port %PORT% jen pro lokalni segment.
endlocal
