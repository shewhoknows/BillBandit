# BillBandit agent rules

These rules apply to this repository, including the active app in `BillBandit/` and the API in `apps/api/`. Preserve existing release, security, and repository gates.

## Testing

- Never write unit tests after you write code.
- Highly prefer E2E tests as the sole testing mechanism. Use them to verify complex features work. At the end of E2E tests, produce a verifiable and repeatable artifact.
- If you must test a system in isolation, first write down all the ways it could fail, then write the code.

An E2E artifact must identify the revision and environment, list the exact replay command or steps, and include the observed result and evidence location. Do not claim a workflow passed when it was not exercised. Preserve isolation tests only when they catch a real failure that the E2E coverage misses.
