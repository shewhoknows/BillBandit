# Settlement state machines

Slice: `settlement` (apps/api/lib/settlement/**, outbox, the settle and reverse routes).
Code names for the states and transitions: `apps/api/lib/settlement/state.ts`.
TLA+ models and TLC output: `specs/tla/settlement/`. E2E: `apps/api/scripts/settlement-e2e.ts`
(output in `specs/tla/settlement/e2e-*.txt`).

Line numbers are approximate (commit f0d864c).

## 1. Payment (Transaction + SettlementAllocation, then SettlementReversal)

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| (none) | settle | active member; actor is payer or recipient; `expectedVersion == settlementVersion`; transfer in current plan; `0 < amount <= transfer amount`; full amount routes through obligations; currency = group currency | RECORDED | `kernel.ts` prepareSettlement 905-1060, commit 1301-1308 |
| RECORDED | reverse | active member; actor is payer or recipient; `expectedVersion` current; no reversal yet | REVERSED | `kernel.ts` prepareReversal 1066-1136, commit 1309-1313 |
| REVERSED | reverse | - | refused `ALREADY_REVERSED` 409 | `kernel.ts` 1089 |
| reversal id | reverse | - | refused `SETTLEMENT_NOT_FOUND` 404 (a reversal is not a payment) | `kernel.ts` 1086 |

- REVERSED is final. `SettlementReversal.transactionId` is unique, so the database also stops a second reversal.
- Finalized group: settle and reverse are both allowed. `api-contracts.md` says finalized groups still accept settlements. `assertNotFinalized` exists in the kernel, but nothing calls it.
- READ COMMITTED: `readGroup` + revision check is its own statement, so a phone that loses a race can get `ALREADY_REVERSED` (guard saw the winner) instead of `SETTLEMENT_VERSION_CONFLICT`. Both are 409; the iOS client treats every 409 as a conflict and refetches. Modelled in `SettlementLedger.tla` (Check / Prepare).
- All money writes go through one kernel transaction. The serialization point is the CAS `UPDATE Group SET settlementVersion+1 WHERE settlementVersion = expected` (`reserveRevision`, kernel 1326). Every read in `prepare*` happens before that CAS, so a commit by someone else between the reads and the CAS makes the CAS fail. The result is `REVISION_CONFLICT`, sent to the client as `SETTLEMENT_VERSION_CONFLICT` with `requiresReconfirmation` (`commands/core.ts` normalizeSettlementError).

### Idempotency (LedgerOperation, per account + `settlement:<Idempotency-Key>`)

| From | Event | To |
| --- | --- | --- |
| (none) | attempt starts (upsert) | PENDING (inside the open transaction only) |
| PENDING | body commits | COMMITTED (with resultRevision, resultRecordId) |
| PENDING | body throws / process dies | (row rolled back, so it never existed) |
| COMMITTED | same key + same hash | replay the stored result (expectedRevision is not part of the hash, so an offline replay with a stale revision still replays) |
| COMMITTED | same key, different body | `IDEMPOTENCY_KEY_REUSED` |
| FAILED | - | the kernel never writes this state for settle/reverse |

**Bug fixed (wrong UI):** Prisma runs this upsert as find-then-insert. When a second attempt with the same key arrives while the first is still open (an offline-queue retry racing the original), it waits on the unique index. When the first commits, the second fails with P2002 and the route returns **500**, though the payment was recorded once. Fix: `withOperationKeyReplay` (`commands/core.ts` 86-105) runs the command one more time on that P2002. The second run finds COMMITTED and replays. It is used by `commands/settle.ts` 22 and `commands/reverse.ts` 15. The same race exists for every other kernel mutation (expenses, members). The general fix belongs in `kernel.ts` (treat that P2002 as a retry).

## 2. Group settle-up completion (`hadOpenTransfers`, `settlementCompletedAt`)

Derived state. It is recomputed only after a settle or reverse request (`version/sources.ts`, called by both routes after the kernel commit, in a second transaction). Expense routes do not touch it.

| State | hadOpenTransfers | settlementCompletedAt | Meaning |
| --- | --- | --- | --- |
| OPEN | true | null | the plan has transfers |
| SETTLED | false | time of the latest settle/reverse journal row | "everyone is settled" + date on the settle-up screen |

Rule: the mutation kernel holds the group revision lock and updates completion
flags in the same transaction as the ledger change and journal. A nonempty plan
clears the completion date. An empty plan uses the latest settle or reverse
journal date. With no such event, it keeps the existing date. The route's later
recompute remains safe to retry.

Invariants (TLA+ `SettlementCompletion.tla`): when no request is in progress and the last commit was a settle or reverse, `hadOpen = planNotEmpty` and `completedAt = (planEmpty ? time of last settle/reverse : null)`.

**Bugs fixed (wrong UI):**
1. *Stale date.* The old rule was `completedAt = existing ?? now`. If everyone settled on Monday, a new expense was added, and it was settled on Friday, the screen still showed Monday. TLC: `tlc-completion-before-sequential.txt`. E2E step 4 failed before the fix and passes after it.
2. *Out-of-order write.* Phone A records the last payment. Phone B reverses it at the same moment. A's recompute read "plan empty" before B committed, but its write landed after B's recompute. The result was `hadOpen=false` and a completion date while a debt was open. TLC: `tlc-completion-before.txt` (8 states). The row lock fixes it. There is no E2E test for this: the timing window cannot be hit on purpose over HTTP.

The crash window between a payment and its flag update is closed by the kernel
transaction. The server E2E invokes the payment command without the route's
post-commit hook and checks the persisted flags and payment. The
`SettlementCompletion_after_crash` model passes with the atomic transition.

Dead code: `commands/core.ts` `advanceGroupVersion` (143) is a second, different copy of the version, journal, outbox and flag logic. Nothing calls it. If it were called next to the kernel, it would journal a version twice.

## 3. SettlementOutbox row

| From | Event | Guard (WHERE) | To | Code (`outbox/dispatcher.ts`) |
| --- | --- | --- | --- | --- |
| (none) | kernel commit | same transaction as the ledger write | PENDING | `kernel.ts` journalMutation 1362; finalize route 173 |
| PENDING | lease | `id, state=PENDING, nextAttemptAt<=now` | LEASED (token = `owner:uuid`, expires +30 s) | 50-60 |
| LEASED | publish ok | `id, state=LEASED, leaseOwner=token` | PUBLISHED (final) | 72-82 |
| LEASED | publish failed | same as above | PENDING, attemptCount+1, backoff ≤ 60 s | 85-95 |
| LEASED | lease expired | `state=LEASED, leaseExpiresAt<now` | PENDING | 25-34 |
| FAILED | - | nothing writes it | - | - |

Workers: every process drains every 5 s and after each committed mutation, so two drains of one row at once is normal. The default `owner` is `worker-<pid>` and is shared by every drain in a process. That is why the lease token now adds a random part.

Invariants (TLA+ `SettlementOutbox.tla`, 2 workers, 1 failure, 1 crash, 1 slow-publish expiry):
- NeverLost: PUBLISHED ⇒ Pusher got the event at least once. This held before and after the fix.
- Liveness: with fair workers, the row ends PUBLISHED and all workers end idle. This held before and after the fix (`tlc-outbox-before-liveness.txt`, `tlc-outbox-after.txt`).
- PublishedIsFinal: once PUBLISHED, always PUBLISHED. **Violated before the fix.**

**Bug fixed (duplicate realtime event):** Worker A leases a row, and its Pusher call hangs for more than 30 s. Worker B reclaims the row and publishes it, so the row is PUBLISHED. A's call then fails, and A writes `PENDING` over `PUBLISHED`. The event is sent again. Before the fix, the final writes were `update where {id}`. Now they are fenced by the lease token. TLC: `tlc-outbox-before.txt` (9 states). E2E step 11 failed before the fix and passes after it.

Also hardened: background drains now catch their own errors (`drainInBackground`), so a database error is not an unhandled promise rejection. Delivery is at least once: a duplicate publish is still possible when A succeeds after its lease expired. Clients treat these events as "refetch", so this is harmless.

## 4. Settlement mode (simplify on/off)

`Group.simplifyDebts` + `SettlementSettingAudit`. The kernel supports `settings.update` (admin only; a no-op when the value is unchanged; otherwise it bumps the version and writes an audit row). Each `planTransferId` includes the mode and the version, so a switch makes every open transfer id stale, and payers must reconfirm. **There is no HTTP route for it.** The iOS client sends `settings.*` kinds to `/api/groups/{id}/settlements`, and that route only records payments. Nothing to model until a route exists.

## 5. Participant status (ACTIVE → DEPARTED, back to ACTIVE when the person is added again)

`access/matrix.ts`: a DEPARTED participant who still has an unsettled position may read the plan and settle or reverse. The kernel (`ensureActiveMember`) refuses anyone who is not a current member, so in practice a departed participant gets 403. The counterparty can still record the payment. This mismatch is reported, not changed (the kernel is owned by another slice).
