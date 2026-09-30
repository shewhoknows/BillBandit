-- Add VND to the existing versioned registry without changing historical rows.
INSERT INTO "CurrencyExponentRegistry" ("id", "version", "code", "exponent")
VALUES ('ledger-currency-v1-VND', 1, 'VND', 0)
ON CONFLICT ("version", "code") DO NOTHING;
