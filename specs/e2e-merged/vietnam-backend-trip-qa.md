# Vietnam trip backend QA

- Revision: 241151d3573b5809f6960a86929664b840c065b8
- Base URL: http://127.0.0.1:31301
- API port: 31301 (PID 8693)
- Database URL: postgresql://prateekranka@127.0.0.1:5432/bb_vietnam_test_mwqip8m5_bd3933?schema=[task-schema]
- Schema: ledger_test_8640_cefd80b83a52
- Financial QA group: Vietnam QA mwqip8m5_bd3933 (cmwqipcxu00068gj11aziqv68)
- Empty UI group: Vietnam UI mwqip8m5_bd3933 (cmwqiphv600248gj19a8ks4we)
- Final settlement revision: 8
- Checks: 10 passed, 0 failed

## Commands

```sh
VIETNAM_TRIP_EVIDENCE_DIR='/tmp/int3-e2e/vietnam-evidence' START_VIETNAM_TRIP_SERVER=1 node --import tsx apps/api/scripts/vietnam-trip-qa.ts
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

Credentials for the simulator are in chmod 600 [qa-session.json](/tmp/int3-e2e/vietnam-evidence/qa-session.json).
Task-owned database bb_vietnam_test_mwqip8m5_bd3933 and schema ledger_test_8640_cefd80b83a52 remain available for simulator QA.
