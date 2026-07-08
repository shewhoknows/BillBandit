# BillBandit

A native SwiftUI iOS expense splitter with a warm receipt-ledger aesthetic: cobalt-blue
surfaces, cream receipt cards, typewriter labels, and handwritten user-entered content.
Backed by the production Railway API — not a local prototype.

## Requirements

- Xcode 26+ (built with Xcode 27)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

```sh
xcodegen generate        # produces BillBandit.xcodeproj from project.yml
open BillBandit.xcodeproj
```

Build and run the `BillBandit` scheme on an iOS simulator. Debug builds talk to the
production API (`https://billbandit-api.contenthelper.in`); previews and tests use
in-process mock repositories and never touch the network.

Run tests:

```sh
xcodebuild test -project BillBandit.xcodeproj -scheme BillBandit \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Project layout

```
BillBanditApp/
  Sources/
    App/           # entry point, root navigation, session state, DI container
    Domain/        # models, Money, SplitEngine, SettlementEngine, validation
    Data/          # API client, repositories, DEBUG-only mock services
    Features/      # Auth, Trips, Friends, Expenses, Ledger, Balances, FinalBill, Settings
    DesignSystem/  # color/typography/spacing tokens, reusable receipt-style components
  Resources/       # asset catalog (mascots, stamps), bundled fonts
  Tests/           # unit tests (domain engines, repositories, parsers)
Config/            # per-configuration xcconfig (API base URL)
docs/              # architecture notes, API contract reference
```

## Backend

The source of truth is the Railway-hosted mobile API. See
[docs/api-contracts.md](docs/api-contracts.md) for the discovered endpoint contracts
and which endpoints do not exist yet. Missing capabilities are hidden or
feature-flagged in the UI — production code never fakes a live response.

## App Store Connect

The bundle identifier is `com.eshabhoon.fairshare` and must not change — the existing
App Store Connect app and the backend's Sign in with Apple audience both depend on it.
The display name is BillBandit.

## Fonts

User-entered content renders in [Caveat](https://fonts.google.com/specimen/Caveat)
(SIL Open Font License, see `BillBanditApp/Resources/Fonts/OFL-Caveat.txt`). Display,
label, and body roles use the system serif, monospaced, and default designs.
