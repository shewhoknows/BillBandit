# FairShare → BillBandit: minimal API surface (settlement + SIWA/username)

Research date: 2026-07-30. Source: `/Users/prateekranka/Cowork/FairShare/apps/web`. iOS client: `/Users/prateekranka/Cowork/BillBandit-published/BillBandit`.

## 1. API routes (paths BillBandit calls today)

### Auth (required)
| Method | Path | FairShare route file |
|--------|------|----------------------|
| POST | `/api/mobile/auth/apple` | `app/api/mobile/auth/apple/route.ts` |
| GET | `/api/mobile/auth/me` | `app/api/mobile/auth/me/route.ts` |
| POST | `/api/mobile/auth/username` | `app/api/mobile/auth/username/route.ts` (claim) |
| PUT | `/api/mobile/auth/username` | same file (rename) |

### Shared Settle Up (required)
| Method | Path | FairShare route file |
|--------|------|----------------------|
| GET | `/api/groups/:id/settle-up` | `app/api/groups/[id]/settle-up/route.ts` |
| GET | `/api/groups/:id/settle-up/history` | `app/api/groups/[id]/settle-up/history/route.ts` |
| POST | `/api/groups/:id/settlements` | `app/api/groups/[id]/settlements/route.ts` |
| POST | `/api/groups/:id/settlements/:settlementId/reversals` | `app/api/groups/[id]/settlements/[settlementId]/reversals/route.ts` |
| PATCH | `/api/groups/:id/settlement-settings` | `app/api/groups/[id]/settlement-settings/route.ts` |
| POST | `/api/groups/:id/realtime/auth` | `app/api/groups/[id]/realtime/auth/route.ts` |

### Ops (recommended)
| Method | Path | File |
|--------|------|------|
| GET | `/api/health` | `app/api/health/route.ts` |

### Gap — iOS calls, FairShare has no route
| Method | Path | Status |
|--------|------|--------|
| GET | `/api/groups/:id/settle-up/transfers/:transferId/explanation` | **Not implemented** (`SettlementStore.loadExplanation` → 404 today) |

**Refactor on move:** all settle-up routes dual-auth via `requireMobileSession` + `getServerSession(authOptions)`. For BillBandit-only API, drop NextAuth web fallback to avoid pulling `lib/auth.ts` + `app/api/auth/[...nextauth]`.

**Not needed for BillBandit SIWA/username:** `/api/mobile/auth/login|register|otp/*`, `/api/mobile/auth/profile` (unused by `UsernameIdentity.swift`).

---

## 2. `lib/` modules to move

### Auth stack
- `lib/prisma.ts`
- `lib/mobile-auth.ts` — Bearer JWT (`MOBILE_JWT_SECRET`)
- `lib/mobile-dto.ts` — `mobileUser()` only
- `lib/apple-id-token.ts` — Apple JWKS verify (`jose`)
- `lib/username-handle.ts`
- `lib/mobile-auth-identifiers.ts` — `syntheticEmailForAppleSubject()` (apple route); OTP/email helpers unused by SIWA path
- `lib/validations.ts` — `appleSignInSchema` (extract or copy slice)

### Settlement engine (entire tree except legacy/backfill)
```
lib/settlement/
  access/matrix.ts
  commands/{core,settle,reverse,setting}.ts
  ledger/{load,obligations,projections,types}.ts
  money/{canonical,registry,transfer-id}.ts
  outbox/{auth,bootstrap,dispatcher,pusher}.ts
  participants/service.ts
  read/sync.ts
  version/sources.ts
```
**Skip:** `legacy/adapter.ts` (only `/api/transactions` shim), `money/backfill.ts` (one-off ops).

### Bootstrap
- `instrumentation.ts` — calls `bootstrapSettlementOutbox()` on Node startup

### npm deps (minimum)
`@prisma/client`, `prisma`, `jose`, `pusher`, `zod`, `next` (or slim HTTP framework). `bcryptjs` only if keeping password helpers in `mobile-auth.ts`.

---

## 3. Prisma models & migrations

### Tables settlement runtime reads/writes (even without group/expense API routes)
`User`, `Account`, `Group`, `GroupMember`, `GroupParticipant`, `Expense`, `ExpenseSplit`, `Transaction`, `SettlementAllocation`, `SettlementAllocationPath`, `SettlementReversal`, `SettlementSettingAudit`, `IdempotentOperation`, `SettlementVersionJournal`, `SettlementOutbox`, `CurrencyExponentRegistry`, `MoneyMigrationIssue`.

Ledger loader (`lib/settlement/ledger/load.ts`) **always** queries expenses + splits + transactions for a `groupId`. No expense rows → empty plan.

### Migrations to deploy (order)
1. `prisma/migrations/20240101000000_init/migration.sql`
2. `prisma/migrations/20260512114541_init/migration.sql`
3. `prisma/migrations/20260618000000_mobile_auth/migration.sql`
4. `prisma/migrations/20260621000000_group_finalization/migration.sql`
5. `prisma/migrations/20260728000000_unique_usernames/migration.sql`
6. `prisma/migrations/20260730000000_shared_settle_up/migration.sql`

Ship full `prisma/schema.prisma` (or trimmed schema with FK-safe subset above). `Session`, `VerificationToken`, `MobileOTPChallenge`, `Friendship`, `Comment`, `ActivityLog` unused at runtime but harmless if kept.

---

## 4. Env vars (production)

| Var | Purpose |
|-----|---------|
| `DATABASE_URL` | PostgreSQL |
| `MOBILE_JWT_SECRET` | Mobile Bearer tokens (fallback: `NEXTAUTH_SECRET`) |
| `IOS_BUNDLE_ID` or `APPLE_CLIENT_ID` | Apple token audience (`com.billbandit.app`) |
| `PUSHER_APP_ID`, `PUSHER_KEY`, `PUSHER_SECRET`, `PUSHER_CLUSTER` | Realtime invalidation (optional; iOS polls without) |

**Dev/QA only:** `MOBILE_AUTH_MOCK_APPLE_*` (bypass Apple verify in `apple-id-token.ts`).

**Not required for SIWA/username settle-up:** `GOOGLE_*`, `NEXTAUTH_URL`, OTP/SMS vars, `NEXT_PUBLIC_*` (unless client reads Pusher key from plist — BillBandit uses `Info.plist` `PUSHER_KEY`/`PUSHER_CLUSTER`).

---

## 5. Can stay in archived FairShare

- All `app/(dashboard)/**`, `app/page.tsx`, marketing/auth pages
- Web NextAuth: `app/api/auth/**`, `lib/auth.ts`
- Mobile groups/expenses/dashboard: `app/api/mobile/groups/**`, `app/api/mobile/expenses/**`, `app/api/mobile/dashboard/**`, `app/api/mobile/transactions/**`
- Web groups/expenses: `app/api/groups/route.ts`, `app/api/groups/[id]/route.ts`, `app/api/expenses/**`, `app/api/balances/**`, `app/api/friends/**`, `app/api/export/**`, `app/api/activity/**`, `app/api/users/**`
- `lib/balance-calculator.ts`, `lib/algorithms/simplify-debts.ts` (settlement has own ledger math)
- `components/**`, `scripts/settlement-backfill.ts`

---

## 6. Risks if moving settle-up without groups/expenses/mobile routes

1. **Stale balances** — Settle-up reads server DB expenses; BillBandit CloudKit expenses never reach Postgres unless a sync path exists. Manual `serverGroupId` link only works if FairShare group data is already populated and kept current.
2. **No version bumps** — `onGroupExpenseMutation` / membership hooks live in expense & group routes (`version/sources.ts`). Without them, settlement version stays frozen; concurrent edits won't invalidate clients correctly.
3. **Access control** — `resolveCallerAccess` requires `GroupMember` + `GroupParticipant` rows for the signed-in user. SIWA user must be a member of the linked group with matching `userId`.
4. **Missing explanation endpoint** — Transfer detail sheet fails silently (404) until route is built.
5. **Participant drift** — `ensureParticipantsForGroup` runs on expense/membership mutations, not on settle-up GET. Departed members / renames may desync without member sync.
6. **Cutover auth** — New `MOBILE_JWT_SECRET` invalidates existing tokens; Apple `Account` rows must migrate with same `DATABASE_URL` or users re-link Apple subjects.
7. **Realtime optional** — Without Pusher + outbox dispatcher, iOS falls back to 10s polling (`SettlementPollingRealtimeClient`); functional but higher load.

---

## Minimal move checklist (~40 source files)

- **10** route handlers (7 settle + 3 auth) + **1** health
- **19** `lib/settlement/**` files + **7** auth/support libs + `instrumentation.ts`
- **1** `prisma/schema.prisma` + **6** migrations
- Implement **1** missing explanation route before shipping transfer-detail UI
