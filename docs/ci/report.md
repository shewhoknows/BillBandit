# BillBandit CI and delivery report

Measured November 24, 2026. [Baseline audit](audit.md) · [Owner actions](OWNER-TODO.md)

| Metric | Before | Candidate |
| --- | ---: | ---: |
| API PR result | 68 s p50 and 77 s p95 across 13 baseline PRs | Two earlier full API runs passed in 43 s and 71 s. The current strict runs report timing failures separately from correct API results. |
| API job waiting | 5 s target | 3 s p50, 68 s p95, 99 s worst across 61 started jobs on GitHub-hosted runners |
| API setup | 53 s p50 across baseline jobs | Cold dependency and checkout setup still reached 16–18 s in strict samples. |
| API E2E | Zero scripts in Actions | The seven existing scripts run in five shards. The slow ledger script now runs in two sections with the same 23 check IDs. |
| Deployment image | 98.17 s build and 2 s startup | 35.50 s build and 1 s startup |
| Ledger model | 737 s, timed out with 3 GiB heap | 650 s full model with 8 GiB heap. 22 s bounded model job. |
| iOS | Zero Cloud runs at audit start | Build-only runs measured 76.49 s, 99.38 s, 83.40 s, and 87.38 s. |
| Standard GitHub-hosted compute | $0 per PR and per month | $0 per PR and per month |

The queue figures use the Actions job `started_at` minus `created_at`,
with nearest-rank percentiles. The 13 candidate workflow runs exclude
jobs that did not start or were cancelled. Standard GitHub-hosted runners
cannot meet a 5 s p95 waiting target. API CI fails if waiting exceeds 68 s
or if setup and runner time reach their existing 15 s and 35 s limits.
The 30 s E2E shard limit remains. The 43 s and 71 s samples are too few
to establish a sustained p50 or p95. The older 5 s gate failed seven waiting
checks in one run. Its waits ranged from 37 s to 99 s.
[Strict baseline](https://github.com/My-apps-factory/BillBandit/actions/runs/45368005114)
[Hosted waiting budget](https://github.com/My-apps-factory/BillBandit/actions/runs/45373847061)
[Reduced setup round trips](https://github.com/My-apps-factory/BillBandit/actions/runs/45374393220)

The 30-day baseline had six Railway push runs that used 355 runner seconds
and no PRs. The two earlier successful API candidates used 209 and 235
parallel runner seconds per PR. At 20 PRs, six merge groups, and six main
pushes, those full API samples imply about 118 runner minutes per month.
Main full TLA+ would add about 71 runner minutes over six pushes. Six
bounded model runs at the observed 98 runner seconds would add about ten
runner minutes. Standard GitHub runner charges stay at $0 for the public
repo. [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

The fastest observed Cloud build action took 66.89 s. The PR #39 build
took 67.27 s after a 20.11 s wait. Twenty builds at 72.47 s each would
consume about 0.4 Xcode Cloud hours per month in a build-only scenario.
They cost $0 incremental if the team has that much of its included
25 hours left. The test, archive, and upload action times are unmeasured.
Compute hours equal summed action minutes divided by 60. See the
[workflow evidence](xcode-cloud.md) and [Apple compute tiers](https://developer.apple.com/xcode-cloud/get-started/).

## API coverage and deployment

- The API workflow uses independent static checks, Next build and five
  E2E shards. Shared API code, migrations, lockfile, config and unknown
  paths select all scripts. A change to one script selects it. Changes to
  the shared ledger scenario file select both of its sections. Merge groups
  and main always select the full suite. Every shard uses disposable databases,
  random order, and a replay artifact with exact coverage. Exact-base main
  artifacts supply later file weights. The local negative replay forced a
  wrong PR selection for an HTTP 201-to-202 regression. Full selection
  failed two existing tests.
- The API test runner keeps script execution because `bun test` discovered
  zero existing E2E scripts. The all-Bun script trial timed out in the
  identity and Vietnam cases. The mixed runner preserved the assertions
  and passed. The split ledger ranges retain all 23 original check IDs.
  The consistency check runs for the groups in each section. Both local
  split runs passed in 5.38 s and 5.06 s after a 20.30 s hosted combined
  observation. These are different machines. Compare hosted measurements
  separately.
- `bun.lock` is now the one dependency lockfile. A side-by-side Docker
  replay built and started both images against empty PostgreSQL 16.
  Each applied all 15 migrations, served its own revision, and rejected
  unauthenticated group access with HTTP 401. Node remains the runtime for
  deployed Next and Prisma. Bun installs and invokes the scripts. CI retains
  Next ESLint for three rules and TypeScript 5 for Next's JavaScript API.
  [Toolchain comparison](toolchain.md)
  [Container comparison](https://github.com/My-apps-factory/BillBandit/actions/runs/45373847266)
- Railway deploys production through its GitHub integration on `main`.
  The bootstrap PR removes `deploy.yml` and its `railway up` call. This
  leaves one deployment path and removes the token
  rejection. Railway injects the source commit SHA in `RAILWAY_GIT_COMMIT_SHA`.
  The unchanged health route reports that SHA. The Docker replay verified
  it against both images. Live deploy and health verification follow the
  first authorized merge. [Railway variables](https://docs.railway.com/variables/reference)
- Blobless sparse checkout, a frozen Bun install, and exact lock and
  Prisma-schema `node_modules` caching reduce setup. Main still needs to
  seed the production cache. A sustained hit rate above 95% and cold setup
  below 15 s remain unverified on the standard image.

## Model coverage and merge queue

The bounded ledger uses one owner operation, one member operation and
two attempts per operation. The full ledger uses two owner operations,
one member operation and the same attempt count. Both use the same spec,
both fixes, and all six original invariants. The bounded job visited
36,526 distinct states and emptied the queue. Coverage recorded Issue,
Send, Refresh, Begin, Unblock, Commit and Archive. It recorded applied
create, edit and delete, plus finalize. It checks same-key contention
and replay, stale revisions, and the freeze and deletion invariants.
The full run also explores traces with three distinct operation IDs,
including two from the same owner. It visited 61,894,947 distinct states
and emptied the queue. Additional heap brought that full run below the
unchanged 12-minute command cap. The faster pre-merge check changes
the input bounds. The larger configuration runs after a push to main.
All other 17 models retain their existing bounds on the queue and main.
A local run with the original fixes disabled reproduced the
`ReplayStable` counterexample in the smaller configuration.
[Original timed-out run](https://github.com/My-apps-factory/BillBandit/actions/runs/45367398123)
[Full run](https://github.com/My-apps-factory/BillBandit/actions/runs/45370032889)
[Bounded run](https://github.com/My-apps-factory/BillBandit/actions/runs/45373896095)

The [active ruleset](https://github.com/My-apps-factory/BillBandit/rules/27974223)
lists exactly the seven API names in [required-checks.txt](required-checks.txt).
Each has both `pull_request` and `merge_group` triggers. No API context
mismatches. The four Model checking jobs also have both triggers. GitHub
currently does not require them, and the native Xcode Cloud check is still
Build only on PRs. A full iOS Test result on a merge-group SHA is unverified.
Those are the gaps between the active ruleset and full-suite enforcement.
Actual queue admission and main cache seeding require the owner to land #47.

## Merge order

Each remaining PR targets `main`. Keep the default branch protected. Review the
combined API bootstrap first because its diff supplies all seven required
checks on the candidate revision.

| Order | PR | Scope |
| ---: | --- | --- |
| 1 | [#47](https://github.com/My-apps-factory/BillBandit/pull/47) | Required API stack, Bun lock, timing budgets, hooks and single Railway deployment |
| 2 | [#37](https://github.com/My-apps-factory/BillBandit/pull/37) | Historical audit |
| 3 | [#48](https://github.com/My-apps-factory/BillBandit/pull/48) | Model checking and separate bounded and full ledger configurations |
| 4 | [#39](https://github.com/My-apps-factory/BillBandit/pull/39) | iOS Cloud, fixture consumer, simulator startup guard and release staging |
| 5 | [#46](https://github.com/My-apps-factory/BillBandit/pull/46) | Owner actions, report and two-week test failure log |

The API fixture producer is in #47. The iOS fixture consumer is in #39.
The narrower PRs #38, #40–#45, #49 and #50 were superseded by the
consolidated diffs. The owner controls all merges.

## Replay evidence

Evidence remains in `.scratch/ci/` in the audit worktree. The historical
per-job ledger is `audit/job-buckets.tsv`. New evidence is in `review/`,
including `queue-seconds.json`, `container-proofs/`, `tla-hosted/`,
`ledger-split-coverage.txt`, `ios-stage-pr39-dry-run.json`, and the
readbacks for the disabled Cloud workflows.

Fetch a hosted API E2E result with
`gh run download 45374393220 -R My-apps-factory/BillBandit --pattern 'api-e2e-*'`.
Each summary records the revision, environment, seed, replay and outcome.
[Two-week test failure log](test-failure-log.md)
