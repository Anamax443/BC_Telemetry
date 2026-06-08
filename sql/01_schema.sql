/* ============================================================================
   BC_Telemetry — SQL schéma
   Databáze: BC_Telemetry  (SQL Server 10.8.2.225 / B-S-W-SQL-04, co-located)
   Tabulka:  dbo.BCPageLog — append log page views interaktivních uživatelů BC

   Verze: 1.1 (zapracována oponentura 2026-06-08)
   ============================================================================ */

IF OBJECT_ID('dbo.BCPageLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BCPageLog (
        Id          INT IDENTITY      PRIMARY KEY,
        Timestamp   DATETIME2(3)      NOT NULL,   -- DATETIME2 kvůli ms přesnosti watermarku
        UserId      NVARCHAR(100)     NOT NULL,
        UserName    NVARCHAR(200),
        PageId      NVARCHAR(50),
        PageName    NVARCHAR(200),
        CompanyName NVARCHAR(100),
        ImportDatum DATETIME2(3)      NOT NULL DEFAULT SYSUTCDATETIME()
    );
END
GO

/* ----------------------------------------------------------------------------
   Indexy
   ---------------------------------------------------------------------------- */

-- Analytické dotazy per uživatel (covering index pro reporty a permission analýzu)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BCPageLog_UserName_Timestamp')
    CREATE INDEX IX_BCPageLog_UserName_Timestamp
        ON dbo.BCPageLog (UserName, Timestamp DESC)
        INCLUDE (PageId, PageName, CompanyName);
GO

-- Časové přehledy + watermark při importu — MAX(Timestamp)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BCPageLog_Timestamp')
    CREATE INDEX IX_BCPageLog_Timestamp
        ON dbo.BCPageLog (Timestamp DESC)
        INCLUDE (UserId, UserName, PageId, PageName);
GO

/* ----------------------------------------------------------------------------
   Anti-duplicita (oponentura bod #2, #4)
   Unikátní filtrovaný index brání vložení téhož page view dvakrát i při
   re-importu / částečném selhání. Staging MERGE v importu se o tuto hranici opírá.
   ---------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_BCPageLog_Dedup')
    CREATE UNIQUE INDEX UX_BCPageLog_Dedup
        ON dbo.BCPageLog (Timestamp, UserId, PageId)
        WHERE PageId IS NOT NULL;
GO

/* ----------------------------------------------------------------------------
   Retence (oponentura bod #7) — držet 6 měsíců, zbytek smazat.
   Volá se z importního skriptu po úspěšném MERGE, nebo samostatným SQL Agent jobem.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.usp_BCPageLog_Purge', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BCPageLog_Purge;
GO
CREATE PROCEDURE dbo.usp_BCPageLog_Purge
    @RetentionMonths INT = 6
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.BCPageLog
    WHERE Timestamp < DATEADD(MONTH, -@RetentionMonths, SYSUTCDATETIME());
END
GO

/* ----------------------------------------------------------------------------
   Analytický pohled — kandidáti na permission set (oponentura bod 🟢#3)
   Stránky s 1–2 návštěvami za sledované období = kandidáti na vyřazení.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.vw_BCPageActivity', 'V') IS NOT NULL
    DROP VIEW dbo.vw_BCPageActivity;
GO
CREATE VIEW dbo.vw_BCPageActivity
AS
    SELECT
        UserName,
        PageId,
        PageName,
        CompanyName,
        COUNT(*)               AS PocetOtevreni,
        MIN(Timestamp)         AS PrvniOtevreni,
        MAX(Timestamp)         AS PosledniOtevreni
    FROM dbo.BCPageLog
    GROUP BY UserName, PageId, PageName, CompanyName;
GO
