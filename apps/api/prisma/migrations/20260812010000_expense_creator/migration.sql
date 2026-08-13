-- Keep the account that created an expense separate from the payer. This lets
-- activity text name the exact actor. Existing rows use the payer as the best
-- available historical value.

ALTER TABLE "Expense"
    ADD COLUMN IF NOT EXISTS "createdById" TEXT;

UPDATE "Expense"
SET "createdById" = "paidById"
WHERE "createdById" IS NULL;

CREATE INDEX IF NOT EXISTS "Expense_createdById_idx"
    ON "Expense"("createdById");

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'Expense_createdById_fkey'
          AND conrelid = '"Expense"'::regclass
    ) THEN
        ALTER TABLE "Expense"
            ADD CONSTRAINT "Expense_createdById_fkey"
            FOREIGN KEY ("createdById") REFERENCES "User"("id")
            ON DELETE SET NULL ON UPDATE CASCADE;
    END IF;
END $$;
