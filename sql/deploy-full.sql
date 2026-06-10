/* ====== BC_Telemetry — KONSOLIDOVANY DEPLOY (paste do SSMS jako sysadmin) ======
   Generovano spojenim 01_schema + 02_aggregates + 04_audit + login/prava.
   Pouzij, kdyz na serveru NENI repo (deploy.cmd) a bezny ucet nema DDL prava —
   sysadmin to vlozi do SSMS a spusti (F5). Idempotentni; pri zmene 01/02/04 regeneruj.
   Servisni ucet: AXINETWORK\svc-bc-telemetry.  Nasazeno LIVE 2026-06-10.
   ============================================================================ */
USE BC_Telemetry;
GO
/* ---------- 01_schema.sql ---------- */
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
GO
/* ---------- 02_aggregates.sql ---------- */
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
GO
/* ---------- 04_audit.sql ---------- */
/* ============================================================================
   BC_Telemetry — Modul B (Audit změn / Change Log) + Modul C (RT0031) SQL
   ============================================================================ */

/* ----------------------------------------------------------------------------
   Modul B — dbo.BCChangeLog (kdo / co / kdy vytvořil / změnil / smazal)
   Zdroj: BC Change Log Entries přes OData. Identita = REÁLNÝ BC User ID.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.BCChangeLog', 'U') IS NULL
    CREATE TABLE dbo.BCChangeLog (
        Id          INT IDENTITY      PRIMARY KEY,
        EntryNo     BIGINT            NOT NULL,           -- BC Entry No. (watermark + dedup)
        ChangedAt   DATETIME2(3)      NOT NULL,
        UserId      NVARCHAR(132)     NOT NULL,           -- reálný BC user (UPN / user name)
        CompanyName NVARCHAR(100),
        TableNo     INT,
        TableName   NVARCHAR(200),
        FieldNo     INT,
        FieldName   NVARCHAR(200),
        ChangeType  NVARCHAR(20),                          -- Insertion / Modification / Deletion
        PrimaryKey  NVARCHAR(440),
        OldValue    NVARCHAR(MAX),
        NewValue    NVARCHAR(MAX),
        ImportDatum DATETIME2(3)      NOT NULL DEFAULT SYSUTCDATETIME()
    );
GO
-- EntryNo je per-firma sekvence → dedup na (CompanyName, EntryNo), ne jen EntryNo
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_BCChangeLog_Company_EntryNo')
    CREATE UNIQUE INDEX UX_BCChangeLog_Company_EntryNo ON dbo.BCChangeLog (CompanyName, EntryNo);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BCChangeLog_User_Time')
    CREATE INDEX IX_BCChangeLog_User_Time ON dbo.BCChangeLog (UserId, ChangedAt DESC)
        INCLUDE (TableName, FieldName, ChangeType);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BCChangeLog_Type_Time')
    CREATE INDEX IX_BCChangeLog_Type_Time ON dbo.BCChangeLog (ChangeType, ChangedAt DESC); -- rychlé „kdo smazal"
GO

-- Dashboard view — poslední změny (kdo/co/kdy), s důrazem na Deletion
IF OBJECT_ID('dbo.vw_DashAudit', 'V') IS NOT NULL DROP VIEW dbo.vw_DashAudit;
GO
CREATE VIEW dbo.vw_DashAudit AS
    SELECT TOP 100 PERCENT
        ChangedAt, UserId, CompanyName, ChangeType,
        TableName, FieldName, PrimaryKey, OldValue, NewValue
    FROM dbo.BCChangeLog
    ORDER BY ChangedAt DESC;
GO

-- Retence auditu (compliance — delší než raw page log; default 24 měsíců)
IF OBJECT_ID('dbo.usp_BCChangeLog_Purge', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_BCChangeLog_Purge;
GO
CREATE PROCEDURE dbo.usp_BCChangeLog_Purge @RetentionMonths INT = 24
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.BCChangeLog WHERE ChangedAt < DATEADD(MONTH, -@RetentionMonths, SYSUTCDATETIME());
END
GO

/* ----------------------------------------------------------------------------
   Modul C — RT0031 rollup (dbo.BCAuthFailDaily je definovaná v 02_aggregates.sql)
   Inkrementální rollup z raw staging (plněn BC_AuthFail_Import.ps1).
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.BCAuthFailRaw', 'U') IS NULL
    CREATE TABLE dbo.BCAuthFailRaw (
        Id         INT IDENTITY PRIMARY KEY,
        Timestamp  DATETIME2(3)  NOT NULL,
        UserId     NVARCHAR(100) NOT NULL,    -- pseudonymní GUID (jako modul A)
        ObjectId   NVARCHAR(50),
        ObjectName NVARCHAR(200),
        CONSTRAINT UX_BCAuthFailRaw UNIQUE (Timestamp, UserId, ObjectId)
    );
GO
IF OBJECT_ID('dbo.usp_BCAuthFail_Rollup', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_BCAuthFail_Rollup;
GO
CREATE PROCEDURE dbo.usp_BCAuthFail_Rollup
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH src AS (
        SELECT CAST(Timestamp AS DATE) AS DateKey, UserId AS UserName,
               ISNULL(ObjectId,'?') AS ObjectId, ObjectName, COUNT(*) AS Failures
        FROM dbo.BCAuthFailRaw
        GROUP BY CAST(Timestamp AS DATE), UserId, ISNULL(ObjectId,'?'), ObjectName
    )
    MERGE dbo.BCAuthFailDaily AS tgt
    USING src ON tgt.DateKey = src.DateKey AND tgt.UserName = src.UserName AND tgt.ObjectId = src.ObjectId
    WHEN MATCHED THEN UPDATE SET tgt.Failures = src.Failures, tgt.ObjectName = src.ObjectName
    WHEN NOT MATCHED THEN
        INSERT (DateKey, UserName, ObjectId, ObjectName, Failures)
        VALUES (src.DateKey, src.UserName, src.ObjectId, src.ObjectName, src.Failures);
END
GO
GO
/* ---------- login + user + prava pro AXINETWORK\svc-bc-telemetry ---------- */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'AXINETWORK\svc-bc-telemetry')
    CREATE LOGIN [AXINETWORK\svc-bc-telemetry] FROM WINDOWS;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AXINETWORK\svc-bc-telemetry')
    CREATE USER [AXINETWORK\svc-bc-telemetry] FOR LOGIN [AXINETWORK\svc-bc-telemetry];
GO
ALTER ROLE db_datareader ADD MEMBER [AXINETWORK\svc-bc-telemetry];
ALTER ROLE db_datawriter ADD MEMBER [AXINETWORK\svc-bc-telemetry];
GRANT EXECUTE ON dbo.usp_BCPageLog_Rollup  TO [AXINETWORK\svc-bc-telemetry];
GRANT EXECUTE ON dbo.usp_BCPageLog_Purge   TO [AXINETWORK\svc-bc-telemetry];
GRANT EXECUTE ON dbo.usp_BCChangeLog_Purge TO [AXINETWORK\svc-bc-telemetry];
GRANT EXECUTE ON dbo.usp_BCAuthFail_Rollup TO [AXINETWORK\svc-bc-telemetry];
GO
PRINT 'HOTOVO: schema + agregaty + audit + prava pro AXINETWORK\svc-bc-telemetry';
GO
