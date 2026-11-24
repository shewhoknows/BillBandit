# BillBandit CI and delivery report

Measured on November 24, 2026. [Baseline audit](audit.md) · [Owner actions](OWNER-TODO.md)

## Time and cost

| Metric | Before | Candidate |
| --- | ---: | ---: |
| API PR wall time | 68 s p50, 77 s p95, 13 runs | 43 s and 71 s on two successful full API PR runs |
| API PR runner time | 65 s median | 209 s and 235 s summed across parallel jobs |
| API E2E | 0 scripts in GitHub Actions | 7 existing scripts passed. Five independent shards. |
| API static gate | Lint and typecheck combined, 63 s median on runner across event types | 17–29 s on runner across observed green CI samples. Includes Oxlint, original Next ESLint, TypeScript 7, and changed-line format. |
| API build | No PR build job | 34–35 s on runner in the two full successful API runs |
| iOS PR and release | 0 Cloud runs | 0 Cloud runs. Local unsigned build reference was 63.12 s before and 61.90 s with the Cloud smoke scheme. |
| Standard GitHub Actions compute | $0 per PR and per month for the public repo | $0 per PR and per month for the public repo |
| Blacksmith and Xcode Cloud | $0 incremental observed | $0 incremental observed. Owner enrollment and runner usage remain pending. |

The two full API PR observations have a 57 s median and 71 s nearest-rank
p95. This sample cannot establish ongoing p50 or p95. The first sharded run
queued jobs for 2–3 s. The later run had 3–40 s queue waits. The slowest job
took 40 s and 41 s on the runner. The API build command stayed inside its
35 s limit and the E2E shard commands stayed inside their 30 s limits.
Availability, queue and runner lifecycle time still matter. See
[sharded E2E](https://github.com/My-apps-factory/BillBandit/actions/runs/45366628920)
and [sparse checkout run](https://github.com/My-apps-factory/BillBandit/actions/runs/45367281300).

The strict-budget candidate kept all correctness results and failed the seven
jobs on waiting. GitHub queued them for 37–99 s. Two jobs also exceeded the
setup limit, and one reached 38.04 s through the runner-budget check. All
seven API scripts passed and their artifacts had exact coverage. This run
shows why the Blacksmith and warm-runner measurements are still required.
See [strict budgets](https://github.com/My-apps-factory/BillBandit/actions/runs/45368005114).

The 30-day baseline contains six Railway push runs that used 355 runner
seconds in total. It contains zero PR runs in that period. At that same
push volume, six post-merge API runs at 222 runner seconds per run would
use 22.2 runner minutes, before deployment, model checking, or merge groups.
For a planning example with 20 PRs, six merge groups, and six main runs,
applying that same full API sample to all 32 events costs about 118 runner
minutes per month. PR selection can reduce that figure. An enrolled
Blacksmith account with its full free-minute allocation would pay $0 for
that volume. Its paid 2-vCPU rate is $0.004/min after applicable free usage.
Optional storage and 4-vCPU rates are separate. See
[GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [Blacksmith pricing](https://www.blacksmith.sh/pricing).

An iOS monthly estimate requires separate action minutes for PR tests,
main tests and archives, and release archives. Compute-hour usage is
`(PR count × PR action minutes + main count × main action minutes +
tag count × tag action minutes) / 60`. Apple includes 25 hours of team
usage. Cloud queue, signing, simulator and processing times are unmeasured.
The local unsigned build is a compile reference on this Mac. It cannot
establish a Cloud floor. [Apple compute tiers](https://developer.apple.com/xcode-cloud/get-started/)

## Coverage and remaining speed limits

- API CI runs lint, typecheck, build, and test shards independently.
  A PR can narrow only script-specific changes and known directories outside
  the API. A change to shared code, migrations, package metadata, config, or
  an unknown path selects all scripts. Merge groups and main always select
  the full suite. GitHub's merge queue still needs owner activation.
- The first one-runner E2E job failed after 65 s on runner. It timed out
  during identity import and ledger. All five sharded jobs passed in the
  candidate. Shard artifacts identify each assigned and executed file.
  Main runs publish times. Future runs use successful artifacts from the
  exact base SHA when available. A local negative replay hid a group creation
  response change from the PR diff. Full selection caught HTTP 202 in two
  existing tests that require HTTP 201.
- Cold dependency setup reduced a 53 s median baseline setup bucket.
  Bun, exact lock caches, blobless fetch, and sparse checkout are configured.
  Main has yet to seed this cache. A >95% hit rate, <5 s runner waiting,
  and a baked and warm Blacksmith image remain unverified.
- The locally measured Oxlint engine ran faster than ESLint. Next ESLint
  remains for three unmatched React rules. TypeScript 7.0.2 passed side by
  side with TypeScript 5.9.3. The Bun Next build passed locally and on Ubuntu.
  The all-Bun E2E run timed out in two scripts. The current runner uses
  Node for the abort-sensitive identity case and the two fixture scripts.
  Direct `bun test` discovery selected zero existing E2E files.
  The scripts own servers, databases, and process environment. Preserve
  their exit status and isolation with script execution. The Railway
  Docker build still uses npm and Node.
- TLC checked all 18 existing after/fixed models locally in 901.34 s with the
  old wrapper. The full ledger model reached 61,894,947 distinct states.
  The new wrapper returned 1 on a known counterexample where the old wrapper
  printed the violation and returned 0. The full ledger model is a separate
  required job with a 12-minute limit. That job exceeds the fast-feedback
  budget. It fails if it does not complete. The first hosted model run
  timed out the combined small-model lane and was cancelled during the large
  ledger lane. Splitting the iOS model groups let the three shorter jobs pass
  in 23 s, 24 s, and 32 s. Together they checked 17 models.
  [Split model run](https://github.com/My-apps-factory/BillBandit/actions/runs/45367398123)
- The iOS smoke scheme builds locally with release Xcode. A beta, a malformed
  tag, and a version mismatch fail the post-clone guard. Cloud needs a product
  and source-repository connection. The full UI suite also needs its
  disposable fixture backend and repairs for existing failing tests.
  Cloud UI, signed archive, internal upload, live build selection and Cloud
  merge-queue enforcement remain unverified.
- The deploy PR pins the Railway CLI and improves the credential diagnostics.
  A missing token made zero CLI calls in the replay. A failing CLI exit
  stays a failure. The rejected production credential remains an owner
  action. The production SHA verification still gates deployment success.

See [toolchain comparison](toolchain.md) and [test failure log](test-failure-log.md).

## Review order

| PR | Scope | Depends on |
| --- | --- | --- |
| [#37](https://github.com/My-apps-factory/BillBandit/pull/37) | Audit and replay | — |
| [#38](https://github.com/My-apps-factory/BillBandit/pull/38) | Railway failure diagnostics | — |
| [#39](https://github.com/My-apps-factory/BillBandit/pull/39) | Xcode Cloud smoke and workflow setup | — |
| [#40](https://github.com/My-apps-factory/BillBandit/pull/40) | Bun, Oxlint, Oxfmt and TypeScript pins | — |
| [#41](https://github.com/My-apps-factory/BillBandit/pull/41) | Static checks, build and caches | #40 |
| [#42](https://github.com/My-apps-factory/BillBandit/pull/42) | E2E and measured shard layout | #41 |
| [#43](https://github.com/My-apps-factory/BillBandit/pull/43) | TLA+ gates and artifacts | — |
| [#44](https://github.com/My-apps-factory/BillBandit/pull/44) | Tag-based iOS staging | #39 |
| [#45](https://github.com/My-apps-factory/BillBandit/pull/45) | Local hk hooks | #41 |
| [#46](https://github.com/My-apps-factory/BillBandit/pull/46) | Owner actions, cost report, and test failure log | — |
| [#47](https://github.com/My-apps-factory/BillBandit/pull/47) | Required API job budgets | #42 |

Stacked PRs target their dependency's branch. Retarget to `main` after the
dependency lands. The CI sessions pushed topic branches and opened PRs.
The owner controls all merges, settings and distribution.

## Evidence

The audit worktree keeps evidence under `.scratch/ci/`.

| Evidence | Location |
| --- | --- |
| Baseline runs, jobs and failure logs | `audit/` |
| API run metadata and command output | `proof/e2e-shards-runner.json`, `proof/sparse-api-hosted.json`, `proof/gh-e2e-shards/`, `proof/strict-budget-shards/` |
| Selection failure and replay | `proof/selection-negative.log`, `selection-proof/.scratch/ci/selection-negative/` |
| TLC model output and counterexample | `proof/tla-old-results.txt`, `proof/tla-new-results.txt`, `proof/tla-counterexample-status.txt` |
| iOS builds and staging contract | `proof/ios-base.log`, `proof/ios-cloud.log`, `proof/ios-cloud-guards.log`, `proof/asc-stage-replay.log` |
| Hook installation and timing | `proof/hk-replay.log` |

Fetch the GitHub API E2E artifacts with
`gh run download 45366628920 --pattern 'api-e2e-*'`. Each summary contains
the revision, environment, seed, result, times and the replay selection.
