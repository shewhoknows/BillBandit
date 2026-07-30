# Execution checklist — retire FairShare into BillBandit

Type: task
Status: code complete — human ops pending (items 5–8)
Blocked by: none (planning tickets 01–09 resolved; lanes A–E delivered)

## Question

What is the ordered execution checklist once planning is confirmed?

## Checklist

1. Scaffold `apps/api` (Next.js API-only) under BillBandit-published / `shewhoknows/BillBandit` — **done (Lane A)**
2. Copy from FairShare into `apps/api`:
   - mobile auth routes + libs — **done (Lane B)**
   - settle-up / settlements / settings / realtime routes + `lib/settlement/**` (skip legacy/backfill) — **done (Lane C)**
   - mobile group/expense APIs that populate ledger — **done (Lane D)**
   - Prisma schema + migrations, `instrumentation.ts`, Dockerfile, railway/health — **done (Lane A)**
3. Relocate/move iOS project under `apps/ios` — **done (Lane E): left in place**
   - Canonical path: `BillBandit/` (Xcode project at `BillBandit/BillBandit.xcodeproj`)
   - `apps/ios/README.md` pointer doc added
   - Layout documented in `.scratch/retire-fairshare/monorepo-layout.md` + root `README.md`
   - Prod API URL documented in `SettlementAPIConfiguration.swift` (`https://billbandit-api.contenthelper.in`)
4. Wire root package scripts + GHA deploy on BillBandit `main` (mirror FairShare deploy.yml → Railway) — **done (Lane A)**
   - Root `package.json` workspaces + scripts
   - `.github/workflows/deploy.yml` + deploy-info scripts
   - `Dockerfile`, `railway.toml`
5. Ensure Railway env: `DATABASE_URL`, `MOBILE_JWT_SECRET`, Apple audience IDs, Pusher vars — **human-pending** (owner: **repo admin / ops**)
   - See [railway-cutover-ops.md](../railway-cutover-ops.md) §3
6. Point Railway at BillBandit `main`; disable FairShare deploy — **human-pending** (owner: **repo admin / ops**)
   - See [railway-cutover-ops.md](../railway-cutover-ops.md) §§1–2, 4
7. Verify prod smoke + live sims (per ticket 05) — **human-pending** (owner: **repo admin / QA**)
   - Curl smoke: health 200, settle-up 401 (no Bearer)
   - SIWA + username on both sims; Shared Settle Up load + one mutation on LiveSettle-Test
   - See [railway-cutover-ops.md](../railway-cutover-ops.md) §5
8. Archive FairShare repo — **human-pending** (owner: **repo admin**)
   - After item 7 passes; set FairShare GitHub repo read-only

9. Later (not cutover): transfer explanation endpoint; optional CloudKit→server sync polish

## Lane delivery summary (2026-07-30)

| Lane | Scope | Status |
|------|-------|--------|
| A | API scaffold, Prisma, Dockerfile, GHA deploy | ✅ |
| B | Mobile auth (SIWA + username) | ✅ |
| C | Settlement routes + `lib/settlement/**` | ✅ |
| D | Mobile groups/expenses (ledger population) | ✅ |
| E | iOS layout docs + prod URL comment | ✅ |

## Local verification (agent)

```bash
cd /Users/prateekranka/Cowork/BillBandit-published
npm install && npm run db:generate
npm run typecheck   # ✅ 2026-07-30
npm run build       # ✅ 2026-07-30 — 15 API routes
```

## Answer

Items 1–4 are complete in the working tree. Execute items 5–8 as human ops (do not automate Railway/GitHub secret changes from agents). Ops playbook: [railway-cutover-ops.md](../railway-cutover-ops.md).
