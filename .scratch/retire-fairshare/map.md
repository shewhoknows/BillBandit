# Retire FairShare → BillBandit

Label: `wayfinder:map`

## Destination

BillBandit (`shewhoknows/BillBandit`) owns the product iOS app (`com.billbandit.app`) and the backend needed for Shared Settle Up plus Sign in with Apple + unique username. Production continues to serve `https://billbandit-api.contenthelper.in`. FairShare is archived (read-only) and no longer required for BillBandit day-to-day work.

## Status (2026-07-30)

**Code migration complete (lanes A–E).** `apps/api` is landed in the BillBandit working tree with auth, settlement, ledger, health, Prisma, Dockerfile, and GHA deploy workflow. iOS remains at `BillBandit/` with docs-only `apps/ios` pointer.

**Remaining:** human Railway/CI cutover, prod verification, FairShare archive. Playbook: [railway-cutover-ops.md](railway-cutover-ops.md). Checklist: [issues/10-execution-checklist.md](issues/10-execution-checklist.md) (items 5–8).

## Notes

- Domain: iOS + Next.js API consolidation; CloudKit stays in BillBandit iOS.
- Skills: wayfinder, batch-grill-me.
- Preferences: plan first; no FairShare web UI; no Ink iOS merge; archive FairShare don’t delete; same Railway DB/URL.
- Working trees: BillBandit at `/Users/prateekranka/Cowork/BillBandit-published`; FairShare at `/Users/prateekranka/Cowork/FairShare`.
- Research: [research-api-surface.md](research-api-surface.md)

## Decisions so far

- [Lock destination and retire scope](issues/01-lock-destination-and-retire-scope.md) — BillBandit owns iOS + API; SIWA/username; no web; Ink out; `apps/ios`+`apps/api`; archive FairShare.
- [Research FairShare settlement dependency graph](issues/03-research-settlement-dependency-graph.md) — auth+settle deps; ledger needs Postgres expenses; explanation gap.
- [Define minimal API surface to move](issues/02-define-minimal-api-surface.md) — auth + settle + mobile group/expense APIs + health.
- [Lock database and production URL ownership](issues/04-lock-database-and-prod-url.md) — same Railway Postgres + hostname.
- [Lock apps/api shape (API-only Next.js)](issues/06-lock-apps-api-shape.md) — API routes only. **Delivered:** `apps/api` with 15 route handlers, no web pages.
- [Lock CloudKit vs server group source of truth](issues/07-lock-cloudkit-vs-server-source-of-truth.md) — CloudKit UX; mirror to Postgres when linked.
- [Decide transfer explanation endpoint](issues/08-decide-transfer-explanation-endpoint.md) — stub for cutover; real endpoint later.
- [Lock physical move method](issues/09-lock-physical-move-method.md) — fresh scaffold + copy selected trees. **Delivered:** scaffold + selective copy (lanes A–D).
- [Lock Railway and CI cutover sequence](issues/05-lock-railway-ci-cutover.md) — land API → point Railway → disable FairShare deploy → verify → archive. **Code landed; ops pending.**

## Layout (Lane E, 2026-07-30)

- iOS stays at **`BillBandit/`**; `apps/ios/README.md` is a pointer only.
- API at **`apps/api/`** (Next.js API-only, workspace root `package.json`).
- See [monorepo-layout.md](monorepo-layout.md) and root `README.md`.

## Out of scope

- Porting FairShare Ink UI / `com.eshabhoon.fairshare`.
- Porting FairShare web dashboard pages.
- Deleting FairShare GitHub repo.
- Reworking CloudKit collaboration core.
- Implementing transfer explanation as cutover blocker.

## Way clear?

Decision tickets 01–09 are resolved. Code migration (checklist items 1–4) is complete. Proceed with human ops cutover per [railway-cutover-ops.md](railway-cutover-ops.md).
