# Lock apps/api shape (API-only Next.js)

Type: grilling
Status: resolved
Blocked by: 02

## Question

Is `apps/api` a Next.js App Router project with **API routes only** (no pages UI), and how do we strip FairShare web UI while keeping middleware, instrumentation, and health?

## Answer

(Round 2)

Yes — `apps/api` is Next.js **API routes only** (health + mobile/settlement/group/expense APIs). No ported dashboard UI. Keep `instrumentation.ts` (outbox bootstrap), slim middleware as needed for API, Prisma migrations under `apps/api`.
