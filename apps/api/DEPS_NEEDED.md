# npm dependencies for other lanes

Lane A owns `apps/api/package.json`. Other lanes append packages here; Lane A merges them into `package.json` before cutover.

## Lane B — mobile auth routes + libs

**Delivered** (SIWA + username only; password/OTP helpers dropped):

- `jose` `^5.10.0` — `lib/apple-id-token.ts`
- `zod` `^3.23.8` — `lib/validations-mobile-auth.ts`

Not needed: `bcryptjs` (no `authenticateMobileUser` / login routes ported).

## Lane C — settlement engine + routes

**Delivered** (`lib/settlement/**` + 6 route handlers; mobile session only):

- `pusher` `^5.2.0` — `lib/settlement/outbox/pusher.ts` (private-channel auth + outbox publish)

Not needed by settlement: extra `zod` (command validation is inline; Lane B `zod` covers auth).

## Lane D — mobile group/expense APIs

_Add if needed beyond B/C:_

- `zod` — group/expense request validation (`validations-mobile-ledger.ts`); shares with Lane B if not already merged

## Merged into package.json

| Package | Lane | Version (match current app) | Status |
|---------|------|---------------------------|--------|
| `jose` | B | `^5.10.0` | merged (Lane A, 2026-07-30) |
| `zod` | B | `^3.23.8` | merged (Lane A, 2026-07-30) |
| `pusher` | C | `^5.2.0` | merged (Lane A, 2026-07-30) |
| `bcryptjs` | A | `^2.4.3` | merged (devDep; `prisma/seed.ts` only) |
