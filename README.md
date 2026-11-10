# BillBandit

iOS expense-splitting app (`com.billbandit.app`) with Shared Settle Up, Sign in with Apple, and a cobalt + cream illustrated aesthetic.

## Monorepo layout

| Path | What |
|------|------|
| [`BillBandit/`](BillBandit/) | iOS app + Xcode project (hand-kept `project.pbxproj`) |
| [`apps/api/`](apps/api/) | Next.js API-only backend (settlement + mobile auth) |

Production API: **`https://billbandit-api.contenthelper.in`** (Railway Postgres and service hostname).

The old XcodeGen scaffold (`BillBanditApp/`, `project.yml`), `mockups/` and `apps/ios/` were removed on 2026-11-10. They remain in git history.

## Quick start

**iOS**

```bash
open BillBandit/BillBandit.xcodeproj
```

**API on this computer** (port 3000, which Debug builds use; never touches the live server)

```bash
npm install
npm run dev:server
```

**Add test data** (adds only, never deletes; see the top of `apps/api/scripts/dev-data.ts`)

```bash
npm run dev:data                 # a new group with friends, expenses and a payment
npm run dev:data -- signin --launch   # open the simulator app signed in as "You"
```

## More docs

- [HANDOFF.md](HANDOFF.md) — agent handoff, build commands, product status
- [EXTERNAL_BETA_CHECKLIST.md](EXTERNAL_BETA_CHECKLIST.md) — beta release checklist
- [docs/architecture.md](docs/architecture.md) — architecture notes
