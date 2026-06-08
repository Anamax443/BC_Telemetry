/* ============================================================================
   BC_Telemetry — agregační vrstva (rollups)
   Řeší škálu: raw dbo.BCPageLog má miliony řádků a po retenci se maže;
   agregáty jsou malé, kumulují se navždy a dashboard z nich čte rychle.

   Princip: inkrementální rollup — zpracuje jen NOVÉ raw řádky (Id > watermark),
   takže náklad roste s denním přírůstkem, ne s celkovou velikostí tabulky.
   ============================================================================ */

/* ----------------------------------------------------------------------------
   Control tabulka — ETL watermark (kam až se rolloval raw log)
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.ETLWatermark', 'U') IS NULL
    CREATE TABLE dbo.ETLWatermark (
        Name    NVARCHAR(100) PRIMARY KEY,
        LastId  BIGINT        NOT NULL DEFAULT 0,
        Updated DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
    );
GO
IF NOT EXISTS (SELECT 1 FROM dbo.ETLWatermark WHERE Name = 'BCPageDaily')
    INSERT INTO dbo.ETLWatermark (Name, LastId) VALUES ('BCPageDaily', 0);
GO

/* ----------------------------------------------------------------------------
   Denní rollup: aktivita per uživatel × stránka × den
   Kumuluje se i poté, co se raw řádky smažou retencí.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.BCPageDaily', 'U') IS NULL
    CREATE TABLE dbo.BCPageDaily (
        DateKey     DATE          NOT NULL,
        UserName    NVARCHAR(200) NOT NULL,
        PageId      NVARCHAR(50)  NOT NULL,
        PageName    NVARCHAR(200),
        CompanyName NVARCHAR(100) NOT NULL,
        Hits        INT           NOT NULL,
        CONSTRAINT PK_BCPageDaily PRIMARY KEY (DateKey, UserName, PageId, CompanyName)
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BCPageDaily_User')
    CREATE INDEX IX_BCPageDaily_User ON dbo.BCPageDaily (UserName, DateKey DESC) INCLUDE (PageId, PageName, Hits);
GO

/* ----------------------------------------------------------------------------
   Inkrementální rollup proc — volá se z importu po každém běhu
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.usp_BCPageLog_Rollup', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_BCPageLog_Rollup;
GO
CREATE PROCEDURE dbo.usp_BCPageLog_Rollup
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from BIGINT, @to BIGINT;
    SELECT @from = LastId FROM dbo.ETLWatermark WHERE Name = 'BCPageDaily';
    SELECT @to = ISNULL(MAX(Id), @from) FROM dbo.BCPageLog;
    IF @to <= @from RETURN;

    ;WITH src AS (
        SELECT CAST(Timestamp AS DATE) AS DateKey, UserName,
               ISNULL(PageId,'?') AS PageId, PageName,
               ISNULL(CompanyName,'?') AS CompanyName, COUNT(*) AS Hits
        FROM dbo.BCPageLog
        WHERE Id > @from AND Id <= @to
        GROUP BY CAST(Timestamp AS DATE), UserName, ISNULL(PageId,'?'), PageName, ISNULL(CompanyName,'?')
    )
    MERGE dbo.BCPageDaily AS tgt
    USING src ON tgt.DateKey = src.DateKey AND tgt.UserName = src.UserName
             AND tgt.PageId = src.PageId AND tgt.CompanyName = src.CompanyName
    WHEN MATCHED THEN UPDATE SET tgt.Hits = tgt.Hits + src.Hits, tgt.PageName = src.PageName
    WHEN NOT MATCHED THEN
        INSERT (DateKey, UserName, PageId, PageName, CompanyName, Hits)
        VALUES (src.DateKey, src.UserName, src.PageId, src.PageName, src.CompanyName, src.Hits);

    UPDATE dbo.ETLWatermark SET LastId = @to, Updated = SYSUTCDATETIME() WHERE Name = 'BCPageDaily';
END
GO

/* ----------------------------------------------------------------------------
   RT0031 — Authorization Failed (migrace SUPER→role).
   Pozn.: RT0031 jsou v AppTraces, ne v pageViews → vyžaduje druhý ingest
   (BC_AuthFail_Import, fáze 2). Tabulka už existuje, aby dashboard fungoval
   ihned, jakmile data dorazí.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.BCAuthFailDaily', 'U') IS NULL
    CREATE TABLE dbo.BCAuthFailDaily (
        DateKey   DATE          NOT NULL,
        UserName  NVARCHAR(200) NOT NULL,
        ObjectId  NVARCHAR(50)  NOT NULL,
        ObjectName NVARCHAR(200),
        Failures  INT           NOT NULL,
        CONSTRAINT PK_BCAuthFailDaily PRIMARY KEY (DateKey, UserName, ObjectId)
    );
GO

/* ----------------------------------------------------------------------------
   Pohledy pro dashboard (čtou jen z agregátů — rychlé i nad miliony raw)
   ---------------------------------------------------------------------------- */

-- KPI dlaždice
IF OBJECT_ID('dbo.vw_DashKPI', 'V') IS NOT NULL DROP VIEW dbo.vw_DashKPI;
GO
CREATE VIEW dbo.vw_DashKPI AS
    SELECT
        (SELECT COUNT(DISTINCT UserName) FROM dbo.BCPageDaily WHERE DateKey >= DATEADD(DAY,-30,CAST(SYSUTCDATETIME() AS DATE))) AS ActiveUsers30d,
        (SELECT COUNT(DISTINCT PageId)   FROM dbo.BCPageDaily WHERE DateKey >= DATEADD(DAY,-30,CAST(SYSUTCDATETIME() AS DATE))) AS DistinctPages30d,
        (SELECT ISNULL(SUM(Hits),0)      FROM dbo.BCPageDaily WHERE DateKey >= DATEADD(DAY,-30,CAST(SYSUTCDATETIME() AS DATE))) AS Hits30d,
        (SELECT ISNULL(SUM(Failures),0)  FROM dbo.BCAuthFailDaily WHERE DateKey >= DATEADD(DAY,-14,CAST(SYSUTCDATETIME() AS DATE))) AS AuthFails14d;
GO

-- Kandidáti na vyřazení z permission setu: ≤2 návštěvy za celé sledované období
IF OBJECT_ID('dbo.vw_DashTrimCandidates', 'V') IS NOT NULL DROP VIEW dbo.vw_DashTrimCandidates;
GO
CREATE VIEW dbo.vw_DashTrimCandidates AS
    SELECT UserName, PageId, PageName, CompanyName,
           SUM(Hits) AS TotalHits, MAX(DateKey) AS LastUsed
    FROM dbo.BCPageDaily
    GROUP BY UserName, PageId, PageName, CompanyName
    HAVING SUM(Hits) <= 2;
GO

-- Aktivita per uživatel (top stránky)
IF OBJECT_ID('dbo.vw_DashUserActivity', 'V') IS NOT NULL DROP VIEW dbo.vw_DashUserActivity;
GO
CREATE VIEW dbo.vw_DashUserActivity AS
    SELECT UserName, PageId, PageName, CompanyName,
           SUM(Hits) AS TotalHits, MAX(DateKey) AS LastUsed
    FROM dbo.BCPageDaily
    GROUP BY UserName, PageId, PageName, CompanyName;
GO

-- Denní trend (sparkline)
IF OBJECT_ID('dbo.vw_DashTrend', 'V') IS NOT NULL DROP VIEW dbo.vw_DashTrend;
GO
CREATE VIEW dbo.vw_DashTrend AS
    SELECT DateKey, SUM(Hits) AS Hits, COUNT(DISTINCT UserName) AS Users
    FROM dbo.BCPageDaily
    GROUP BY DateKey;
GO
