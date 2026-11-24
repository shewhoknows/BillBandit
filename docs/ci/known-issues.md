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
- **Root cause of the Node crash:** not determined (Node 22.23.5 + tsx/esbuild + the Prisma library
  engine are the candidates). It no longer affects CI because nothing in CI runs Node + tsx.
