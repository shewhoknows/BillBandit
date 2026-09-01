-- Usernames are nullable for existing accounts, but every claimed handle is
-- normalized and globally unique. The database check keeps direct writes from
-- bypassing the API's handle contract.
ALTER TABLE "User"
ADD COLUMN "username" TEXT;

CREATE UNIQUE INDEX "User_username_key" ON "User"("username");

ALTER TABLE "User"
ADD CONSTRAINT "User_username_format"
CHECK (
  "username" IS NULL OR
  "username" ~ '^[a-z][a-z0-9_]{1,18}[a-z0-9]$'
);
