# End-to-end results on the merged branch (2026-11-21)

All server E2E scripts were run against one local API built from the merged
branch `fix/state-machines-tla` (before the final commit; the files carry the
merge revision `c6c092a`). Environment: Linux, Node 22, PostgreSQL 16 on
localhost, Next dev server on port 3200, database `billbandit_int`, seeded
with `npx tsx scripts/dev-data.ts scenario`. Dev server env:
`MOBILE_AUTH_MOCK_APPLE_SUBJECT=ifi-e2e-apple-subject MOBILE_AUTH_MOCK_APPLE_EMAIL=ifi-e2e@dev.billbandit.local`.

| Script | Result | File |
|---|---|---|
| settlement-e2e.ts | 11 PASS, 0 FAIL | settlement.txt |
| ledger-kernel-e2e.ts | 20 passed, 0 failed | ledger-kernel.txt |
| identity-friends-import-e2e.ts | 19/19 PASS | identity-friends-import.txt |
| any-member-delete-e2e.ts (run after ledger-kernel, which adds dev_zoya) | 8/8 PASS | any-member-delete.txt |
| polish-e2e.ts (`START_POLISH_SERVER=1`, own server :31401) | 10 passed, 0 failed | polish.txt |
| vietnam-trip-qa.ts (`START_VIETNAM_TRIP_SERVER=1 VIETNAM_TRIP_BASE_URL=http://127.0.0.1:31301`) | 10 checks passed | vietnam.txt, vietnam-backend-trip-qa.md |

Replay commands are at the top of each file and in docs/state-machines/README.md.
The iOS app was not built or run here.
