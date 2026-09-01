ALTER TABLE "Group"
ADD COLUMN "finalizedAt" TIMESTAMP(3),
ADD COLUMN "finalizedById" TEXT;

CREATE INDEX "Group_finalizedById_idx" ON "Group"("finalizedById");

ALTER TABLE "Group" ADD CONSTRAINT "Group_finalizedById_fkey" FOREIGN KEY ("finalizedById") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
