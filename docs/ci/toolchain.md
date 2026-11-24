# API toolchain comparison

Local measurements used Apple Silicon, Node 22.23.2, Bun 1.3.14,
Next 14.2.35, and Prisma 5.22.0. These are single runs in seconds.

| Check | Current | Candidate | Result |
| --- | ---: | ---: | --- |
| Dependency install | 26.25, npm ci | 5.38, Bun first lock import and install | Both installed. CI uses the committed Bun lock. |
| Lint | 2.91, Next ESLint | 0.34, Oxlint | Both exited 0. Oxlint reported additional warnings. |
| Typecheck | 1.87, TypeScript 5.9.3 | 0.66, TypeScript 7.0.2 | Both exited 0. |
| Build | 7.73, Next on Node | 12.22, Next forced onto Bun | Both passed. CI builds Next on Bun. The production image uses Bun for installs and scripts, and keeps the Node runtime for Next and Prisma. |
| Format | No current check | 0.28, Oxfmt | Full-tree check returned 1 because the existing API source needs formatting. Gate changed API files first. |

Oxlint maps 44 of the 47 enabled ESLint rules and retains their severity.
Its additional correctness rules reported 12 warnings. Keep Next ESLint in
CI because Oxlint omits `react/jsx-uses-react`, `react/jsx-uses-vars`, and
`react/no-deprecated`. Run `bun lint` for Oxlint and
`bun run --cwd apps/api lint` for the original Next file scope. Next's
internal build checks still use TypeScript 5 and ESLint. Next 14 uses the
TypeScript JavaScript API, so it keeps TypeScript 5 alongside the native
TypeScript 7 CLI.

The Bun lock is the only lockfile for the API dependency graph. Both CI and the
deployment image use `bun install --frozen-lockfile --ignore-scripts` and
generate the Prisma client explicitly. The next build checks continue to use
their existing ESLint and TypeScript JavaScript APIs.

The Linux Docker comparison built and started the original and candidate
images against separate, empty PostgreSQL 16 databases. The original Docker
build took 98.17 s and the Bun-install image took 35.50 s. Both applied all
15 migrations, reported the requested Git SHA on health, and returned HTTP
401 for an unauthenticated group request. The candidate continues to use
Node for Next and Prisma execution. This comparison exercises startup and
migrations. The seven API E2E scripts separately cover ledger and identity.
[Linux container comparison](https://github.com/My-apps-factory/BillBandit/actions/runs/45373847266)
