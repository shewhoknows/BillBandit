# BillBandit monorepo layout (retire FairShare)

Label: `wayfinder:layout`

This document records the **physical** repo layout after consolidating FairShare settlement APIs into BillBandit. It supersedes the aspirational `apps/ios/` path from issue 01 — we kept the Xcode project where it already lived to avoid `xcodeproj` churn.

## Top-level map

| Path | Role |
|------|------|
| `BillBandit/` | **iOS app** — Xcode project (`BillBandit.xcodeproj`), SwiftUI + SwiftData, Shared Settle Up client |
| `apps/api/` | **Backend** — Next.js App Router, API routes only (no web UI) |
| `apps/ios/` | **Pointer** — README only; opens `BillBandit/` (not a second copy of the app) |
| `CloudKit/` | CloudKit schema / collaboration notes |
| `BillBandit-Raccoon-SVG/` | Official mascot source SVGs |
| `mockups/` | Throwaway design mockups (not app source) |
| `.scratch/` | Agent scratch, derived data, retire-fairshare planning |

## iOS — why `BillBandit/` not `apps/ios/BillBandit/`

The published app (`com.billbandit.app`) has shipped from `BillBandit/` for years. Moving the `.xcodeproj`, SPM package resolution, entitlements, export plists, and CI/signing paths would touch dozens of references with no product benefit.

**Decision (Lane E, 2026-07-30):** Treat `BillBandit/` as the canonical iOS tree. Use `apps/ios/README.md` as the monorepo entry point for agents and humans who expect an `apps/` sibling next to `apps/api/`.

### Open the iOS project

```bash
open BillBandit/BillBandit.xcodeproj
```

### Build (simulator)

```bash
cd BillBandit
xcodebuild -project BillBandit.xcodeproj -scheme BillBandit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build
```

See `HANDOFF.md` for full build/test/archive commands.

## API — `apps/api/`

Fresh Next.js scaffold + copied FairShare settlement/mobile routes (see issue 09). Deploy target: Railway, same Postgres and hostname as before cutover.

| Concern | Location |
|---------|----------|
| Mobile auth (SIWA + username) | `apps/api/app/api/mobile/auth/**` |
| Settle-up / settlements | `apps/api/app/api/**` (settlement routes) |
| Prisma schema + migrations | `apps/api/prisma/` |
| Health / Railway | `apps/api/app/api/health/**`, Dockerfile |

Production URL (unchanged): **`https://billbandit-api.contenthelper.in`**

## iOS ↔ API wiring

The iOS Settlement client resolves its base URL in `BillBandit/BillBandit/Settlement/SettlementAPIConfiguration.swift`:

- **Release:** `https://billbandit-api.contenthelper.in`
- **Debug:** `http://127.0.0.1:3000` (local `apps/api` dev server)
- **Override:** `API_BASE_URL` in Info.plist / build settings

Keychain session for mobile JWT: service `com.billbandit.app.mobile-api`.

## FairShare archive

FairShare (`/Users/prateekranka/Cowork/FairShare`) is archived read-only after cutover. BillBandit day-to-day work does not require FairShare. FairShare Ink (`com.eshabhoon.fairshare`) is **not** merged into this repo.

## Related docs

- [map.md](map.md) — retire scope and decisions
- [issues/10-execution-checklist.md](issues/10-execution-checklist.md) — ordered cutover steps
- [HANDOFF.md](../HANDOFF.md) — iOS product handoff (living doc)
