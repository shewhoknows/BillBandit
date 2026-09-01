# BillBandit architecture

## Principles

- SwiftUI + Apple-native frameworks only; no external dependencies.
- Business logic lives in tested Domain services, never in views.
- The Railway API is the source of truth. Local state is a cache/performance aid.
- Production code never fakes a backend response. Missing endpoints surface as
  hidden/flagged UI plus an entry in [api-contracts.md](api-contracts.md).
- Previews and unit tests run against in-process mock repositories (DEBUG only).

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

- Friend codes / invite codes / trip invite links — no endpoints. UI hidden behind
  `FeatureFlags`.
- Reopening a finalized trip — no un-finalize endpoint. Reopen is unavailable in
  production UI; finalize is guarded by a confirmation.
- Standalone friends list — the backend models friendships but exposes no API;
  the app derives "people you've traveled with" from group memberships.
- Member removal, group edit/delete — no endpoints; UI does not offer them.

## Conventions

- Swift 6 language mode.
- Dates cross the wire as ISO-8601 strings.
- Errors from Data surface as typed `APIError`; view models translate them into
  human copy.
- Currency defaults to INR; a trip has exactly one currency; no conversion.
