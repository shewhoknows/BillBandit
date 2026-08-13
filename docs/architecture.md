# BillBandit architecture

## Principles

- SwiftUI + Apple-native frameworks only; no external dependencies.
- Business logic lives in tested Domain services, never in views.
- The Railway API is the source of truth. Local state is a cache/performance aid.
- Production code never fakes a backend response. Missing endpoints surface as
  hidden/flagged UI plus an entry in [api-contracts.md](api-contracts.md).
- Previews and unit tests run against in-process mock repositories (DEBUG only).

## 2026-08-12 server-authoritative social flow

The Railway API is the sole authority for friends, groups and expenses. SwiftData
and other device stores can cache API data, but they must not create a second
social identity or shared ledger. CloudKit collaboration records from older builds
are legacy data. They are not authoritative for this flow.

The canonical sequence is:

1. One account creates a reusable five-character code with
   `POST /api/mobile/friends/invitations`.
2. The other account claims it with
   `POST /api/mobile/friends/invitations/{code}/claim`.
3. Both accounts load the same accepted edge from `GET /api/mobile/friends`.
4. The creator sends accepted friend account IDs in `memberAccountIds` to
   `POST /api/mobile/groups`. One transaction creates all memberships and group
   participants.
5. Canonical expense and settlement mutations increment the group ledger revision.
   Both accounts then read the same group, exact amounts and opposite balances.

Friend deletion through `DELETE /api/mobile/friends/{accountId}` is a social
operation only. It removes the accepted friendship edge. Existing group membership
and all expense, split, settlement and ledger history stay intact.

Pusher can reduce notification delay, but correctness does not depend on it. While
the app is active, it can poll `GET /api/mobile/sync-token`. An unchanged SHA-256
token needs no full reload. A changed token causes a friends/groups refresh. The
token covers friend add/remove/profile updates, group discovery/removal/name/member
changes, and canonical group revision changes. The response contains no raw IDs.

Validation on 2026-08-12: TypeScript typecheck passes, the five focused friend
tests pass, the authenticated sync-token integration test passes, and the full
API ledger suite passes 34/34.

## Layers

```
Features (SwiftUI views + view models)
   │  depends on
Domain (models, Money, SplitEngine, SettlementEngine, validation)
   │  persisted/synced through
Data (APIClient, repositories, DEBUG mocks)
```

- **App/** — entry point, root navigation, session store, dependency container.
- **Domain/** — pure Swift, no UIKit/SwiftUI imports. `Money` stores minor units
  internally; the API encodes decimal major units (see api-contracts.md → Money
  semantics). SplitEngine and SettlementEngine are deterministic and fully unit-tested.
- **Data/** — `APIClient` (URLSession, async/await, bearer JWT from Keychain),
  one repository protocol per aggregate (auth, trips, expenses, participants,
  settlements), a live implementation backed by the API, and mock implementations
  compiled only in DEBUG.
- **Features/** — one folder per feature; view models are `@MainActor @Observable`
  classes that talk to repository protocols.
- **DesignSystem/** — tokens (colors, typography, spacing, shapes) and reusable
  receipt-style components. No feature logic.

## Backend gaps and feature flags

Backend capabilities the API does not provide yet (kept honest in UI):

- Reopening a finalized trip — no un-finalize endpoint. Reopen is unavailable in
  production UI; finalize is guarded by a confirmation.
- Standalone group edit/delete endpoints do not exist. Canonical membership
  mutations support add, role update and removal.

## Conventions

- Swift 6 language mode.
- Dates cross the wire as ISO-8601 strings.
- Errors from Data surface as typed `APIError`; view models translate them into
  human copy.
- Currency defaults to INR; a trip has exactly one currency; no conversion.
