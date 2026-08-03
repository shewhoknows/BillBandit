-- T-02: exact-money authority and the generic ledger import/idempotency substrate.
--
-- This migration is deliberately expand-only. Legacy DOUBLE PRECISION columns
-- remain in place, exact columns are filled only when the value is provably
-- representable, and every unresolved value is retained in MoneyMigrationIssue.

-- Generic state enums. The guards make this file safe to replay in a rehearsal
-- database or after an interrupted schema apply.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'LedgerOperationState') THEN
        CREATE TYPE "LedgerOperationState" AS ENUM ('PENDING', 'COMMITTED', 'FAILED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'LedgerImportState') THEN
        CREATE TYPE "LedgerImportState" AS ENUM ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'LedgerImportRecordState') THEN
        CREATE TYPE "LedgerImportRecordState" AS ENUM ('PENDING', 'IMPORTED', 'QUARANTINED', 'SKIPPED');
    END IF;
END $$;

-- Keep the registry data-driven. Existing rows win, so rerunning this seed is
-- harmless and a changed registry version can be added later without editing
-- legacy rows.
INSERT INTO "CurrencyExponentRegistry" ("id", "version", "code", "exponent") VALUES
    ('ledger-currency-v1-USD', 1, 'USD', 2),
    ('ledger-currency-v1-EUR', 1, 'EUR', 2),
    ('ledger-currency-v1-GBP', 1, 'GBP', 2),
    ('ledger-currency-v1-JPY', 1, 'JPY', 0),
    ('ledger-currency-v1-CAD', 1, 'CAD', 2),
    ('ledger-currency-v1-AUD', 1, 'AUD', 2),
    ('ledger-currency-v1-INR', 1, 'INR', 2),
    ('ledger-currency-v1-CNY', 1, 'CNY', 2),
    ('ledger-currency-v1-BRL', 1, 'BRL', 2),
    ('ledger-currency-v1-MXN', 1, 'MXN', 2),
    ('ledger-currency-v1-KWD', 1, 'KWD', 3),
    ('ledger-currency-v1-BHD', 1, 'BHD', 3),
    ('ledger-currency-v1-OMR', 1, 'OMR', 3)
ON CONFLICT ("version", "code") DO NOTHING;

CREATE TABLE IF NOT EXISTS "LedgerOperation" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "groupId" TEXT,
    "operationKey" TEXT NOT NULL,
    "requestHash" TEXT NOT NULL,
    "expectedRevision" INTEGER,
    "resultRevision" INTEGER,
    "resultRecordId" TEXT,
    "state" "LedgerOperationState" NOT NULL DEFAULT 'PENDING',
    "failureCode" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "completedAt" TIMESTAMP(3),

    CONSTRAINT "LedgerOperation_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "LedgerOperation_accountId_operationKey_key"
    ON "LedgerOperation" ("accountId", "operationKey");
CREATE INDEX IF NOT EXISTS "LedgerOperation_accountId_idx"
    ON "LedgerOperation" ("accountId");
CREATE INDEX IF NOT EXISTS "LedgerOperation_groupId_idx"
    ON "LedgerOperation" ("groupId");

CREATE TABLE IF NOT EXISTS "LedgerImport" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "sourceSystem" TEXT NOT NULL,
    "sourceKey" TEXT NOT NULL,
    "state" "LedgerImportState" NOT NULL DEFAULT 'PENDING',
    "sourceChecksum" TEXT,
    "failureReason" TEXT,
    "startedAt" TIMESTAMP(3),
    "completedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "LedgerImport_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "LedgerImport_accountId_sourceSystem_sourceKey_key"
    ON "LedgerImport" ("accountId", "sourceSystem", "sourceKey");
CREATE INDEX IF NOT EXISTS "LedgerImport_accountId_state_idx"
    ON "LedgerImport" ("accountId", "state");

CREATE TABLE IF NOT EXISTS "LedgerImportRecord" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "importId" TEXT NOT NULL,
    "sourceSystem" TEXT NOT NULL,
    "sourceRecordKey" TEXT NOT NULL,
    "sourceRecordType" TEXT NOT NULL,
    "payload" JSONB,
    "payloadChecksum" TEXT,
    "state" "LedgerImportRecordState" NOT NULL DEFAULT 'PENDING',
    "targetType" TEXT,
    "targetId" TEXT,
    "quarantineReason" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "LedgerImportRecord_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "LedgerImportRecord_accountId_sourceSystem_sourceRecordKey_key"
    ON "LedgerImportRecord" ("accountId", "sourceSystem", "sourceRecordKey");
CREATE UNIQUE INDEX IF NOT EXISTS "LedgerImportRecord_importId_sourceRecordKey_key"
    ON "LedgerImportRecord" ("importId", "sourceRecordKey");
CREATE INDEX IF NOT EXISTS "LedgerImportRecord_accountId_state_idx"
    ON "LedgerImportRecord" ("accountId", "state");
CREATE INDEX IF NOT EXISTS "LedgerImportRecord_importId_state_idx"
    ON "LedgerImportRecord" ("importId", "state");

CREATE TABLE IF NOT EXISTS "ExternalIdentity" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "subject" TEXT NOT NULL,
    "metadata" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ExternalIdentity_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "ExternalIdentity_provider_subject_key"
    ON "ExternalIdentity" ("provider", "subject");
CREATE UNIQUE INDEX IF NOT EXISTS "ExternalIdentity_accountId_provider_key"
    ON "ExternalIdentity" ("accountId", "provider");
CREATE INDEX IF NOT EXISTS "ExternalIdentity_accountId_idx"
    ON "ExternalIdentity" ("accountId");

-- Foreign keys are guarded because PostgreSQL has no ALTER TABLE
-- ADD CONSTRAINT IF NOT EXISTS form.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LedgerOperation_accountId_fkey') THEN
        ALTER TABLE "LedgerOperation"
            ADD CONSTRAINT "LedgerOperation_accountId_fkey"
            FOREIGN KEY ("accountId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LedgerOperation_groupId_fkey') THEN
        ALTER TABLE "LedgerOperation"
            ADD CONSTRAINT "LedgerOperation_groupId_fkey"
            FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LedgerImport_accountId_fkey') THEN
        ALTER TABLE "LedgerImport"
            ADD CONSTRAINT "LedgerImport_accountId_fkey"
            FOREIGN KEY ("accountId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LedgerImportRecord_accountId_fkey') THEN
        ALTER TABLE "LedgerImportRecord"
            ADD CONSTRAINT "LedgerImportRecord_accountId_fkey"
            FOREIGN KEY ("accountId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LedgerImportRecord_importId_fkey') THEN
        ALTER TABLE "LedgerImportRecord"
            ADD CONSTRAINT "LedgerImportRecord_importId_fkey"
            FOREIGN KEY ("importId") REFERENCES "LedgerImport"("id") ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ExternalIdentity_accountId_fkey') THEN
        ALTER TABLE "ExternalIdentity"
            ADD CONSTRAINT "ExternalIdentity_accountId_fkey"
            FOREIGN KEY ("accountId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
END $$;

-- Expense amounts. The registry's latest version for a code supplies the
-- exponent; no currency default is inferred here. A decimal value is accepted
-- only when multiplying by 10^exponent produces an integer in BIGINT range.
WITH candidates AS (
    SELECT
        e."id" AS record_id,
        e."groupId" AS group_id,
        e."currency" AS currency_code,
        e."amount"::text AS amount_text,
        e."amountMinorUnits" AS exact_minor,
        e."currencyExponent" AS exact_exponent,
        r."exponent" AS registry_exponent,
        CASE
            WHEN e."amount" IS NULL OR lower(e."amount"::text) IN ('nan', 'infinity', '-infinity') THEN NULL
            ELSE e."amount"::text::numeric
        END AS decimal_amount
    FROM "Expense" e
    LEFT JOIN LATERAL (
        SELECT cer."exponent"
        FROM "CurrencyExponentRegistry" cer
        WHERE upper(trim(cer."code")) = upper(trim(e."currency"))
        ORDER BY cer."version" DESC
        LIMIT 1
    ) r ON true
), prepared AS (
    SELECT c.*, CASE
        WHEN c.decimal_amount IS NULL OR c.registry_exponent IS NULL THEN NULL
        ELSE c.decimal_amount * power(10::numeric, c.registry_exponent)
    END AS scaled_amount
    FROM candidates c
), converted AS (
    SELECT record_id, registry_exponent, scaled_amount::bigint AS minor_units
    FROM prepared
    WHERE exact_minor IS NULL
      AND exact_exponent IS NULL
      AND registry_exponent >= 0
      AND scaled_amount = trunc(scaled_amount)
      AND scaled_amount BETWEEN (-9223372036854775808)::numeric AND 9223372036854775807::numeric
)
UPDATE "Expense" e
SET "amountMinorUnits" = c.minor_units,
    "currencyExponent" = c.registry_exponent
FROM converted c
WHERE e."id" = c.record_id
  AND e."amountMinorUnits" IS NULL
  AND e."currencyExponent" IS NULL;

WITH candidates AS (
    SELECT
        e."id" AS record_id,
        e."groupId" AS group_id,
        e."currency" AS currency_code,
        e."amount"::text AS amount_text,
        e."amountMinorUnits" AS exact_minor,
        e."currencyExponent" AS exact_exponent,
        r."exponent" AS registry_exponent,
        CASE
            WHEN e."amount" IS NULL OR lower(e."amount"::text) IN ('nan', 'infinity', '-infinity') THEN NULL
            ELSE e."amount"::text::numeric
        END AS decimal_amount
    FROM "Expense" e
    LEFT JOIN LATERAL (
        SELECT cer."exponent"
        FROM "CurrencyExponentRegistry" cer
        WHERE upper(trim(cer."code")) = upper(trim(e."currency"))
        ORDER BY cer."version" DESC
        LIMIT 1
    ) r ON true
), prepared AS (
    SELECT c.*, CASE
        WHEN c.decimal_amount IS NULL OR c.registry_exponent IS NULL THEN NULL
        ELSE c.decimal_amount * power(10::numeric, c.registry_exponent)
    END AS scaled_amount
    FROM candidates c
), classified AS (
    SELECT p.*, CASE
        WHEN (p.exact_minor IS NULL) <> (p.exact_exponent IS NULL) THEN 'PARTIAL_EXACT_FIELDS'
        WHEN p.exact_minor IS NOT NULL AND p.exact_exponent IS NOT NULL
             AND (p.registry_exponent IS NULL OR p.exact_exponent <> p.registry_exponent OR p.exact_exponent < 0)
            THEN 'EXACT_EXPONENT_MISMATCH'
        WHEN p.exact_minor IS NOT NULL AND p.exact_exponent IS NOT NULL THEN NULL
        WHEN p.registry_exponent IS NULL THEN 'UNSUPPORTED_CURRENCY'
        WHEN p.decimal_amount IS NULL THEN 'INVALID_LEGACY_VALUE'
        WHEN p.registry_exponent < 0 THEN 'INVALID_CURRENCY_EXPONENT'
        WHEN p.scaled_amount < (-9223372036854775808)::numeric
          OR p.scaled_amount > 9223372036854775807::numeric THEN 'OUT_OF_RANGE'
        WHEN p.scaled_amount <> trunc(p.scaled_amount) THEN 'AMBIGUOUS_LEGACY_VALUE'
        ELSE NULL
    END AS reason
    FROM prepared p
)
INSERT INTO "MoneyMigrationIssue" ("id", "tableName", "recordId", "groupId", "currencyCode", "reason", "floatValue")
SELECT
    md5('money-migration:Expense:' || record_id || ':' || reason),
    'Expense',
    record_id,
    group_id,
    currency_code,
    reason,
    amount_text
FROM classified c
WHERE c.reason IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM "MoneyMigrationIssue" i
      WHERE i."tableName" = 'Expense'
        AND i."recordId" = c.record_id
        AND i."reason" = c.reason
  );

-- Expense splits inherit their currency and group from the parent expense.
WITH candidates AS (
    SELECT
        s."id" AS record_id,
        e."groupId" AS group_id,
        e."currency" AS currency_code,
        s."amount"::text AS amount_text,
        s."amountMinorUnits" AS exact_minor,
        s."currencyExponent" AS exact_exponent,
        r."exponent" AS registry_exponent,
        CASE
            WHEN s."amount" IS NULL OR lower(s."amount"::text) IN ('nan', 'infinity', '-infinity') THEN NULL
            ELSE s."amount"::text::numeric
        END AS decimal_amount
    FROM "ExpenseSplit" s
    JOIN "Expense" e ON e."id" = s."expenseId"
    LEFT JOIN LATERAL (
        SELECT cer."exponent"
        FROM "CurrencyExponentRegistry" cer
        WHERE upper(trim(cer."code")) = upper(trim(e."currency"))
        ORDER BY cer."version" DESC
        LIMIT 1
    ) r ON true
), prepared AS (
    SELECT c.*, CASE
        WHEN c.decimal_amount IS NULL OR c.registry_exponent IS NULL THEN NULL
        ELSE c.decimal_amount * power(10::numeric, c.registry_exponent)
    END AS scaled_amount
    FROM candidates c
), converted AS (
    SELECT record_id, registry_exponent, scaled_amount::bigint AS minor_units
    FROM prepared
    WHERE exact_minor IS NULL
      AND exact_exponent IS NULL
      AND registry_exponent >= 0
      AND scaled_amount = trunc(scaled_amount)
      AND scaled_amount BETWEEN (-9223372036854775808)::numeric AND 9223372036854775807::numeric
)
UPDATE "ExpenseSplit" s
SET "amountMinorUnits" = c.minor_units,
    "currencyExponent" = c.registry_exponent
FROM converted c
WHERE s."id" = c.record_id
  AND s."amountMinorUnits" IS NULL
  AND s."currencyExponent" IS NULL;

WITH candidates AS (
    SELECT
        s."id" AS record_id,
        e."groupId" AS group_id,
        e."currency" AS currency_code,
        s."amount"::text AS amount_text,
        s."amountMinorUnits" AS exact_minor,
        s."currencyExponent" AS exact_exponent,
        r."exponent" AS registry_exponent,
        CASE
            WHEN s."amount" IS NULL OR lower(s."amount"::text) IN ('nan', 'infinity', '-infinity') THEN NULL
            ELSE s."amount"::text::numeric
        END AS decimal_amount
    FROM "ExpenseSplit" s
    JOIN "Expense" e ON e."id" = s."expenseId"
    LEFT JOIN LATERAL (
        SELECT cer."exponent"
        FROM "CurrencyExponentRegistry" cer
        WHERE upper(trim(cer."code")) = upper(trim(e."currency"))
        ORDER BY cer."version" DESC
        LIMIT 1
    ) r ON true
), prepared AS (
    SELECT c.*, CASE
        WHEN c.decimal_amount IS NULL OR c.registry_exponent IS NULL THEN NULL
        ELSE c.decimal_amount * power(10::numeric, c.registry_exponent)
    END AS scaled_amount
    FROM candidates c
), classified AS (
    SELECT p.*, CASE
        WHEN (p.exact_minor IS NULL) <> (p.exact_exponent IS NULL) THEN 'PARTIAL_EXACT_FIELDS'
        WHEN p.exact_minor IS NOT NULL AND p.exact_exponent IS NOT NULL
             AND (p.registry_exponent IS NULL OR p.exact_exponent <> p.registry_exponent OR p.exact_exponent < 0)
            THEN 'EXACT_EXPONENT_MISMATCH'
        WHEN p.exact_minor IS NOT NULL AND p.exact_exponent IS NOT NULL THEN NULL
        WHEN p.registry_exponent IS NULL THEN 'UNSUPPORTED_CURRENCY'
        WHEN p.decimal_amount IS NULL THEN 'INVALID_LEGACY_VALUE'
        WHEN p.registry_exponent < 0 THEN 'INVALID_CURRENCY_EXPONENT'
        WHEN p.scaled_amount < (-9223372036854775808)::numeric
          OR p.scaled_amount > 9223372036854775807::numeric THEN 'OUT_OF_RANGE'
        WHEN p.scaled_amount <> trunc(p.scaled_amount) THEN 'AMBIGUOUS_LEGACY_VALUE'
        ELSE NULL
    END AS reason
    FROM prepared p
)
INSERT INTO "MoneyMigrationIssue" ("id", "tableName", "recordId", "groupId", "currencyCode", "reason", "floatValue")
SELECT
    md5('money-migration:ExpenseSplit:' || record_id || ':' || reason),
    'ExpenseSplit',
    record_id,
    group_id,
    currency_code,
    reason,
    amount_text
FROM classified c
WHERE c.reason IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM "MoneyMigrationIssue" i
      WHERE i."tableName" = 'ExpenseSplit'
        AND i."recordId" = c.record_id
        AND i."reason" = c.reason
  );

-- Transactions carry their own currency and group.
WITH candidates AS (
    SELECT
        t."id" AS record_id,
        t."groupId" AS group_id,
        t."currency" AS currency_code,
        t."amount"::text AS amount_text,
        t."amountMinorUnits" AS exact_minor,
        t."currencyExponent" AS exact_exponent,
        r."exponent" AS registry_exponent,
        CASE
            WHEN t."amount" IS NULL OR lower(t."amount"::text) IN ('nan', 'infinity', '-infinity') THEN NULL
            ELSE t."amount"::text::numeric
        END AS decimal_amount
    FROM "Transaction" t
    LEFT JOIN LATERAL (
        SELECT cer."exponent"
        FROM "CurrencyExponentRegistry" cer
        WHERE upper(trim(cer."code")) = upper(trim(t."currency"))
        ORDER BY cer."version" DESC
        LIMIT 1
    ) r ON true
), prepared AS (
    SELECT c.*, CASE
        WHEN c.decimal_amount IS NULL OR c.registry_exponent IS NULL THEN NULL
        ELSE c.decimal_amount * power(10::numeric, c.registry_exponent)
    END AS scaled_amount
    FROM candidates c
), converted AS (
    SELECT record_id, registry_exponent, scaled_amount::bigint AS minor_units
    FROM prepared
    WHERE exact_minor IS NULL
      AND exact_exponent IS NULL
      AND registry_exponent >= 0
      AND scaled_amount = trunc(scaled_amount)
      AND scaled_amount BETWEEN (-9223372036854775808)::numeric AND 9223372036854775807::numeric
)
UPDATE "Transaction" t
SET "amountMinorUnits" = c.minor_units,
    "currencyExponent" = c.registry_exponent
FROM converted c
WHERE t."id" = c.record_id
  AND t."amountMinorUnits" IS NULL
  AND t."currencyExponent" IS NULL;

WITH candidates AS (
    SELECT
        t."id" AS record_id,
        t."groupId" AS group_id,
        t."currency" AS currency_code,
        t."amount"::text AS amount_text,
        t."amountMinorUnits" AS exact_minor,
        t."currencyExponent" AS exact_exponent,
        r."exponent" AS registry_exponent,
        CASE
            WHEN t."amount" IS NULL OR lower(t."amount"::text) IN ('nan', 'infinity', '-infinity') THEN NULL
            ELSE t."amount"::text::numeric
        END AS decimal_amount
    FROM "Transaction" t
    LEFT JOIN LATERAL (
        SELECT cer."exponent"
        FROM "CurrencyExponentRegistry" cer
        WHERE upper(trim(cer."code")) = upper(trim(t."currency"))
        ORDER BY cer."version" DESC
        LIMIT 1
    ) r ON true
), prepared AS (
    SELECT c.*, CASE
        WHEN c.decimal_amount IS NULL OR c.registry_exponent IS NULL THEN NULL
        ELSE c.decimal_amount * power(10::numeric, c.registry_exponent)
    END AS scaled_amount
    FROM candidates c
), classified AS (
    SELECT p.*, CASE
        WHEN (p.exact_minor IS NULL) <> (p.exact_exponent IS NULL) THEN 'PARTIAL_EXACT_FIELDS'
        WHEN p.exact_minor IS NOT NULL AND p.exact_exponent IS NOT NULL
             AND (p.registry_exponent IS NULL OR p.exact_exponent <> p.registry_exponent OR p.exact_exponent < 0)
            THEN 'EXACT_EXPONENT_MISMATCH'
        WHEN p.exact_minor IS NOT NULL AND p.exact_exponent IS NOT NULL THEN NULL
        WHEN p.registry_exponent IS NULL THEN 'UNSUPPORTED_CURRENCY'
        WHEN p.decimal_amount IS NULL THEN 'INVALID_LEGACY_VALUE'
        WHEN p.registry_exponent < 0 THEN 'INVALID_CURRENCY_EXPONENT'
        WHEN p.scaled_amount < (-9223372036854775808)::numeric
          OR p.scaled_amount > 9223372036854775807::numeric THEN 'OUT_OF_RANGE'
        WHEN p.scaled_amount <> trunc(p.scaled_amount) THEN 'AMBIGUOUS_LEGACY_VALUE'
        ELSE NULL
    END AS reason
    FROM prepared p
)
INSERT INTO "MoneyMigrationIssue" ("id", "tableName", "recordId", "groupId", "currencyCode", "reason", "floatValue")
SELECT
    md5('money-migration:Transaction:' || record_id || ':' || reason),
    'Transaction',
    record_id,
    group_id,
    currency_code,
    reason,
    amount_text
FROM classified c
WHERE c.reason IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM "MoneyMigrationIssue" i
      WHERE i."tableName" = 'Transaction'
        AND i."recordId" = c.record_id
        AND i."reason" = c.reason
  );
