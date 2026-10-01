-- Server-level logins, one per service; each service's migrator maps its login into its own database only.
IF SUSER_ID(N'placement_app') IS NULL CREATE LOGIN placement_app WITH PASSWORD = N'$(PLACEMENT_DB_PASSWORD)', CHECK_POLICY = ON;
IF SUSER_ID(N'wallet_app') IS NULL CREATE LOGIN wallet_app WITH PASSWORD = N'$(WALLET_DB_PASSWORD)', CHECK_POLICY = ON;
IF SUSER_ID(N'settlement_app') IS NULL CREATE LOGIN settlement_app WITH PASSWORD = N'$(SETTLEMENT_DB_PASSWORD)', CHECK_POLICY = ON;
IF SUSER_ID(N'payout_app') IS NULL CREATE LOGIN payout_app WITH PASSWORD = N'$(PAYOUT_DB_PASSWORD)', CHECK_POLICY = ON;
IF SUSER_ID(N'identity_app') IS NULL CREATE LOGIN identity_app WITH PASSWORD = N'$(IDENTITY_DB_PASSWORD)', CHECK_POLICY = ON;
IF SUSER_ID(N'compliance_app') IS NULL CREATE LOGIN compliance_app WITH PASSWORD = N'$(COMPLIANCE_DB_PASSWORD)', CHECK_POLICY = ON;
