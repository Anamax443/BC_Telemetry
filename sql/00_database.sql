/* ============================================================================
   BC_Telemetry — vytvoření databáze
   Spouští se v kontextu [master] (deploy.cmd to dělá první).
   Idempotentní: pokud DB existuje, neudělá nic.
   ============================================================================ */
IF DB_ID('BC_Telemetry') IS NULL
BEGIN
    CREATE DATABASE BC_Telemetry;
    PRINT 'Databáze BC_Telemetry vytvořena.';
END
ELSE
    PRINT 'Databáze BC_Telemetry už existuje — přeskočeno.';
GO
