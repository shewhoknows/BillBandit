# iOS app (`apps/ios`)

This folder is a **monorepo pointer**, not a second copy of the Xcode project.

The BillBandit iOS app lives at the repo root:

**`BillBandit/BillBandit.xcodeproj`**

We kept that path stable (instead of moving sources under `apps/ios/`) to avoid `xcodeproj`, signing, and SPM churn. See the root README for the monorepo layout notes.

## Open in Xcode

```bash
open ../../BillBandit/BillBandit.xcodeproj
```

Or from repo root:

```bash
open BillBandit/BillBandit.xcodeproj
```

## Production API

Shared Settle Up talks to **`https://billbandit-api.contenthelper.in`** (see `BillBandit/BillBandit/Settlement/SettlementAPIConfiguration.swift`). Debug builds default to `http://127.0.0.1:3000` when `apps/api` runs locally.
