-- Add mobile-first auth/profile fields.
ALTER TABLE "User"
ADD COLUMN "phone" TEXT,
ADD COLUMN "preferredName" TEXT,
ADD COLUMN "upiID" TEXT;

CREATE UNIQUE INDEX "User_phone_key" ON "User"("phone");
CREATE INDEX "User_phone_idx" ON "User"("phone");

-- Store short-lived one-time-passcode challenges for email/phone auth.
CREATE TABLE "MobileOTPChallenge" (
    "id" TEXT NOT NULL,
    "identifier" TEXT NOT NULL,
    "identifierType" TEXT NOT NULL,
    "codeHash" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumedAt" TIMESTAMP(3),
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MobileOTPChallenge_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "MobileOTPChallenge_identifier_idx" ON "MobileOTPChallenge"("identifier");
CREATE INDEX "MobileOTPChallenge_expiresAt_idx" ON "MobileOTPChallenge"("expiresAt");
