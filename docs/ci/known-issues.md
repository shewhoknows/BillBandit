# Known CI issues

## Node + tsx test client crash (open)

- **What:** In merge-group run 45383107521 the `API image` job failed because the test client
  `node --import tsx scripts/any-member-delete-e2e.ts` exited with signal 11 (SIGSEGV) on the
  GitHub runner. The production image itself was healthy in that run (health 200, reviewer
  sign-in 200, authenticated mobile calls passed).
- **Rate:** rare. The unchanged Node client passed 60 of 60 runs in run 45384818748.
- **Decision (owner, 24 Nov 2026):** the image smoke clients and every E2E script that can run under Bun now do, which was already
  the main E2E runtime. The Bun client passed 30 of 30 consecutive image smoke runs
  (run 45384541596). Node still runs inside the production container; only the runner-side
  test clients moved.
- **Still unknown:** the root cause of the Node crash (Node 22.23.5 + tsx/esbuild + the
  Prisma library engine are the candidates). Locally, under colima's QEMU amd64 emulation,
  esbuild inside tsx also crashed with a Go runtime error, which may be an emulation artifact.
  Three API E2E scripts still run under Node because they fail under Bun: `polish-e2e.ts` and
  `vietnam-trip-qa.ts` (they start their own server) and `identity-friends-import-e2e.ts`. They carry
  the same small crash risk. Reopen this if any of them shows the same signal.
