# BillBandit state machines — summary (2026-11-21)

This folder writes down every state machine that was hidden in the code
(booleans, nullable dates, status strings, "in flight" flags, leases,
revisions). Each machine is now named in one place in the code, and each one
has a TLA+ model in `specs/tla/<part>/` that the TLC model checker checked.

| Part | Doc | Named in code | TLA+ models |
|---|---|---|---|
| Server: expenses, groups, members, idempotency | `ledger-kernel.md` | `apps/api/lib/ledger/mutation/state-machines.ts` | `LedgerKernel.tla`, `GroupMembership.tla` |
| Server: settle up, reversals, completion flags, realtime outbox | `settlement.md` | `apps/api/lib/settlement/state.ts` | `SettlementLedger.tla`, `SettlementCompletion.tla`, `SettlementOutbox.tla` |
| Server: account deletion, Apple sign-in, friend codes, CloudKit import | `identity-friends-import.md` | `apps/api/lib/identity-friends-state.ts` | `AccountDeletion.tla`, `AppleSignIn.tla`, `FriendClaimLimit.tla`, `CloudKitImport.tla` |
| iOS: offline queue, sync, cache, account switch | `ios-ledger-sync.md` | `PendingLedgerOperationState.canTransition`, `ServerLedgerQueueOrder` | `LedgerQueueSync.tla` |
| iOS: settle-up screen, account gate | `ios-settlement-shell.md` | `SettlementStore` (derived `isUpdating`, `writeGatesOpen`, `canReverse`) | `SettleShell.tla`, `AccountGate.tla` |
| iOS: failure notices ("no silent failures") | `ios-failure-notices.md` | `AppFailureCenter`, `PendingLedgerOperation.failureAcknowledgedAt` | `FailureNotices.tla` |

## How to check again

- All TLA+ models (after the fixes): `sh specs/tla/check-all.sh` (set `TLA2TOOLS`
  to your `tla2tools.jar`). Results of the last run: `specs/tla/check-all-results.txt`.
- Each model also has a "before" config. It runs the old behaviour and shows the
  bug as a TLC counterexample (`tlc-*-before*.txt`).
- Server end-to-end tests (real HTTP API, local Postgres). Start the local
  server with a mock Apple user that is not `dev_you`:

  ```sh
  cd apps/api
  MOBILE_AUTH_MOCK_APPLE_SUBJECT=ifi-e2e-apple-subject \
  MOBILE_AUTH_MOCK_APPLE_EMAIL=ifi-e2e@dev.billbandit.local npm run dev:server
  npx tsx scripts/dev-data.ts scenario
  npx tsx scripts/settlement-e2e.ts
  npx tsx scripts/ledger-kernel-e2e.ts        # also adds dev_zoya
  npx tsx scripts/any-member-delete-e2e.ts    # needs dev_zoya, so run it after ledger-kernel-e2e
  npx tsx scripts/identity-friends-import-e2e.ts
  npx tsx scripts/simplify-debts-e2e.ts
  ```

  Each script prints the revision, environment, replay command and a PASS/FAIL
  table. Before/after outputs are in `specs/tla/<part>/e2e-*.txt`.

## Bugs found and fixed

Money or data:
1. Account deletion removed payment reversals and allocations. A reversed
   payment then counted again (Bob's ₹50 debt dropped to ₹0). Now kept.
2. A member who still owed money could leave or be removed. Now refused.
3. A person who left a group and then owed money again (an old expense
   they shared was edited or deleted) could not pay it: the server refused
   them. Now they can record or reverse their own payment, and the answer
   is no longer a 500 after the payment is saved. (Changed 2026-11-21: an
   earlier version of this work refused such edits instead. Bobby rejected
   that rule.)
4. iOS offline queue: after a retry delay, a later expense was sent first and
   was lost with no message. Now each group's rows go in order.
5. iOS offline queue: an edit queued after an add failed for good with a
   revision conflict. Now every queued change reserves its revision.
6. iOS: after a session expired and another person signed in, the first
   person's queued change could be sent with the second person's token and
   applied as them. Now a row is sent only with a token for its own account
   (also for settle-up payments).
7. iOS settle-up: a refresh could clear the "saving" state while a payment
   was still saving, so a second payment could start. A double tap could
   start two reversals. Both fixed.

Wrong screen or error:
8. "Everyone is settled" kept an old date, and a race could mark a group
   settled while money was still owed.
9. Two requests with the same key at the same time (the offline queue retries
   while the first request is still running) answered 500 although the change
   was saved. Fixed for expenses, groups, finalize and payments.
10. Retry of a delete or edit that was already saved answered 404.
11. First Sign in with Apple on two devices at once: one device showed
    "Apple sign-in failed".
12. CloudKit import sent twice at once answered 500.
13. Removing yourself from a group answered 500 after it was saved.
14. The last owner could leave or become a plain member (group with no owner).
15. iOS: "Reverse" showed on payments that were already reversed or that
    belong to other members (the server refused them).
16. iOS: a queued payment that the server refused was retried forever, and
    the person was never told. Now it stops and shows "Payment not recorded"
    or "Payment not reversed" once.
17. iOS: after a 401, Home still said "Balances are current" with no session,
    and the app could open without a session.

Security and realtime:
18. A correct friend code reset the wrong-guess counter, so guessing had no
    limit. Now the counter is never reset by a success.
19. A friendship with a deleted account could survive a claim that ran during
    the deletion.
20. A realtime event could be published twice when a worker's lease expired.

## Added 2026-11-21

- **Simplify debts on/off:** `PATCH /api/groups/{id}/settlement-settings`
  (owner only, revision-checked, idempotent, audited; same value = no
  change). See `docs/api-contracts.md`. E2E: `simplify-debts-e2e.ts`
  (11 steps). The app does not have a switch for it yet; it only shows it.
- **No silent failures in the app:** see `ios-failure-notices.md`.

## Open items (not fixed — need a decision or UI work)

- **A person who left a group does not see it in the app.** If an old
  expense changes after they left, the other members see the new debt and
  can record the payment, but the person who left is not told.
- **CloudKit import:** it moves data from the old iCloud version of the app
  to the server. It needs a link between each old iCloud user and a server
  account, and nothing creates those links, so every real import stops as
  "needs repair". Also, if the iCloud data changes after the first upload,
  the import stays FAILED (`CloudKitImport-change-after` fails on purpose).
  The app now tells the person once.
- **Completion flags:** if the server crashes between a payment and the flag
  update, the flags stay stale until the next payment
  (`SettlementCompletion_after_crash` fails on purpose).
- **Queue delay:** a group's later changes can wait up to 300 s behind an
  earlier change that is in retry.
- `scripts/vietnam-trip-qa.ts` starts its server on port 31301 but calls
  31300 by default. Run it with `VIETNAM_TRIP_BASE_URL=http://127.0.0.1:31301`.

## Not verified here

- The Swift code was not compiled (no Xcode on the checking machine). See the
  "Verification still needed on a Mac" lists in the two iOS docs.
- The three-operation `LedgerKernel` model is too large to check fully here.
  The two-operation model was checked fully, and still finds the old bug; the
  three-operation model got a random search only (`tlc-LedgerKernel-after_3ops_simulate.txt`).
