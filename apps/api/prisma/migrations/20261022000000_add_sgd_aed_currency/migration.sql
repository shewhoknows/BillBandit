-- Add SGD and AED to the existing versioned registry without changing historical rows.
INSERT INTO "CurrencyExponentRegistry" ("id", "version", "code", "exponent")
VALUES
  ('ledger-currency-v1-SGD', 1, 'SGD', 2),
  ('ledger-currency-v1-AED', 1, 'AED', 2)
ON CONFLICT ("version", "code") DO NOTHING;
