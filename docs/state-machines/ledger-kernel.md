# State machines: ledger kernel

Slice `ledger-kernel`, 2026-11-21. Code: `apps/api/lib/ledger/mutation/kernel.ts`, the named states and transition tables in `apps/api/lib/ledger/mutation/state-machines.ts`, and the routes under `apps/api/app/api/mobile/{expenses,groups,ledger}`.
Models: `specs/tla/ledger-kernel/LedgerKernel.tla` (operations, revisions, retries) and `GroupMembership.tla` (membership and balances). E2E proof: `apps/api/scripts/ledger-kernel-e2e.ts`.

Line numbers refer to the commit on branch `sm/ledger-kernel`.

## 1. Group lifecycle

Stored as `Group.isArchived` and `Group.finalizedAt`. Named by `deriveGroupLifecycle()`.

| State | Columns |
| --- | --- |
| open | `isArchived = false`, `finalizedAt = null` |
| finalized | `isArchived = false`, `finalizedAt` set |
| archived | `isArchived = true` (it wins over `finalizedAt`) |

| From | Event | To | Guard | Code |
| --- | --- | --- | --- | --- |
| open | expense.write (create, edit, delete) | open | revision matches | `kernel.ts` 273 (`assertNotFinalized`), called at 594, 687, 742 |
| open, finalized | ledger.write (membership, payment, settings) | same | revision matches | `kernel.ts` 252 |
| open | finalize | finalized | ADMIN, revision matches; CAS `finalizedAt = null AND isArchived = false`, bumps revision | `finalize/route.ts` 159, 172 |
| open, finalized | archive | archived | owner, nothing owed, no pending non-invitation operation; SERIALIZABLE + `FOR UPDATE`; CAS on revision (no bump) | `groups/[id]/route.ts` 80 |
| finalized | expense.write, finalize | refused `GROUP_FINALIZED` 409 | | `state-machines.ts` `assertGroupEvent` |
| archived | anything | refused `GROUP_ARCHIVED` 403 | | same; also `reserveRevision` `WHERE isArchived = false` (`kernel.ts` 1360) |

No way back: there is no un-finalize and no un-archive.

Invariant (TLC `FinalizedAndArchivedAreFrozen`): no expense changes after finalize or archive. It holds because finalize bumps the revision (so a write prepared before it fails its compare-and-set) and archive is in the compare-and-set `WHERE`.

Not maintained here: `Group.hadOpenTransfers` and `settlementCompletedAt`. Only the legacy settlement routes recompute them (`lib/settlement/version/sources.ts`), after the kernel transaction. Expense create/edit/delete through the kernel never touch them, so after "all settled", a new expense leaves `settlementCompletedAt` set. These flags feed the sync token only. The kernel does not read them.

## 2. Expense lifecycle

Stored as the `Expense` row and `Expense.isDeleted`. Named by `deriveExpenseState()`.

| From | Event | To | Guard | Code |
| --- | --- | --- | --- | --- |
| absent | create | active | active member; payer and split users are current members; splits sum exactly; group currency; group open | `kernel.ts` 687, commit 1249 |
| active | edit | active | same as create; splits are replaced | `kernel.ts` 741, commit 1258 |
| active | delete | deleted | any active member (approved 2026-11-10); group open | `kernel.ts` 593, commit 1273 |
| deleted | edit | refused `NOT_FOUND` 404 "Expense not found" | | `assertExpenseEvent` |
| deleted | delete | refused `NOT_FOUND` 404 "Expense is already deleted" | | `assertExpenseEvent` |

Invariants: `DeletedStaysDeleted` (TLC). A deleted expense never counts in balances: the mutation loader filters `isDeleted: false`, and the read model skips `voided`. E2E check I1 recomputes every test group from rows.

Also a split field: `ExpenseSplit.isPaid` is stored as sent and is never read by balances. It is not a state machine.

## 3. Group membership

Stored as the `GroupMember` row (role `ADMIN` or `MEMBER`) and `GroupParticipant.status` (`ACTIVE`/`DEPARTED`) + `departedAt`. Named by `deriveMemberState()`. The read model shows `ADMIN` as `owner`.

| From | Event | To | Guard | Code |
| --- | --- | --- | --- | --- |
| none, departed | add (`POST /members`) | active | actor is a member; ADMIN role only by an ADMIN | `kernel.ts` 1277, participant reactivated 1292/1304 |
| active | remove self (`POST /leave`) | departed | route: not owner, own balance 0 at the read revision | `leave/route.ts` 45, then kernel |
| active | remove (`DELETE /members`) | departed | self: any member; other: ADMIN. **New:** balance 0 in every currency (`MEMBER_UNSETTLED` 409); not the last ADMIN (`LAST_ADMIN` 409) | `kernel.ts` 865, 1311/1324, 1525 |
| active | role update (`PATCH /members`) | active | ADMIN. **New:** the last ADMIN cannot become MEMBER (`LAST_ADMIN`) | `kernel.ts` 890 |
| departed | an old expense that includes them is edited or deleted, or one of their payments is reversed | departed, now owing or owed (allowed: Bobby's rule, 2026-11-21) | | — |
| departed, owing or owed | records or reverses a payment they are part of | departed | `ensureSettlementActor`: active member, or departed with an unsettled position (access matrix) | `kernel.ts` `ensureSettlementActor` |

Invariants (TLC `GroupMembership.tla`): `HasAdmin`, `BalancesSumToZero`, `MemberRowsAgree`, `DepartedCanSettle` (a departed person who owes money can pay it), and the action property `LeaverSettled` (balance 0 at the moment of leaving). `GroupMembership_newrule_departed_can_owe.cfg` shows, on purpose, that a departed person can owe money again.

The leave guard (`assertLeaverIsSettled`) runs after `membership.remove`, in the same transaction, so a refusal rolls back.

**Rule change 2026-11-21 (Bobby):** the first version of this work refused every write that moved a departed person's balance (`DEPARTED_MEMBER_BALANCE`). That blocked edits and deletes of old expenses, so it was removed. Now such writes are allowed. The debt shows in the group's balances and plan, and the other member, or the departed person, records the payment. The settle routes answer `state: null` when a payment ends the departed person's read access (it was a 500 after commit). Open question: the departed person does not see the group in the app.

## 4. LedgerOperation (idempotency receipt)

Stored in `LedgerOperation(accountId, operationKey)` with `state` (`PENDING`/`COMMITTED`/`FAILED`), `requestHash`, `resultRevision`, `completedAt`. The request hash covers `groupId`, `kind` and `payload`, but not `expectedRevision`.

| From | Event | To | Code |
| --- | --- | --- | --- |
| absent | attempt starts | PENDING (inside its own transaction only) | `kernel.ts` 276 |
| PENDING | commit | COMMITTED, `resultRevision`, `completedAt` | `kernel.ts` 1537 (noop: 1502) |
| PENDING | any refusal or conflict | absent (rollback) | |
| PENDING (invitations only) | group archive | FAILED `GROUP_ARCHIVED` | `groups/[id]/route.ts` 75 |

Decision for an attempt (`decideOperation`, `kernel.ts` 1472): different hash or group → `IDEMPOTENCY_KEY_REUSED` 409; COMMITTED → replay the stored revision; FAILED → 409; otherwise execute.

Because PENDING is rolled back with its transaction, another request only ever sees absent, COMMITTED or FAILED. Prisma's `upsert` here is read-then-insert, so two attempts with one key at the same time make the second insert fail with P2002 once the first commits. **New:** that error is retried (`OperationKeyRaceError`, `kernel.ts` 285/1555; same in the finalize route and group creation), and the retry replays.

## 5. Group revision (`Group.settlementVersion`)

Single serialization point: `reserveRevision` (`kernel.ts` 1360) runs `UPDATE ... WHERE settlementVersion = expected AND isArchived = false`, increments by 1 and holds the row lock to commit. Under READ COMMITTED, a second writer with the same expected revision waits, re-checks the `WHERE` on the new row and gets `REVISION_CONFLICT`. The finalize route uses the same compare-and-set. Archive does a compare-and-set without a bump.

Invariants (TLC): `RevisionIsApplyCount` (each step is one applied operation; no lost update), `NoDoubleApply`, `ReplayStable` (after an operation succeeded, every later answer for its id is that same success). E2E I1: the journal versions of every group are exactly 1..revision.

## Bugs found and fixed

| # | Model / counterexample | Fix |
| --- | --- | --- |
| 1 | `LedgerKernel` Fixes={}: o1 deletes e0, sends again while in flight, commit, retry → route 404 | DELETE/PUT routes also find deleted expenses; the kernel replays or refuses |
| 2 | Fixes={"route"}: two attempts of o1, first prepared, second blocked, commit → second 500 (P2002) | retry on LedgerOperation P2002 (kernel, finalize, group create) |
| 3 | `GroupMembership` Fixes={}: `RemoveSelf("a")` with a owing 1 | balance must be 0 on remove (after-write guard) |
| 4 | Fixes={"balance"}: `SetRole(o,o,member)` / settled `RemoveSelf(o)` → no admin | `assertKeepsAnAdmin` |
| 5 | `GroupMembership_before_departedsettle`: a departed person owes 1 and cannot pay it (kernel `ensureActiveMember` 403) | `ensureSettlementActor` lets a departed person with an unsettled position record or reverse their own payment |
| 5b | (E2E B5a) that payment was saved but answered 500, because the payer could no longer read the group | `getSettleUpStateAfterCommit`: answer 201 with `state: null` |
| 6 | (E2E) self-removal through `DELETE /members` committed but answered 500; the phone retries 5xx forever | members route answers 200 with the receipt when the remover can no longer read the group |
