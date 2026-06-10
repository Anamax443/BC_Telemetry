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
    -- ObjectName popisný → MAX(), ne v GROUP BY (jinak duplicate PK_BCAuthFailDaily)
    ;WITH src AS (
        SELECT CAST(Timestamp AS DATE) AS DateKey, UserId AS UserName,
               ISNULL(ObjectId,'?') AS ObjectId, MAX(ObjectName) AS ObjectName, COUNT(*) AS Failures
        FROM dbo.BCAuthFailRaw
        GROUP BY CAST(Timestamp AS DATE), UserId, ISNULL(ObjectId,'?')
    )
    MERGE dbo.BCAuthFailDaily AS tgt
    USING src ON tgt.DateKey = src.DateKey AND tgt.UserName = src.UserName AND tgt.ObjectId = src.ObjectId
    WHEN MATCHED THEN UPDATE SET tgt.Failures = src.Failures, tgt.ObjectName = src.ObjectName
    WHEN NOT MATCHED THEN
        INSERT (DateKey, UserName, ObjectId, ObjectName, Failures)
        VALUES (src.DateKey, src.UserName, src.ObjectId, src.ObjectName, src.Failures);
END
GO
