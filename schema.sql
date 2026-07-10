/* ============================================================
   Directory Services Management Tool - database schema
   Target: Microsoft SQL Server 2017+  (works on SQL Express)
   Run once at install time (Install.ps1 does this for you).
   ============================================================ */

IF DB_ID('DSMTOOL') IS NULL
    CREATE DATABASE [DSMTOOL];
GO
USE [DSMTOOL];
GO

/* ---- Console configuration (key/value) ------------------- */
IF OBJECT_ID('dbo.Config') IS NULL
CREATE TABLE dbo.Config (
    [Key]        NVARCHAR(128) NOT NULL PRIMARY KEY,
    [Value]      NVARCHAR(MAX) NULL,
    UpdatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedBy    NVARCHAR(128) NULL
);
GO

/* ---- Encrypted secrets (DPAPI blobs, never plain text) --- */
IF OBJECT_ID('dbo.Secrets') IS NULL
CREATE TABLE dbo.Secrets (
    Name         NVARCHAR(128) NOT NULL PRIMARY KEY,
    Cipher       NVARCHAR(MAX) NOT NULL,
    Account      NVARCHAR(256) NULL,
    UpdatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedBy    NVARCHAR(128) NULL
);
GO

/* ---- LDAP security group -> console role mapping --------- */
IF OBJECT_ID('dbo.RoleMappings') IS NULL
CREATE TABLE dbo.RoleMappings (
    Id           INT IDENTITY(1,1) PRIMARY KEY,
    LdapGroup    NVARCHAR(256) NOT NULL UNIQUE,
    ConsoleRole  NVARCHAR(64)  NOT NULL,
    CreatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* ---- Local (break-glass) accounts ------------------------ */
/* Passwords are PBKDF2 salted hashes - never plain text.     */
IF OBJECT_ID('dbo.LocalAccounts') IS NULL
CREATE TABLE dbo.LocalAccounts (
    Id           INT IDENTITY(1,1) PRIMARY KEY,
    Username     NVARCHAR(128) NOT NULL UNIQUE,
    ConsoleRole  NVARCHAR(64)  NOT NULL,
    PwHash       NVARCHAR(512) NOT NULL,
    PwSalt       NVARCHAR(256) NOT NULL,
    Iterations   INT           NOT NULL DEFAULT 120000,
    Enabled      BIT           NOT NULL DEFAULT 1,
    BuiltIn      BIT           NOT NULL DEFAULT 0,
    CreatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* MFA (TOTP) columns - added via idempotent ALTER so re-running this
   schema against an existing install (Invoke-DbMigrate) is safe. */
IF COL_LENGTH('dbo.LocalAccounts', 'MfaEnabled') IS NULL
ALTER TABLE dbo.LocalAccounts ADD MfaEnabled BIT NOT NULL DEFAULT 0;
GO
IF COL_LENGTH('dbo.LocalAccounts', 'MfaSecret') IS NULL
ALTER TABLE dbo.LocalAccounts ADD MfaSecret NVARCHAR(64) NULL;
GO

/* ---- Audit trail ----------------------------------------- */
IF OBJECT_ID('dbo.AuditLog') IS NULL
CREATE TABLE dbo.AuditLog (
    Id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    [Time]       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    Actor        NVARCHAR(128) NOT NULL,
    Action       NVARCHAR(256) NOT NULL,
    Target       NVARCHAR(256) NULL,
    Result       NVARCHAR(32)  NOT NULL,        -- Success | Denied | Warning | Error
    Kind         NVARCHAR(32)  NULL,            -- auth | user | pw | lock | sync | audit | cert
    Detail       NVARCHAR(MAX) NULL,
    SourceIp     NVARCHAR(64)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AuditLog_Time' AND object_id = OBJECT_ID('dbo.AuditLog'))
    CREATE INDEX IX_AuditLog_Time ON dbo.AuditLog ([Time] DESC);
GO

/* ---- Scheduled job run history --------------------------- */
IF OBJECT_ID('dbo.JobRuns') IS NULL
CREATE TABLE dbo.JobRuns (
    Id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    JobName      NVARCHAR(128) NOT NULL,
    StartedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    FinishedAt   DATETIME2     NULL,
    Status       NVARCHAR(32)  NOT NULL DEFAULT 'Running',
    Detail       NVARCHAR(MAX) NULL
);
GO

/* ---- API sessions (bearer tokens) ------------------------ */
IF OBJECT_ID('dbo.Sessions') IS NULL
CREATE TABLE dbo.Sessions (
    Token        NVARCHAR(128) NOT NULL PRIMARY KEY,
    Username     NVARCHAR(128) NOT NULL,
    ConsoleRole  NVARCHAR(64)  NOT NULL,
    IsLocal      BIT           NOT NULL DEFAULT 0,
    CreatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    ExpiresAt    DATETIME2     NOT NULL
);
GO

/* ---- vCenter / ESXi connections + permission snapshots ---- */
/* Password is DPAPI-encrypted (Secrets.psm1's Protect-Secret/Unprotect-Secret),
   same as every other credential this app stores - never plain text. */
IF OBJECT_ID('dbo.VCenterConnections') IS NULL
CREATE TABLE dbo.VCenterConnections (
    Id           INT IDENTITY(1,1) PRIMARY KEY,
    Server       NVARCHAR(256) NOT NULL UNIQUE,
    Username     NVARCHAR(256) NOT NULL,
    PasswordCipher NVARCHAR(1024) NOT NULL,
    Enabled      BIT           NOT NULL DEFAULT 1,
    AllowUntrustedCert BIT     NOT NULL DEFAULT 0,  -- explicit opt-in only, e.g. self-signed lab certs
    LastSyncAt   DATETIME2     NULL,
    LastResult   NVARCHAR(32)  NULL,      -- 'Success' | 'Error'
    LastDetail   NVARCHAR(1024) NULL,
    CreatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* One row per (connection, sync run, principal+entity) - a full permission
   snapshot each sync, timestamped, so past syncs stay queryable for trend/
   audit purposes instead of only ever showing the latest state. */
IF OBJECT_ID('dbo.VCenterPermissions') IS NULL
CREATE TABLE dbo.VCenterPermissions (
    Id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    ConnectionId INT           NOT NULL,
    SyncId       UNIQUEIDENTIFIER NOT NULL,   -- groups all rows from the same sync run
    Principal    NVARCHAR(256) NOT NULL,
    Role         NVARCHAR(128) NOT NULL,
    Entity       NVARCHAR(512) NOT NULL,
    EntityType   NVARCHAR(64)  NULL,
    Propagate    BIT           NOT NULL DEFAULT 0,
    IsGroup      BIT           NOT NULL DEFAULT 0,
    CapturedAt   DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_VCenterPermissions_Sync' AND object_id = OBJECT_ID('dbo.VCenterPermissions'))
CREATE INDEX IX_VCenterPermissions_Sync ON dbo.VCenterPermissions(ConnectionId, SyncId, CapturedAt DESC);
GO

/* ---- Seed defaults (idempotent) -------------------------- */
/* RequireSecurityGroup/AccessSecurityGroup/RequireMfa/AllowSsoSignIn were
   removed from this seed list (3.35.0) - leftovers from the pre-3.32.0
   access-control design that nothing in DSMT_Api.ps1 has read since the
   single-list redesign (RequireSecurityGroup/AccessSecurityGroup) and the
   real MFA/SSO implementation (RequireMfa/AllowSsoSignIn -> superseded by
   dbo.LocalAccounts.MfaEnabled and Config.Directory.SsoEnabled). Existing
   installs keep whatever rows they already have - this only stops NEW
   installs from getting dead, misleading keys. */
MERGE dbo.Config AS t
USING (VALUES
    ('SchemaVersion','15'),
    ('ADConnectServer','ADC-SYNC-01'),
    ('ContractorExpectedAdminOU','OU=AdminAccounts,OU=Companies,DC=lab,DC=local'),
    ('ContractorExpectedSupportOU','OU=SupportAccounts,OU=Companies,DC=lab,DC=local'),
    ('CaConfigString','CA-01.lab.local\lab-Enterprise-CA'),
    ('SecretProvider','Windows DPAPI (machine)')
) AS s([Key],[Value])
ON t.[Key] = s.[Key]
WHEN NOT MATCHED THEN INSERT([Key],[Value]) VALUES(s.[Key],s.[Value]);
GO

MERGE dbo.RoleMappings AS t
USING (VALUES
    ('SG-SystemTeam-Admins','System Administrator'),
    ('SG-DSMT-Access','Operator'),
    ('SG-PasswordReset-Operators','Helpdesk Operator'),
    ('SG-ReadOnly-Auditors','Read-only')
) AS s(LdapGroup,ConsoleRole)
ON t.LdapGroup = s.LdapGroup
WHEN NOT MATCHED THEN INSERT(LdapGroup,ConsoleRole) VALUES(s.LdapGroup,s.ConsoleRole);
GO

PRINT 'DSMTOOL schema ready.';
GO
