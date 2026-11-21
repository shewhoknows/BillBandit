# Vietnam trip backend QA

- Revision: c6c092abdc8b46f9f30d56742ef7ad28158c03b7
- Base URL: http://127.0.0.1:31301
- API port: 31301 (PID 5191)
- Database URL: postgresql://prateekranka@127.0.0.1:5432/bb_vietnam_test_mwqgy098_a27f70?schema=[task-schema]
- Schema: ledger_test_5137_372d75cad50f
- Financial QA group: Vietnam QA mwqgy098_a27f70 (cmwqgy4fc0006eneiajkcrern)
- Empty UI group: Vietnam UI mwqgy098_a27f70 (cmwqgyb700024enein9qu7zna)
- Final settlement revision: 8
- Checks: 10 passed, 0 failed

## Commands

```sh
VIETNAM_TRIP_EVIDENCE_DIR='/tmp/int-e2e/vietnam-evidence' START_VIETNAM_TRIP_SERVER=1 node --import tsx apps/api/scripts/vietnam-trip-qa.ts
```

## Covered behavior

- Real HTTP auth, username claims, friend invitation, and group creation.
- VND exact odd total 100001 with 50001/50000 exact splits.
- Expense edit revision, percentage splits, and shares 50001/50000.
- Mixed-currency rejection and separate INR control-group aggregate.
- Outsider read/write denial.
- Partial settlement, full settlement, zero remaining plan, and exactly-once retry.
- Proxy-dropped expense response replay and cleanup.

## Check results

- PASS HTTP auth, username claims, and friend invitation
- PASS VND group creation through accepted friendship
- PASS Outsider group read and expense write denied
- PASS Odd exact expense and revisioned edit
- PASS Percentage and shares split preservation
- PASS Mixed-currency expense rejected
- PASS Partial/full settlement clears plan and retries exactly once
- PASS Proxy-dropped expense response replays one UUID exactly once
- PASS Separate INR control aggregate remains independent
- PASS Empty VND UI group has two members and no expenses

Credentials for the simulator are in chmod 600 [qa-session.json](/tmp/int-e2e/vietnam-evidence/qa-session.json).
Task-owned database bb_vietnam_test_mwqgy098_a27f70 and schema ledger_test_5137_372d75cad50f remain available for simulator QA.
