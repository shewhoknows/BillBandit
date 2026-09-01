# Ledger Contract v2

Status: frozen contract fixture for Phase 1 / Wave 1.

## Canonical target

The shipping iOS target is the root XcodeGen project named `BillBandit`, generated from the root `project.yml`. Its application target sources are the `BillBanditApp` tree. The older `BillBandit/` tree is not a second ledger target and is not part of this contract's implementation surface.

This decision is about the application target only. It does not change the API authority decision: the production API is the sole authority for shared groups, membership, expenses, splits, balances, settlements, reversals, activity, and history. SwiftData is an account-scoped offline cache and durable mutation queue. CloudKit ledger records are imported once and then become read-only recovery data; there is no permanent dual-write mode.

## Contract identity and exact money

Every v2 JSON document carries `contractVersion: 2`. A v2 client identifies itself with `Client-Contract: ledger-v2` and `Client-Compatibility: ledger-v2`.

The only money representation is:

```json
{
  "minorUnits": "12345",
  "currencyCode": "INR",
  "currencyExponent": 2
}
```

`minorUnits` is a canonical signed-integer string. It may be negative or zero, but it may not contain a decimal point, a leading zero, a plus sign, or negative zero. Money values are never JSON numbers and never floating-point major-unit values. The currency registry is explicit and versioned; there is no default exponent. The v2 fixtures cover INR (2), JPY (0), and KWD (3).

All arithmetic is integer arithmetic on minor units. Addition, subtraction, equality, and settlement allocation require the same currency code and exponent. Mixed currencies are retained as separate balance entries and are never netted or converted implicitly. Split amounts must sum to the expense amount exactly, including signed corrections and zero-value expenses. Percentages are metadata strings and are not used to recalculate exact split amounts.

## Identity and scope

Server IDs are the identity keys:

- `accountId` identifies an API account.
- `groupId` identifies a server-backed shared group.
- `memberId` identifies a ledger membership in that group.
- `expenseId`, `splitId`, `settlementId`, `reversalId`, `planTransferId`, and `operationId` identify their records.

Display names, email addresses, and local cache IDs are not identity keys. `localIdentityId` may be retained as a reconciliation hint, but it cannot select or merge a ledger member.

Every shared read has a `scope` with `kind: "shared"` and `localOnly: false`. Local-only groups are not serialized as shared groups, members, expenses, balances, plans, or history. A fixture may list their IDs under `excludedLocalOnlyGroupIds` solely to prove the boundary; that list is not a shared read model.

## Read model and authority

The read envelope contains:

- `revision`: the current server ledger revision. This is the API projection of the persisted `Group.settlementVersion`; clients do not maintain a second financial revision.
- `readRevision`: the revision represented by the returned data.
- `pendingOperationIds`: queued client operations that have not been incorporated into the server snapshot.
- `migration`: import state and the explicit `dualWriteEnabled: false` marker.
- `stale`: whether the cache is safe to present as current and why it is stale when it is not.
- `authority`: server-authority markers for the read model, balances, settlement plan/history, and identity.

The group read model includes members, expenses and exact splits, per-member balances, per-currency totals, the current account's balance, the complete settlement plan, settlement/reversal history, and activity. The account read model includes shared-group summaries, the current account balance, pending operation records, and migration/cache state. These are projections of one server-derived snapshot, so dashboard, group detail, invoice, Settle Up, explanations, and history must consume these same surfaces.

`serverAuthoritative: true` means the data can replace the matching cache projection. `cacheRole: "offline-cache"` means the client may display and queue against it offline, but it cannot make the data authoritative for other devices.

## Mutation headers and envelopes

Every shared mutation requires these headers:

| Header | Semantics |
| --- | --- |
| `Idempotency-Key` | Stable opaque key for one logical mutation. A retry of the same operation reuses it. |
| `Expected-Revision` | Decimal string containing the revision the client read before writing. |
| `Client-Contract` | Must be `ledger-v2`. |
| `Client-Compatibility` | Must be `ledger-v2`; this release has no v1 write compatibility mode. |

The body also carries a stable `operationId` for the durable offline queue. The server hashes the canonical request body before recording the idempotency receipt.

An applied mutation returns `outcome: "applied"` and advances `revision` exactly once. A retry with the same key and request hash returns `outcome: "replayed"`, the original record/result, and the original result revision; it does not advance the revision. Reusing a key with a different request hash returns `IDEMPOTENCY_KEY_REUSED` and does not write.

If `Expected-Revision` does not equal the server revision, the server returns a `REVISION_CONFLICT` envelope with the expected revision, current authoritative revision, retryability, and an optional authoritative snapshot. The client must reconcile and construct a new request; it must not silently overwrite the current ledger. Domain write, revision event, idempotency receipt, and outbox invalidation are one server transaction.

## Migration and rollback markers

`migration.status: "complete"` means a CloudKit ledger was imported exactly once and the API projection is now authoritative. `dualWriteEnabled` is permanently false after cutover. `recoveryReadOnly` indicates that the old source can be consulted for repair/export without becoming a write authority. `pending`, `in_progress`, and `blocked` states are explicit and must gate shared writes until the server declares compatibility.

## Fixtures and verification

`apps/api/test/fixtures/ledger-v2/shared-ledger.json` is one complete shared read fixture. It contains all four split methods, INR/JPY/KWD, signed and zero money, mixed-currency balances, active and reversed settlements, plan/history/activity surfaces, canonical identity IDs, migration/cache markers, and a pending retry. It contains no local-only group object.

`apps/api/test/fixtures/ledger-v2/mutation-envelopes.json` covers the required headers, an applied mutation, an idempotent replay, a revision conflict, and an idempotency-key conflict.

The contract types and runtime validators live in `apps/api/lib/ledger-contract/`. The contract test loads the JSON fixtures, validates every money field and cross-reference, performs a stable JSON round trip, and verifies the envelope semantics.
