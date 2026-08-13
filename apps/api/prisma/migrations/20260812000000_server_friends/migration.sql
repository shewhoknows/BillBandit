-- Server-authoritative friend invitations and normalized friendship pairs.
--
-- A friendship is one unordered account pair. Existing reverse-direction rows
-- are merged before the direction constraint is added. ACCEPTED wins over
-- PENDING, and PENDING wins over REJECTED, so this migration does not hide an
-- already accepted friend.

CREATE TABLE IF NOT EXISTS "FriendInvitation" (
    "id" TEXT NOT NULL,
    "inviterId" TEXT NOT NULL,
    "code" VARCHAR(5) NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "FriendInvitation_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "FriendInvitation_inviterId_key"
    ON "FriendInvitation"("inviterId");
CREATE UNIQUE INDEX IF NOT EXISTS "FriendInvitation_code_key"
    ON "FriendInvitation"("code");
CREATE INDEX IF NOT EXISTS "FriendInvitation_expiresAt_idx"
    ON "FriendInvitation"("expiresAt");

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'FriendInvitation_code_format_check'
          AND conrelid = '"FriendInvitation"'::regclass
    ) THEN
        ALTER TABLE "FriendInvitation"
            ADD CONSTRAINT "FriendInvitation_code_format_check"
            CHECK ("code" ~ '^[A-HJ-NP-Z2-9]{5}$');
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'FriendInvitation_inviterId_fkey'
          AND conrelid = '"FriendInvitation"'::regclass
    ) THEN
        ALTER TABLE "FriendInvitation"
            ADD CONSTRAINT "FriendInvitation_inviterId_fkey"
            FOREIGN KEY ("inviterId") REFERENCES "User"("id")
            ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
END $$;

-- Keep failed claim counts in PostgreSQL so rate limits work across API
-- processes and restarts.
CREATE TABLE IF NOT EXISTS "FriendClaimRateLimit" (
    "accountId" TEXT NOT NULL,
    "windowStartedAt" TIMESTAMP(3) NOT NULL,
    "failureCount" INTEGER NOT NULL DEFAULT 0,
    "blockedUntil" TIMESTAMP(3),
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "FriendClaimRateLimit_pkey" PRIMARY KEY ("accountId")
);

CREATE INDEX IF NOT EXISTS "FriendClaimRateLimit_blockedUntil_idx"
    ON "FriendClaimRateLimit"("blockedUntil");

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'FriendClaimRateLimit_accountId_fkey'
          AND conrelid = '"FriendClaimRateLimit"'::regclass
    ) THEN
        ALTER TABLE "FriendClaimRateLimit"
            ADD CONSTRAINT "FriendClaimRateLimit_accountId_fkey"
            FOREIGN KEY ("accountId") REFERENCES "User"("id")
            ON DELETE CASCADE ON UPDATE CASCADE;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'FriendClaimRateLimit_failureCount_check'
          AND conrelid = '"FriendClaimRateLimit"'::regclass
    ) THEN
        ALTER TABLE "FriendClaimRateLimit"
            ADD CONSTRAINT "FriendClaimRateLimit_failureCount_check"
            CHECK ("failureCount" >= 0);
    END IF;
END $$;

-- Self-friendships cannot represent a useful connection and would violate the
-- normalized direction invariant.
DELETE FROM "Friendship" WHERE "fromId" = "toId";

WITH ranked AS (
    SELECT
        "id",
        ROW_NUMBER() OVER (
            PARTITION BY LEAST("fromId", "toId"), GREATEST("fromId", "toId")
            ORDER BY
                CASE "status"
                    WHEN 'ACCEPTED' THEN 0
                    WHEN 'PENDING' THEN 1
                    ELSE 2
                END,
                "createdAt" ASC,
                "id" ASC
        ) AS rank
    FROM "Friendship"
)
DELETE FROM "Friendship" AS friendship
USING ranked
WHERE friendship."id" = ranked."id" AND ranked.rank > 1;

UPDATE "Friendship"
SET
    "fromId" = LEAST("fromId", "toId"),
    "toId" = GREATEST("fromId", "toId");

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'Friendship_normalized_direction_check'
          AND conrelid = '"Friendship"'::regclass
    ) THEN
        ALTER TABLE "Friendship"
            ADD CONSTRAINT "Friendship_normalized_direction_check"
            CHECK ("fromId" < "toId");
    END IF;
END $$;
