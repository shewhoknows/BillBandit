# State machines: iOS ledger cache, offline queue and sync (`ios-ledger-sync`)

Scope: `BillBandit/BillBandit/ServerLedger/**`, `Store/AppStore.swift`, `Engine/**`.
Model: `specs/tla/ios-ledger-sync/LedgerQueueSync.tla` (replay: `sh specs/tla/ios-ledger-sync/run.sh`).
Line numbers refer to this branch (`sm/ios-ledger-sync`).

`Engine/**` (BalanceEngine, SplitEngine, Money) is pure arithmetic with no state. It has no machine.

## Actors that really run at the same time

* **Several `ServerLedgerSync` instances share one `ServerLedgerStore`** (`AppStore.serverLedgerStore`):
  `ServerLedgerAccountLifecycle.sync` (15 s reconcile from `CloudCollaboration.refreshWhileVisible`),
  `T15CanonicalLedgerRuntime.sync` (add/edit/delete sheets), `ServerLedgerSurfaceStore.sync` (home cards),
  and one new instance per `SettlementStore.configure`. An old instance's task keeps running after it is replaced.
  Each instance has its **own** `accountGeneration` / `activeAccountID` / `state`. Only the store's drain gate
  (`beginDrain`) and, after this change, the store's **account epoch** are shared.
* The keychain session token is read at **send time** by `URLSessionServerLedgerAPIClient` and is written by
  `UsernameIdentityService` off the main actor, before `ServerLedgerAccountLifecycle.activate` runs.
* The server (`apps/api/lib/ledger/mutation/kernel.ts`): one transaction per mutation. The receipt
  (`LedgerOperation`) key is **(session account, operationId)**. A COMMITTED receipt replays its result with no
  revision check. Otherwise `expectedRevision` must equal `Group.settlementVersion`, which then increments by
  exactly 1. A conflict rolls back, so no receipt is kept.
* A second phone (peer) writes to the same group. In the model it is `PeerWrite` (its own queue is the same
  machine, so only its effect on the server revision matters to device 1).

## M1. Queue row `PendingLedgerOperation.retryState` (explicit enum, `PendingLedgerOperation.swift`)

| From | Event | To | Code |
| --- | --- | --- | --- |
| (none) | `store.enqueue` new ID | pending | `ServerLedgerStore.swift:105` |
| pending / retrying / inFlight | drain picks the row | inFlight | `ServerLedgerSync.swift:255` `markInFlight` |
| inFlight | 2xx, snapshot cached | succeeded | `:276` `markSucceeded` |
| inFlight | 409 REVISION_CONFLICT, IDEMPOTENCY_KEY_REUSED, other 4xx (not 408/429), scope mismatch | failed | `:382-408` `markFailed` |
| inFlight | offline, timeout, 5xx, 408/429 | retrying, `nextRetryAt = now + backoff` | `:397-410` `retry(after:)` |
| inFlight | 401 or token for another account | retrying, `nextRetryAt = nil` | `:390` |
| inFlight | app killed / account changed while the request was out | stays inFlight (replayed with the same ID) | `:282-288` |
| pending / retrying / inFlight | reservation chain broken (new) | failed `revision_conflict_requires_reconfirmation` | `:246` |
| any | `store.clear(accountID:)` (sign-out, account switch) | row deleted | `ServerLedgerStore.swift:250` |

`succeeded` and `failed` are final. The table is `PendingLedgerOperationState.canTransition(to:)`
(`PendingLedgerOperation.swift:32`). Every `mark*`/`retry` asserts it in Debug builds (behaviour in Release is unchanged).
One path used to break the table: the final `context.save()` after `markSucceeded` throws, and the catch turned the row
back into `retrying`. It now keeps it succeeded in memory (a replay of the on-disk inFlight row is idempotent).

Invariants: a row is sent only with its own `operationID` (never regenerated); a row of account A is only sent
with a token whose `sub` is A; at most one drain per account per process (`beginDrain`, `:228`).

## M2. Drain order and revision reservation (`ServerLedgerQueueOrder`, coordinator, store)

Rows of one group form a chain. `nextQueuedExpenseRevision` (`ServerLedgerStore.swift:273`) gives a new row
`max(waiting expectedRevision) + 1` when that max is at least the revision the person saw.

| | Before | After |
| --- | --- | --- |
| Which kinds reserve | only `expense.create` (call site in `AddGroupSheet.swift`) | every kind sent through `ServerLedgerMutationCoordinator.enqueueServerMutation` (`:114`); the revision the person saw is stored as `basedOnRevision` |
| Which rows a drain sends | every waiting row that is due, in creation order | in creation order, but a group **stops at its first row still in backoff** (`ServerLedgerQueueOrder.drainable`, `PendingLedgerOperation.swift:207`) |
| Reserved non-create row whose chain broke | (could not happen: edits did not reserve) | failed as a conflict without sending (`reservationIsIntact`, `:228`): every revision in `basedOnRevision ..< expectedRevision` must belong to a succeeded row of this device |

Settlement rows (`SettlementStore.enqueueIfNeeded`) and `reconfirm` still call `store.enqueue` directly and do not reserve.

## M3. `ServerLedgerSyncState` + `requiresReconfirmation` (per instance, `ServerLedgerSync.swift`)

States: `idle, refreshing, draining, offline, unauthorized, conflictRequiresReconfirmation`.
Diagram in the enum's doc comment. `offline`/`unauthorized` block refresh and drain until `markReconnected()`;
`conflict` blocks nothing. Reachable odd combinations (cosmetic, left as is):
* `activate()` sets `idle` while this instance is still draining (`:115`); the shared `beginDrain` gate still prevents a second drain.
* `reconfirm()` clears `requiresReconfirmation` but leaves `state == .conflictRequiresReconfirmation` (`:331`).
* `refreshing` and `draining` overwrite each other when both run on one instance.
* The 401 "pause" is not a pause: every caller (`lifecycle.reconcile(.foreground)` every 15 s, every T15 refresh,
  `SettlementStore.refresh`) calls `markReconnected()` first. With no token the row just retries every 15 s
  (`retryCount` grows, no backoff for 401). After this change no token or another account's token is refused
  before the network.

## M4. Cache row `CachedLedgerSnapshot` (revision fence)

`absent -> rev r -> rev r' (r' >= r) -> deleted (clear)`. `ServerLedgerStore.cache` refuses a lower revision (`:78`);
`refresh` and the drain also throw `staleRevision` before writing (`ServerLedgerSync.swift` refresh / drain).
Check-and-write has no `await` in between, so on the main actor it is atomic. A refresh or post-mutation snapshot that
was started before an account clear can no longer write the old account's cache back (epoch check).

## M5. Account lifecycle and session (`ServerLedgerAccountLifecycle`, `AppStore.swift:157`)

`signedOut -> active(A) -> unauthorized(A, queue kept) -> active(A) | active(B: A's cache+queue cleared) | signedOut`.
Fields: `activeAccountID`, persisted `serverLedger.authoritativeAccountID`, `lifecycleGeneration`
(bumped on account change and sign-out), `isReconciling` + `reconciliationGeneration`
(`invalidateReconciliation` lets a new reconcile start while the old one is still awaiting; the old one is fenced by
the sync generation and now also by the store epoch). New: `ServerLedgerStore.accountEpoch` is bumped by every
`clear(accountID:)` and by `LocalAccountDataCleanup.deleteAll` (`AppStore.swift:106`); drains and refreshes of **all**
instances capture it and stop before they send, cache or touch a (possibly deleted) row.

## M6. Store preparation `AppStore.didPrepareStore`

`unprepared -> prepared`, set before the repair work runs (`AppStore.swift:70`), main actor only. One-shot per launch, no bug.

## Server receipt (read only, `kernel.ts`)

`absent -> PENDING (inside the transaction only) -> COMMITTED | FAILED`; key `(accountId = session user, operationId)`.

## Properties checked (TLC)

| Property | Meaning |
| --- | --- |
| `NoDoubleApply` | no operation's effect commits twice |
| `SucceededApplied` | a row marked succeeded was applied exactly once |
| `NoCrossAccount` | no row of account A is sent with account B's session |
| `NoLostUpdate` | an edit never commits over a peer revision the person did not see |
| `NoSelfConflict` | a row fails only because of a real peer change (not because of this device's own rows or order) |
| `CacheMonotonic` | the cached revision never goes down for the active account |
| `QueueDrains`, `AppliedOrFailed` (liveness) | every queued row ends succeeded (applied once) or failed |
| `Converges` (liveness) | the cache reaches the server revision |

Bounds: 2-3 rows (create, create, edit), 1 peer write, 1 lost request/response, 1 app kill, 1 account switch (401 then
sign in as B), 2 sync instances. Results (`specs/tla/ios-ledger-sync/tlc-*.txt`, short traces in `trace-*.txt`):

| Run | Result |
| --- | --- |
| `before_order` | **NoSelfConflict violated**, 11 steps |
| `before_selfconflict` | **NoSelfConflict violated**, 10 steps |
| `before_account` | **NoCrossAccount violated**, 6 steps |
| `noguard` (reserve every kind but no chain guard) | **NoLostUpdate violated**, 15 steps: why the guard exists |
| `after` | clean, 559,335 states / 159,131 distinct |
| `after_live` | clean incl. liveness, 44,000 distinct |
| `before_live` | clean: the old code also always ends each row; its failures are final, so liveness does not see a lost row |

## Bugs found

1. **Replay order (data loss, likely on any trip).** Trace `before_order`: row 1 is sent, the network drops, row 1 waits
   for backoff; row 2 (reserved revision +1) is due first and is sent; the server is still at the old revision, so
   row 2 gets REVISION_CONFLICT and is failed for good, with no peer change. Story: offline for a few minutes, add two
   expenses; backoffs differ, so when the signal returns the second one goes first, fails, and is never sent again.
   The sheet had already closed ("queued"), and no screen lists failed rows. Fix: per-group head-of-line order.
2. **Own queued change makes the next edit conflict (data loss).** Trace `before_selfconflict`: offline create
   (rev 0), offline edit of another expense (also rev 0, edits did not reserve); create applies -> rev 1; edit
   conflicts. Fix: reserve for every kind + chain guard (trace `noguard` shows the lost update without the guard).
3. **Account A's queued change sent with account B's session (money: wrong actor; crash risk).** Trace
   `before_account`: a 401 clears the token but keeps A's queue; signing in as B writes B's token before
   `activate(B)`; a drain (or a stale SettlementStore/T15 instance whose generation nobody bumps) sends A's row with
   B's token. The server keys the receipt by B and applies it as B if B is in the group. The old instance could also
   read rows that `clear(A)` had already deleted. Fix: token `sub` must equal the row's account
   (`ServerLedgerAPIClient.swift:257`), and the shared store epoch fences every instance.

## Not fixed here (needs UI or another slice)

* **A failed row is not shown anywhere** once its sheet has closed. Background drains (`lifecycle.reconcile`) put the
  error in `ServerLedgerAccountLifecycle.lastError`, which no view reads. The rows stay in the store with `lastError`;
  `ServerLedgerStore.pendingOperations(for:includingCompleted:)` already returns failed rows, so a UI slice can list
  them. Until then, "applied or shown failed" holds only as "applied or durably failed".
* Head-of-line order can hold a group's later rows for up to the 300 s backoff cap after a long offline period.

## Verification still needed on a Mac (Swift was not compiled here)

1. Build the `BillBandit` scheme for an iOS simulator (Swift 6). The SwiftData model gains one optional attribute
   (`PendingLedgerOperation.basedOnRevision`); launch once over an existing store to confirm the automatic migration.
2. Replay order: local API + simulator; go offline (Network Link Conditioner "100% Loss"); add expense 1, wait
   about 2 minutes (several 15 s reconciles so its backoff grows), add expense 2; restore the network. Expected: both
   expenses appear, server revision +2, no row left `failed` (old code: expense 2 missing, REVISION_CONFLICT in the API log).
3. Self-conflict: offline, add an expense, then edit a different existing expense; reconnect. Expected: both applied.
4. Chain guard: offline, add an expense and edit another; before reconnecting, change the group from a second
   account; reconnect. Expected: the edit is not applied over the peer change (row failed, conflict state).
5. Account fence: with queued rows for A, force a 401, sign in as B, check the API log: no mutation for A's
   operation IDs arrives with B's session; A's rows are deleted by the switch.
