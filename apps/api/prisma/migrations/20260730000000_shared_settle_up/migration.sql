-- Shared Settle Up: exact money, participants, settlement state

-- CreateEnum
CREATE TYPE "SettlementMode" AS ENUM ('DIRECT', 'SIMPLIFIED');
CREATE TYPE "ParticipantStatus" AS ENUM ('ACTIVE', 'DEPARTED');
CREATE TYPE "SettlementOutboxState" AS ENUM ('PENDING', 'LEASED', 'PUBLISHED', 'FAILED');

-- Group settlement fields
ALTER TABLE "Group" ADD COLUMN "simplifyDebts" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "Group" ADD COLUMN "settlementVersion" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Group" ADD COLUMN "hadOpenTransfers" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "Group" ADD COLUMN "settlementCompletedAt" TIMESTAMP(3);

-- Exact money columns (expand-only)
ALTER TABLE "Expense" ADD COLUMN "amountMinorUnits" BIGINT;
ALTER TABLE "Expense" ADD COLUMN "currencyExponent" INTEGER;
ALTER TABLE "ExpenseSplit" ADD COLUMN "amountMinorUnits" BIGINT;
ALTER TABLE "ExpenseSplit" ADD COLUMN "currencyExponent" INTEGER;
ALTER TABLE "Transaction" ADD COLUMN "amountMinorUnits" BIGINT;
ALTER TABLE "Transaction" ADD COLUMN "currencyExponent" INTEGER;

-- Transaction settlement links
ALTER TABLE "Transaction" ADD COLUMN "payerParticipantId" TEXT;
ALTER TABLE "Transaction" ADD COLUMN "recipientParticipantId" TEXT;
ALTER TABLE "Transaction" ADD COLUMN "actorUserId" TEXT;
ALTER TABLE "Transaction" ADD COLUMN "settlementMode" "SettlementMode";
ALTER TABLE "Transaction" ADD COLUMN "settlementGroupVersion" INTEGER;

-- Currency registry
CREATE TABLE "CurrencyExponentRegistry" (
    "id" TEXT NOT NULL,
    "version" INTEGER NOT NULL,
    "code" TEXT NOT NULL,
    "exponent" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "CurrencyExponentRegistry_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "CurrencyExponentRegistry_version_code_key" ON "CurrencyExponentRegistry"("version", "code");
CREATE INDEX "CurrencyExponentRegistry_code_idx" ON "CurrencyExponentRegistry"("code");

-- Migration issues
CREATE TABLE "MoneyMigrationIssue" (
    "id" TEXT NOT NULL,
    "tableName" TEXT NOT NULL,
    "recordId" TEXT NOT NULL,
    "groupId" TEXT,
    "currencyCode" TEXT,
    "reason" TEXT NOT NULL,
    "floatValue" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "MoneyMigrationIssue_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "MoneyMigrationIssue_groupId_idx" ON "MoneyMigrationIssue"("groupId");
CREATE INDEX "MoneyMigrationIssue_tableName_recordId_idx" ON "MoneyMigrationIssue"("tableName", "recordId");

-- Group participants
CREATE TABLE "GroupParticipant" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "displayName" TEXT NOT NULL,
    "status" "ParticipantStatus" NOT NULL DEFAULT 'ACTIVE',
    "joinedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "departedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "GroupParticipant_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "GroupParticipant_groupId_userId_key" ON "GroupParticipant"("groupId", "userId");
CREATE INDEX "GroupParticipant_groupId_idx" ON "GroupParticipant"("groupId");
CREATE INDEX "GroupParticipant_userId_idx" ON "GroupParticipant"("userId");
ALTER TABLE "GroupParticipant" ADD CONSTRAINT "GroupParticipant_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "GroupParticipant" ADD CONSTRAINT "GroupParticipant_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- Settlement allocations
CREATE TABLE "SettlementAllocation" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "transactionId" TEXT NOT NULL,
    "settlementVersion" INTEGER NOT NULL,
    "mode" "SettlementMode" NOT NULL,
    "algorithmVersion" INTEGER NOT NULL DEFAULT 1,
    "currencyCode" TEXT NOT NULL,
    "currencyExponent" INTEGER NOT NULL,
    "amountMinorUnits" BIGINT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SettlementAllocation_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "SettlementAllocation_transactionId_key" ON "SettlementAllocation"("transactionId");
CREATE INDEX "SettlementAllocation_groupId_idx" ON "SettlementAllocation"("groupId");
ALTER TABLE "SettlementAllocation" ADD CONSTRAINT "SettlementAllocation_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "SettlementAllocation" ADD CONSTRAINT "SettlementAllocation_transactionId_fkey" FOREIGN KEY ("transactionId") REFERENCES "Transaction"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

CREATE TABLE "SettlementAllocationPath" (
    "id" TEXT NOT NULL,
    "allocationId" TEXT NOT NULL,
    "sequence" INTEGER NOT NULL,
    "flowMinorUnits" BIGINT NOT NULL,
    "obligationComponentKey" TEXT NOT NULL,
    "payerParticipantId" TEXT NOT NULL,
    "recipientParticipantId" TEXT NOT NULL,
    CONSTRAINT "SettlementAllocationPath_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "SettlementAllocationPath_allocationId_idx" ON "SettlementAllocationPath"("allocationId");
ALTER TABLE "SettlementAllocationPath" ADD CONSTRAINT "SettlementAllocationPath_allocationId_fkey" FOREIGN KEY ("allocationId") REFERENCES "SettlementAllocation"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- Reversals
CREATE TABLE "SettlementReversal" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "transactionId" TEXT NOT NULL,
    "actorUserId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SettlementReversal_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "SettlementReversal_transactionId_key" ON "SettlementReversal"("transactionId");
CREATE INDEX "SettlementReversal_groupId_idx" ON "SettlementReversal"("groupId");
ALTER TABLE "SettlementReversal" ADD CONSTRAINT "SettlementReversal_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "SettlementReversal" ADD CONSTRAINT "SettlementReversal_transactionId_fkey" FOREIGN KEY ("transactionId") REFERENCES "Transaction"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "SettlementReversal" ADD CONSTRAINT "SettlementReversal_actorUserId_fkey" FOREIGN KEY ("actorUserId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- Setting audits
CREATE TABLE "SettlementSettingAudit" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "actorUserId" TEXT NOT NULL,
    "simplifyDebts" BOOLEAN NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SettlementSettingAudit_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "SettlementSettingAudit_groupId_createdAt_idx" ON "SettlementSettingAudit"("groupId", "createdAt");
ALTER TABLE "SettlementSettingAudit" ADD CONSTRAINT "SettlementSettingAudit_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "SettlementSettingAudit" ADD CONSTRAINT "SettlementSettingAudit_actorUserId_fkey" FOREIGN KEY ("actorUserId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- Idempotent operations
CREATE TABLE "IdempotentOperation" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "operationKey" TEXT NOT NULL,
    "requestHash" TEXT NOT NULL,
    "resultVersion" INTEGER NOT NULL,
    "resultRecordId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "IdempotentOperation_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "IdempotentOperation_groupId_operationKey_key" ON "IdempotentOperation"("groupId", "operationKey");
CREATE INDEX "IdempotentOperation_groupId_idx" ON "IdempotentOperation"("groupId");
ALTER TABLE "IdempotentOperation" ADD CONSTRAINT "IdempotentOperation_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- Version journal
CREATE TABLE "SettlementVersionJournal" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "version" INTEGER NOT NULL,
    "recordId" TEXT,
    "eventType" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SettlementVersionJournal_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "SettlementVersionJournal_groupId_version_key" ON "SettlementVersionJournal"("groupId", "version");
CREATE INDEX "SettlementVersionJournal_groupId_version_idx" ON "SettlementVersionJournal"("groupId", "version");
ALTER TABLE "SettlementVersionJournal" ADD CONSTRAINT "SettlementVersionJournal_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- Outbox
CREATE TABLE "SettlementOutbox" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "recordId" TEXT NOT NULL,
    "eventType" TEXT NOT NULL,
    "version" INTEGER NOT NULL,
    "state" "SettlementOutboxState" NOT NULL DEFAULT 'PENDING',
    "attemptCount" INTEGER NOT NULL DEFAULT 0,
    "nextAttemptAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "leaseOwner" TEXT,
    "leaseExpiresAt" TIMESTAMP(3),
    "publishedAt" TIMESTAMP(3),
    "failureCode" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SettlementOutbox_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "SettlementOutbox_groupId_version_key" ON "SettlementOutbox"("groupId", "version");
CREATE INDEX "SettlementOutbox_state_nextAttemptAt_idx" ON "SettlementOutbox"("state", "nextAttemptAt");
CREATE INDEX "SettlementOutbox_groupId_idx" ON "SettlementOutbox"("groupId");
ALTER TABLE "SettlementOutbox" ADD CONSTRAINT "SettlementOutbox_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- Transaction FKs
CREATE INDEX "Transaction_payerParticipantId_idx" ON "Transaction"("payerParticipantId");
CREATE INDEX "Transaction_recipientParticipantId_idx" ON "Transaction"("recipientParticipantId");
ALTER TABLE "Transaction" ADD CONSTRAINT "Transaction_payerParticipantId_fkey" FOREIGN KEY ("payerParticipantId") REFERENCES "GroupParticipant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "Transaction" ADD CONSTRAINT "Transaction_recipientParticipantId_fkey" FOREIGN KEY ("recipientParticipantId") REFERENCES "GroupParticipant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "Transaction" ADD CONSTRAINT "Transaction_actorUserId_fkey" FOREIGN KEY ("actorUserId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- Seed currency exponent registry v1
INSERT INTO "CurrencyExponentRegistry" ("id", "version", "code", "exponent") VALUES
  (gen_random_uuid()::text, 1, 'USD', 2),
  (gen_random_uuid()::text, 1, 'EUR', 2),
  (gen_random_uuid()::text, 1, 'GBP', 2),
  (gen_random_uuid()::text, 1, 'JPY', 0),
  (gen_random_uuid()::text, 1, 'CAD', 2),
  (gen_random_uuid()::text, 1, 'AUD', 2),
  (gen_random_uuid()::text, 1, 'INR', 2),
  (gen_random_uuid()::text, 1, 'CNY', 2),
  (gen_random_uuid()::text, 1, 'BRL', 2),
  (gen_random_uuid()::text, 1, 'MXN', 2),
  (gen_random_uuid()::text, 1, 'KWD', 3),
  (gen_random_uuid()::text, 1, 'BHD', 3),
  (gen_random_uuid()::text, 1, 'OMR', 3);

-- Backfill simplifyDebts for existing groups (already default true)
UPDATE "Group" SET "simplifyDebts" = true WHERE "simplifyDebts" IS NULL;
