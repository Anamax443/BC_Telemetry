/* ---------- 03_users.sql ----------
   BC_Telemetry — adresar uzivatelu z BC Users web service (Page 9800).
   Klic mapovani modulu A/C: telemetricky pseudonymni GUID -> realne jmeno.

   POZOR (overeno 2026-06-10): telemetricky UserId v AppPageViews =
     BC pole "Telemetry User ID"  (NE AAD object id, NE User Security ID).
   Naplnuje scripts\BC_Users_Import.ps1 (OData -> MERGE).
*/

-- filtrovany index (WHERE ...) vyzaduje QUOTED_IDENTIFIER ON; sqlcmd ho ma defaultne OFF
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.BCUser', 'U') IS NULL
    CREATE TABLE dbo.BCUser (
        UserSecurityId   NVARCHAR(36)  NOT NULL,   -- BC "User Security ID" (PK, vzdy unikatni)
        TelemetryUserId  NVARCHAR(36)  NULL,        -- = AppPageViews UserId (muze byt prazdny u uctu bez telemetrie)
        UserName         NVARCHAR(132) NULL,        -- login (MTRNKA, ACACKY, ...)
        FullName         NVARCHAR(132) NULL,        -- cele jmeno (Milan Trnka)
        AuthEmail        NVARCHAR(250) NULL,
        State            NVARCHAR(20)  NULL,        -- Enabled / Disabled
        UpdatedAt        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_BCUser_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_BCUser PRIMARY KEY CLUSTERED (UserSecurityId)
    );
GO

-- vyhledavaci index nad telemetrickym GUID (jen neprazdne)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BCUser_Telemetry' AND object_id = OBJECT_ID('dbo.BCUser'))
    CREATE INDEX IX_BCUser_Telemetry ON dbo.BCUser (TelemetryUserId)
        WHERE TelemetryUserId IS NOT NULL;
GO

-- mapovaci view: telemetricky GUID -> nejlepsi dostupne jmeno
CREATE OR ALTER VIEW dbo.vw_UserMap AS
    SELECT  TelemetryUserId AS UserId,
            COALESCE(NULLIF(LTRIM(RTRIM(FullName)), ''),
                     NULLIF(LTRIM(RTRIM(UserName)), ''),
                     TelemetryUserId) AS Name
    FROM    dbo.BCUser
    WHERE   TelemetryUserId IS NOT NULL
      AND   LTRIM(RTRIM(TelemetryUserId)) <> ''
      AND   TelemetryUserId <> '00000000-0000-0000-0000-000000000000';
GO
