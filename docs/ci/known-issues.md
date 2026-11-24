# Known CI issues

## Node + tsx test client crash (resolved by removing Node from the test path)

- **What:** In merge-group run 45383107521 the `API image` job failed because the test client
  `node --import tsx scripts/any-member-delete-e2e.ts` exited with signal 11 (SIGSEGV) on the
  GitHub runner. The production image itself was healthy in that run (health 200, reviewer
  sign-in 200, authenticated mobile calls passed).
- **Rate:** rare. The unchanged Node client passed 60 of 60 runs in run 45384818748.
- **Decision (owner, 24 Nov 2026):** no Node and no tsx anywhere in the test or tooling path.
  Every E2E script, the image smoke clients, `dev:server`, `dev:data`, `review:reset` and
  `review:teardown` run under Bun. `polish-e2e.ts` and `vietnam-trip-qa.ts` were rewritten to mint
  tokens with `bun --eval` and start Next with `bun run`. The `tsx` dependency is removed.
  The Bun image client passed 30 of 30 consecutive image smoke runs (run 45384541596).
- **Not changed:** the production container still runs Next.js on Node (`node:20-alpine` base);
  only the build and install steps use Bun.
- **Still Node, by shebang:** the Next.js and Prisma CLIs start with `#!/usr/bin/env node`, so
  `bun run dev`, `next start` and `prisma migrate deploy` run on the runner's Node even though Bun
  launches them. Only our own scripts are guaranteed to run on Bun. Xcode Cloud installs Node for
  this reason (`BillBandit/ci_scripts/ci_pre_xcodebuild.sh`).
- **Root cause of the Node crash:** not determined (Node 22.23.5 + tsx/esbuild + the Prisma library
  engine are the candidates). It no longer affects CI because nothing in CI runs Node + tsx.

## Job-budget overruns failed required checks (fixed in #54)

- **What:** the 15s setup budget failed required checks on runner jitter alone: 15.03s on #47,
  15.99s on #37 (run 45433179992), 16.84s on main (run 45429908797). Checkout varies 5 to 8s by
  runner.
- **Fix:** an overrun is now a warning in the job and its step summary; more than twice the budget
  still fails.

## Next readiness missed on macOS under Bun (fixed in #55)

- **What:** `vietnam-trip-qa.ts` waited for Next's `Ready` line with `fs.watch`. Under Bun on
  macOS the watcher reports the first appends and then stops, so the script timed out after 90s
  though Next was ready in under a second. Linux CI was unaffected; the Xcode Cloud fixture prep
  (#39) runs on macOS.
- **Fix:** `vietnam-trip-qa.ts` and `polish-e2e.ts` poll both log files every 200ms.

## Prisma migrate stalled on one runner (open, seen once)

- **What:** in PR run 45436084334 (#51, which changes no API code), shard 4 started two API
  servers and both sat in `prisma migrate deploy` for the whole 12s startup limit without printing
  `Prisma schema loaded`. The same runner took 13s to read the timing artifacts (about 5s
  normally), so the runner was slow overall. The same scripts with the same cache passed in every
  other run.
- **Handling:** the failed job was re-run once by hand on the PR to check for a repeat, and passed.
  Nothing retries automatically, and the merge queue runs the full suite.
- **If it repeats:** set `CHECKPOINT_DISABLE=1` in the E2E env (Prisma's version check is the one
  network call in that step) and capture timestamps around `prisma migrate deploy` in
  `dev-server.ts`.
