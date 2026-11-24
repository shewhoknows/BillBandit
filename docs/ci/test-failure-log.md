# Two-week test failure log

Window: November 24 to December 8, 2026. Add an entry when a test failure is
fixed. Record the failing revision, run or artifact, failure, repair and replay.
Classify each fix as a caught regression or a change detector. Keep all
existing assertions during the window.

| Date | Evidence | Failure and repair | Classification |
| --- | --- | --- | --- |
| Nov 24 | `.scratch/ci/proof/bun-e2e/summary.json` and `mixed-e2e/summary.json` | The all-Bun trial timed out in the identity concurrency and Vietnam fixture scripts. Running those scripts with Node and retaining Bun for installation and the other scripts let all seven pass. | Caught harness regression |
| Nov 24 | [Single-runner API E2E](https://github.com/My-apps-factory/BillBandit/actions/runs/45365721088) and [sharded API E2E](https://github.com/My-apps-factory/BillBandit/actions/runs/45366628920) | Four concurrent Next processes on one runner hit the existing execution budget in two scripts. Five independent shards ran the same assertions and all passed. | Caught CI scheduling regression |
| Nov 24 | `.scratch/ci/proof/tla-counterexample-status.txt` | The old runner returned exit 0 on an existing model counterexample. The new wrapper returned exit 1. | Caught false-green CI regression |
| Nov 24 | [TLC timeout](https://github.com/My-apps-factory/BillBandit/actions/runs/45367398123) and [TLC completion](https://github.com/My-apps-factory/BillBandit/actions/runs/45370032889) | The ledger ran out of time at the original heap size. An 8 GiB heap let the full model complete in 650 s under the same timeout. | Caught CI resource regression |
| Nov 24 | [Simulator startup repair](https://github.com/My-apps-factory/BillBandit/pull/50) | The unsigned simulator crashed during eager CloudKit startup. Lazy initialization and the Debug QA guard let the signed-out flow pass. | Caught simulator startup regression |
| Nov 24 | [Ledger split baseline](https://github.com/My-apps-factory/BillBandit/actions/runs/45374393220) and [split result](https://github.com/My-apps-factory/BillBandit/actions/runs/45375043792) | The ledger script took 20.30 s. The split retained all 23 check IDs and the consistency check on both sets of groups. Hosted sections took 18.40 s and 13.95 s. | Caught CI timing regression |

A deliberately injected HTTP status change in the selection replay is a
gate check. It is excluded from the failure counts. No tests were removed.
