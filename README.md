# BillBandit

iOS expense-splitting app (`com.billbandit.app`) with Shared Settle Up, Sign in with Apple, and a cobalt + cream illustrated aesthetic.

## Monorepo layout

| Path | What |
|------|------|
| [`BillBandit/`](BillBandit/) | iOS app + Xcode project (canonical — not under `apps/ios/`) |
| [`apps/api/`](apps/api/) | Next.js API-only backend (settlement + mobile auth) |
| [`apps/ios/`](apps/ios/) | Pointer README → open `BillBandit/` |

Production API: **`https://billbandit-api.contenthelper.in`** (same Railway Postgres/hostname after FairShare retire).

Full layout rationale: [.scratch/retire-fairshare/monorepo-layout.md](.scratch/retire-fairshare/monorepo-layout.md)

## Quick start

**iOS**

```bash
open BillBandit/BillBandit.xcodeproj
```

**API** (local dev — see `apps/api/` once scaffold is complete)

```bash
cd apps/api && npm install && npm run dev
```

## Merged local history (XcodeGen scaffold)

The nine pre-consolidation commits are preserved on `main` via merge. They added an alternate XcodeGen-based tree at repo root:

- [`BillBanditApp/`](BillBanditApp/) — SwiftUI app sources, tests, and UI tests from that lineage
- [`project.yml`](project.yml) — XcodeGen spec (`xcodegen generate` → root `BillBandit.xcodeproj`)
- [`docs/`](docs/) — architecture, API contracts, design tokens from that scaffold

Use **`BillBandit/BillBandit.xcodeproj`** for the canonical app; the root scaffold is retained for reference and cherry-picking.

## More docs

- [HANDOFF.md](HANDOFF.md) — agent handoff, build commands, product status
- [EXTERNAL_BETA_CHECKLIST.md](EXTERNAL_BETA_CHECKLIST.md) — beta release checklist
- [.scratch/retire-fairshare/map.md](.scratch/retire-fairshare/map.md) — FairShare → BillBandit migration map
- [docs/architecture.md](docs/architecture.md) — notes from the merged XcodeGen scaffold
