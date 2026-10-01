-- CI fixture for the restore drill: a tiny ledger shaped like the wallet's, balanced, plus the drill's own database.
CREATE DATABASE SbWallet;
GO
USE SbWallet;
GO
CREATE SCHEMA wallet;
GO
CREATE TABLE wallet.Accounts (AccountId int PRIMARY KEY, Kind tinyint NOT NULL, Available bigint NOT NULL, Reserved bigint NOT NULL);
CREATE TABLE wallet.LedgerEntries (EntryId int IDENTITY PRIMARY KEY, AccountId int NOT NULL, Bucket tinyint NOT NULL, Amount bigint NOT NULL);
INSERT INTO wallet.Accounts VALUES (1, 1, 700, 300), (2, 3, 0, 0);
INSERT INTO wallet.LedgerEntries (AccountId, Bucket, Amount) VALUES (1, 1, 1000), (2, 1, -1000), (1, 1, -300), (1, 2, 300);
