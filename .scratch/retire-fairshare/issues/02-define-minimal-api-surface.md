# Define minimal API surface to move

Type: grilling
Status: resolved
Blocked by:

## Question

Given “settlement only, no web” + SIWA/username: which FairShare API routes and libs must move into `apps/api` so Shared Settle Up works end-to-end on BillBandit?

## Answer

(Round 2 — batch-grill-me, 2026-07-30)

Move:
- **Auth:** `/api/mobile/auth/apple|me|username` (+ libs: mobile-auth, apple-id-token, username-handle, prisma)
- **Settle:** settle-up, history, settlements, reversals, settlement-settings, realtime/auth (+ full `lib/settlement/**` except legacy/backfill)
- **Ledger population:** mobile **group/expense** APIs that write the Postgres rows settle-up reads
- **Ops:** `/api/health`
- **Shape:** API-only Next.js in `apps/api` (no FairShare web UI); drop NextAuth web fallback on move

Do **not** move FairShare web pages / Ink iOS.

See also [research-api-surface.md](../research-api-surface.md).
