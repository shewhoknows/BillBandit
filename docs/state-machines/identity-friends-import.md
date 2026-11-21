# State machines: identity, friends, CloudKit import

Slice `identity-friends-import`. Code names for every state and allowed move:
`apps/api/lib/identity-friends-state.ts`. TLA+ models and TLC output:
`specs/tla/identity-friends-import/`. HTTP proof: `apps/api/scripts/identity-friends-import-e2e.ts`
(`specs/tla/identity-friends-import/e2e-before.txt`, `e2e-after.txt`).

Line numbers are for the commit that adds this file.

## Not present in this revision

- **OTP login.** `MobileOTPChallenge` exists in the schema, but no route creates, verifies or
  consumes a challenge. The only code that touches it is account deletion
  (`deleteMany` by email/phone). Nothing to model.
- **App Review "review code" login and its server switch.** No such route, flag or env switch
  exists in `apps/api` (searched for review, reviewer, demo, otp). Review sign-in today is
  Sign in with Apple. The `MOBILE_AUTH_MOCK_APPLE_*` fake token is the only "bypass" and it is
  hard-off when `NODE_ENV=production` (`lib/apple-id-token.ts:16`).

## 1. Account

| State | Stored as |
| --- | --- |
| `active` | `User.deletedAt IS NULL` |
| `deleted` (terminal) | `User.deletedAt` set; email `deleted+<id>@…`, username, phone, image cleared |

| Event | From → To | Guard | Code |
| --- | --- | --- | --- |
| Sign in with Apple, first time | (none) → `active` | Apple token valid | `app/api/mobile/auth/apple/route.ts:49` (`withUniqueRetry` + upsert/connectOrCreate) |
| Sign in with Apple again | `active` → `active` | Account row (apple, sub) exists | same |
| Claim handle (onboarding) | `username NULL` → set | `updateMany where username IS NULL`; unique index | `auth/username/route.ts:66` |
| Change handle (Profile) | set → set | unique index (409 `username_taken`) | `auth/username/route.ts:92` |
| Delete account | `active` → `deleted` | row locked `FOR UPDATE` first | `lib/account-deletion.ts:28`, commit `:121` |
| Delete again | `deleted` → `deleted` | returns `already_deleted` (route answers 200) | `lib/account-deletion.ts:33` |
| Sign in with Apple after deletion | — → new `active` user | Account row was deleted; anonymised email cannot match | apple route |

Tokens are stateless HS256 JWTs (30 days). Every request goes through `getMobileSession`, which
re-reads the user and refuses `deletedAt` (`lib/mobile-auth.ts:123`). All mobile and settlement
routes use it (`requireMobileSession` / `lib/settlement/route-auth.ts`).

Invariants:
- A1 No token works after deletion (E2E: 401 on `/auth/me`, `/friends`, `/sync-token`, `/rewards`, invitations).
- A2 Deleting an account never changes another member's balance (model `BalanceUnchanged`).
- A3 At most one live account per Apple subject; concurrent first sign-ins get the same account (`OneLiveAccount`, `SameFreshAccount`).
- A4 The deleted user's handle is free again; re-sign-in starts with no handle.

What happens to groups with open debts: deletion is allowed. Expenses, splits, payments,
allocations and reversals stay; the member shows as "Deleted user"; the debt stays visible to the
others. Only free text (expense notes/receipt/description of expenses they paid, payment notes,
comments, activity) is removed.

## 2. Friend invitation (one reusable code per inviter)

The code is **reusable** for 7 days by design (any number of people may claim it). "A code is used
at most once" does not apply here; what must hold is "an expired or rotated code never works".

| State | Stored as |
| --- | --- |
| `none` | no `FriendInvitation` row for the inviter |
| `active` | row, `expiresAt > now` |
| `expired` | row, `expiresAt <= now` |

| Event | From → To | Code |
| --- | --- | --- |
| Get my code | `none` → `active` | `lib/friends.ts:275` (create; P2002 → retry, not in a transaction) |
| Get my code | `active` → `active` (same code) | `lib/friends.ts:248` |
| Get my code | `expired` → `active` (new code) | `lib/friends.ts:262` (`updateMany where expiresAt <= now`: one rotation wins) |
| Time passes | `active` → `expired` | derived, `deriveInvitationState` |
| Inviter deleted | any → `none` | `lib/account-deletion.ts:94` |

## 3. Friendship (one row per unordered pair)

Stored sorted (`normalizedFriendPair`), unique `(fromId, toId)`. `PENDING` and `REJECTED` exist
in the enum but no code writes them.

| Event | From → To | Guard | Code |
| --- | --- | --- | --- |
| Claim code | `none` → `accepted` (201) | not own code (409), not expired (410), inviter exists and not deleted (404), not rate-limited (429) | `lib/friends.ts:387` (upsert → `INSERT … ON CONFLICT`) |
| Claim again | `accepted` → `accepted` (200) | same | same |
| Unfriend | `accepted` → `none` | — | `lib/friends.ts:440` |
| Either account deleted | `accepted` → `none` | — | `lib/account-deletion.ts:96` |

Invariants: F1 at most one row per pair (E2E: both sides claim at once, 5 pairs; one phone sends
3 claims at once, 5 times). F2 no friendship with a deleted account once both requests finished
(model `NoFriendshipWithDeleted`).

## 4. Friend-code failure limit (`FriendClaimRateLimit`, per claiming account)

| State | Stored as |
| --- | --- |
| `open` | no row, or `windowStartedAt` older than 15 min |
| `counting(n)` | `failureCount = n < 10` in the window |
| `blocked` | `blockedUntil > now` |

| Event | From → To | Code |
| --- | --- | --- |
| Wrong / malformed / expired / own / deleted-inviter code | `open`→`counting(1)`, `counting(n)`→`counting(n+1)`, `counting(9)`→`blocked` (that request answers 429) | `recordFriendClaimFailure`, `lib/friends.ts:339` |
| Any claim while `blocked` | `blocked` → `blocked` (429, nothing looked up) | `lib/friends.ts:336` |
| Right code | unchanged (**was: row deleted → `open`**) | — |
| Window over | `blocked`/`counting` → `open` | upsert CASE on `windowStartedAt` |

Guard: the check and the count run in one transaction under
`pg_advisory_xact_lock('friend-claim:<account>')` (`lib/friends.ts:329`).
Invariant R1: at most 10 wrong codes looked up per account per window (model `LookedBound`).

## 5. CloudKit ledger import

`LedgerImport.state`:

| From → To | Event | Code |
| --- | --- | --- |
| (none) → `RUNNING` | first prepare, validation ok (row created `PENDING` and moved in the same transaction) | `service.ts:607`, `:812` |
| (none)/`PENDING`/`RUNNING`/`FAILED` → `FAILED` | validation or reservation error; checksum changed while incomplete | `service.ts:766`, `:796`, `:1473` |
| `RUNNING` → `RUNNING` | re-run / resume after crash | `service.ts:812` |
| `RUNNING` → `FAILED` | a record fails → that record `QUARANTINED` | `service.ts:1297-1298` |
| `RUNNING` → `COMPLETED` (terminal) | every record row `IMPORTED` | `service.ts:1331` (now only from `RUNNING`) |
| `FAILED` → `RUNNING` | same checksum, validation passes (repair retry) | `service.ts:812` |
| `COMPLETED` → — | later exports with another checksum or key: 409 `completed_import_frozen` | `service.ts:593`, `:757` |

`LedgerImportRecord.state`: `PENDING → IMPORTED` (terminal, same transaction as the money upsert,
`service.ts:1260`), `PENDING → QUARANTINED`, `QUARANTINED → PENDING` on retry (`:703`),
`QUARANTINED → IMPORTED` for a row owned by an older import. Metadata row: `SKIPPED`.

Locks (new): prepare and completion take `cloudkit-import:<account>`; each record takes
`cloudkit-import:<account>:<logicalKey>` (`service.ts:752`, `:1228`, `:1306`).

Invariants: I1 money never imported twice (target ids are deterministic hashes of the source
record, writes are upserts; model `MoneyOnce`); I2 `COMPLETED` ⇒ every record imported once
(`CompletedIsWhole`); I3 two runs at once never answer 500 (`NoServerError`); I4 only the
transitions above (`LegalTransitions`); L1 with client retries and bounded crashes the import
completes (`EventuallyCompleted`) — holds only when the source does not change (see open issue).

## Bugs found and fixed

| # | Severity | TLC counterexample | Real story | Fix | Verified |
| --- | --- | --- | --- | --- | --- |
| 1 | **money** | `AccountDeletion-before-money`: `DelRead(d1) → DelClean(d1)`: reversal row gone, `BobOwes` 5000 → 0 | Bob paid Alice ₹50, then reversed it, so he owes ₹50. Alice deletes her account. Deletion deleted every `SettlementReversal` (and allocation/path) of payments she was in, so the reversed payment counted again: Bob's debt silently became ₹0. A simplified payment between two *other* people routed through her also lost its allocation. | Keep reversal, allocation and path rows; only null payment notes. | TLC clean; E2E step 2 FAIL before (5000 → 0), PASS after |
| 2 | security | `FriendClaimLimit-before-reset`: bad, good, bad, bad with LIMIT 2 → 3 lookups. `-before-parallel`: 3 bad requests pass the check before any is counted | An attacker with a second account (or any existing friend's code) types 9 guesses, claims the known code (resets the counter), repeats: unlimited guessing of 5-letter codes, so they can friend strangers. Parallel requests also all pass the read-then-count check. | No reset on success; check + count in one transaction under a per-account advisory lock; failure is committed before the error. | TLC clean; E2E "successful claim does not reset": FAIL before (404 after reset), PASS after (429). Parallel burst of 60 did **not** reproduce over HTTP on the dev server (9 lookups both before and after) — TLC only. |
| 3 | wrong UI | `AppleSignIn-before`: `Find(d1) Find(d2) Create(d1) Create(d2)` → d2 `failed` | First sign-in on iPhone and iPad at the same time (or a double tap / retry): one device gets "Apple sign-in failed". | Retry the upsert on P2002 (max 3). | TLC clean; E2E 5 rounds × 3 devices: FAIL before (`200,401,401`), PASS after |
| 4 | wrong UI / retry | `CloudKitImport-before`: `Find(w1) Find(w2) Prepare(w1) Prepare(w2)` → 500 | The app's 30 s timeout re-sends the import while the first request runs: the second request hits a unique key inside its Postgres transaction; the transaction is aborted, so the "re-read the winner" branch fails with `25P02` → HTTP 500. No money doubled. | Advisory locks around prepare/completion and per record; completion only from `RUNNING`. | TLC clean; E2E 3 parallel runs: `500,500,200` before, `200,200,200` after; money identical |
| 5 | data (low) | `AccountDeletion-before-race`: `DelRead DelClean(friendships) ClaimRead … ClaimWrite` → friendship with deleted user | Carol claims Alice's code while Alice deletes her account: a friendship row to the deleted user survives (hidden by the `deletedAt` filter, but counted in the sync token). Two deletions at once also ran the cleanup twice (`-before-twice`, harmless). | Deletion takes `FOR UPDATE` on the user row first; the claim takes `FOR SHARE` on both users before checking. | TLC clean; not reproducible over HTTP (timing) |

Illegal transition also found: `CloudKitImport-change-before` — `FAILED → COMPLETED` when a run
finishes after another run failed the import for a changed checksum. Now refused (completion only
from `RUNNING`).

## Open issue (not fixed: needs a product decision)

**Changed CloudKit source traps the import in `FAILED`.** `CloudKitImport-change-after` (and
`-change-before-live`): the first submission records rows and the checksum, the request times out
or crashes before the app learns the `importId`, the app re-reads CloudKit (status `collecting`),
one record changed, the `sourceKey` stays the same (it hashes record names only), and every later
prepare answers `needs-repair` ("checksum changed while incomplete"). The app then stops for good
(`needsRepair`). Part of the ledger may already be imported. Options: let a `RUNNING`/`FAILED`
import adopt the new checksum while no record is `IMPORTED`, or include the checksum in the client
`sourceKey`. Today the path is unreachable in production: no code creates `cloudkit`
`ExternalIdentity` rows, so every real import ends `needs-repair` at `resolvePeople`.
