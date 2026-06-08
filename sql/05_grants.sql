/* ============================================================================
   BC_Telemetry — práva servisního účtu (běží v kontextu DB BC_Telemetry)

   Importní skripty se připojují přes Integrated Security (Windows auth), takže
   SQL práva potřebuje WINDOWS účet, pod kterým běží scheduled task — NE Service
   Principal (ten je jen pro Azure / BC API).

   Účet se předává jako sqlcmd proměnná:
     sqlcmd -d BC_Telemetry -v ServiceAccount="DOMENA\ucet" -i 05_grants.sql
   (deploy.cmd to dělá automaticky; default AXIMA\svc_bc_telemetry.)

   Idempotentní: vše se vytváří jen pokud chybí; GRANT/ALTER ROLE jsou no-op při opakování.
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @acct sysname = N'$(ServiceAccount)';
DECLARE @sql  nvarchar(max);

IF @acct IS NULL OR LTRIM(RTRIM(@acct)) = N''
BEGIN
    RAISERROR('ServiceAccount není zadán — spusť přes deploy.cmd nebo -v ServiceAccount=...', 16, 1);
    RETURN;
END

/* ── Server login (FROM WINDOWS) ─────────────────────────────────────────── */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @acct)
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@acct) + N' FROM WINDOWS;';
    EXEC (@sql);
    PRINT 'Login ' + @acct + ' vytvořen.';
END
ELSE
    PRINT 'Login ' + @acct + ' už existuje.';

/* ── Database user ───────────────────────────────────────────────────────── */
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @acct)
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@acct) + N' FOR LOGIN ' + QUOTENAME(@acct) + N';';
    EXEC (@sql);
    PRINT 'User ' + @acct + ' vytvořen v BC_Telemetry.';
END
ELSE
    PRINT 'User ' + @acct + ' už existuje.';

/* ── Role: čtení + zápis (import plní raw + audit tabulky) ────────────────── */
SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@acct) + N';'; EXEC (@sql);
SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@acct) + N';'; EXEC (@sql);

/* ── EXECUTE na všechny ETL procedury (rollupy + retence, moduly A/B/C) ───── */
SET @sql =
    N'GRANT EXECUTE ON dbo.usp_BCPageLog_Rollup   TO ' + QUOTENAME(@acct) + N';' +
    N'GRANT EXECUTE ON dbo.usp_BCPageLog_Purge    TO ' + QUOTENAME(@acct) + N';' +
    N'GRANT EXECUTE ON dbo.usp_BCChangeLog_Purge  TO ' + QUOTENAME(@acct) + N';' +
    N'GRANT EXECUTE ON dbo.usp_BCAuthFail_Rollup  TO ' + QUOTENAME(@acct) + N';';
EXEC (@sql);

PRINT 'Práva pro ' + @acct + ' nastavena (db_datareader + db_datawriter + EXECUTE na ETL procy).';
GO
