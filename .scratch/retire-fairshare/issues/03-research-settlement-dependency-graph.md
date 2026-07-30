# Research FairShare settlement dependency graph

Type: research
Status: resolved
Blocked by:

## Question

What exact routes, libs, Prisma models, and env vars does Shared Settle Up + mobile SIWA/username auth need from FairShare?

## Answer

Full write-up: [research-api-surface.md](../research-api-surface.md) ([Research settlement API deps](c86e352d-59eb-4e38-a21f-07ec8190f33f)).

**Headlines:**
1. **Routes:** SIWA/username (`/api/mobile/auth/apple|me|username`) + settle-up/settlements/settings/realtime/auth + `/api/health`.
2. **Gap:** iOS calls `.../settle-up/transfers/:id/explanation` — **not implemented** in FairShare.
3. **Libs:** `lib/settlement/**` (skip legacy/backfill) + mobile auth/apple/username/prisma; drop NextAuth web fallback on move.
4. **Prisma:** Settlement reads `Expense`/`ExpenseSplit`/`GroupMember` from DB even without moving group/expense HTTP APIs — empty DB ⇒ empty settle plans.
5. **Env:** `DATABASE_URL`, `MOBILE_JWT_SECRET`, `IOS_BUNDLE_ID`/`APPLE_CLIENT_ID`, optional Pusher set.
6. **Main risk:** Moving settle-up HTTP alone without a path to populate Postgres group/expense rows (CloudKit-only data) leaves Shared Settle Up empty for linked `serverGroupId`s.

## Comments

- Research completed 2026-07-30.
