CREATE TABLE "ReviewCodeRateLimit" (
    "key" TEXT NOT NULL,
    "windowStartedAt" TIMESTAMP(3) NOT NULL,
    "failureCount" INTEGER NOT NULL DEFAULT 0,
    "blockedUntil" TIMESTAMP(3),
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "ReviewCodeRateLimit_pkey" PRIMARY KEY ("key")
);
CREATE INDEX "ReviewCodeRateLimit_blockedUntil_idx" ON "ReviewCodeRateLimit"("blockedUntil");
