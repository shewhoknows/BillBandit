-- The currency a person sees totals and estimates in. Null until they choose.
ALTER TABLE "User" ADD COLUMN "defaultCurrency" TEXT;
