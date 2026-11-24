# API toolchain comparison

Local measurements used Apple Silicon, Node 22.23.2, Bun 1.3.14,
Next 14.2.35, and Prisma 5.22.0. These are single runs in seconds.

| Check | Current | Candidate | Result |
| --- | ---: | ---: | --- |
| Dependency install | 26.25, npm ci | 5.38, Bun first lock import and install | Both installed. CI uses the committed Bun lock. |
| Lint | 2.91, Next ESLint | 0.34, Oxlint | Both exited 0. Oxlint reported additional warnings. |
| Typecheck | 1.87, TypeScript 5.9.3 | 0.66, TypeScript 7.0.2 | Both exited 0. |
| Build | 7.73, Next on Node | 12.22, Next forced onto Bun | Both passed. Use the Bun build in CI and retain the production Docker entry point until Linux build and runtime match. |
| Format | No current check | 0.28, Oxfmt | Full-tree check returned 1 because the existing API source needs formatting. Gate changed API files first. |

Oxlint maps 44 of the 47 enabled ESLint rules and retains their severity.
Its additional correctness rules reported 12 warnings. Keep Next ESLint in
CI because Oxlint omits `react/jsx-uses-react`, `react/jsx-uses-vars`, and
`react/no-deprecated`. Run `bun lint` for Oxlint and
`bun run --cwd apps/api lint` for the original Next file scope. Next's
internal build checks still use TypeScript 5 and ESLint. Next 14 uses the
TypeScript JavaScript API, so it keeps TypeScript 5 alongside the native
TypeScript 7 CLI.

The root npm lock remains for the Railway Dockerfile. The CI Bun lock pins
the candidate dependency graph. CI uses `bun install --frozen-lockfile`
and explicitly generates Prisma rather than trusting dependency scripts.
