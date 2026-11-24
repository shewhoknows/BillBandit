# Known CI issues

## Node + tsx test client crash (open)

- **What:** In merge-group run 45383107521 the `API image` job failed because the test client
  `node --import tsx scripts/any-member-delete-e2e.ts` exited with signal 11 (SIGSEGV) on the
  GitHub runner. The production image itself was healthy in that run (health 200, reviewer
  sign-in 200, authenticated mobile calls passed).
- **Rate:** rare. The unchanged Node client passed 60 of 60 runs in run 45384818748.
- **Decision (owner, 24 Nov 2026):** every E2E test client now runs under Bun, which was already
  the main E2E runtime. The Bun client passed 30 of 30 consecutive image smoke runs
  (run 45384541596). Node still runs inside the production container; only the runner-side
  test clients moved.
- **Still unknown:** the root cause of the Node crash (Node 22.23.5 + tsx/esbuild + the
  Prisma library engine are the candidates). Locally, under colima's QEMU amd64 emulation,
  esbuild inside tsx also crashed with a Go runtime error, which may be an emulation artifact.
  Reopen this if any job that still uses Node shows the same signal.
