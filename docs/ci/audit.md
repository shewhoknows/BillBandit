# CI baseline

GitHub returned 37 workflow runs and 73 job records, including one rerun.
The sample covers July 30 to November 23, 2026 UTC and ends at [run 45160305590](https://github.com/shewhoknows/BillBandit/actions/runs/45160305590).

All values are seconds, p50 / p95. p50 is the median. p95 uses the nearest rank.

| Workflow / job | Started | Waiting | Setup | Running | On runner |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deploy privacy pages / deploy | 3 | 3 / 10 | 4 / 5 | 10 / 21 | 15 / 25 |
| Deploy to Railway / Deploy | 21 | 2 / 8 | 4 / 12 | 4 / 213 | 10 / 222 |
| Deploy to Railway / Lint & Type Check | 35 | 2 / 9 | 53 / 60 | 11 / 13 | 63 / 70 |

Waiting starts when GitHub creates the job. The Deploy job is created after its
prerequisite, so its waiting time excludes the prerequisite. Setup includes
runner setup, checkout, Node, dependency install, Prisma generation, Railway CLI
install, and Pages configuration when present. Running is the rest of the job.
The 14 skipped Deploy records have no runner timing. A failed deployment
typically ends before the health check, so its runtime understates successful delivery.

| Workflow / event | Runs | Total wall p50 / p95 |
| --- | ---: | ---: |
| Deploy to Railway / pull request | 13 | 68 / 77 |
| Deploy to Railway / push | 17 | 73 / 499 |
| Deploy to Railway / manual | 4 | 62 / 229 |
| Deploy privacy pages / push | 2 | 16.5 / 18 |
| Deploy privacy pages / manual | 1 | 35 / 35 |

Wall time spans the first job creation to the last started job's completion in
the latest attempt. The sample includes three successful Railway push runs.
For PR feedback, setup is the largest bucket. Start with dependency installation
and reuse, then measure the runner and tool changes.

## Railway failure

In [run 45160305590](https://github.com/shewhoknows/BillBandit/actions/runs/45160305590/job/137644223096),
lint and typecheck passed. Railway CLI 5.75.0 received a configured, masked
`RAILWAY_TOKEN` and exited 1 with `Invalid RAILWAY_TOKEN`. The production SHA
check never ran. The log cannot tell whether the token expired, was revoked,
or had the wrong project or environment scope. The owner must replace it with
a project token for the production environment.

Job metadata records 17 failed Railway deploy steps and two historical
typecheck failures. Eight available failure logs show the token rejection.
Nine failure log requests returned HTTP 410. The remaining available failure
log shows a TypeScript error. See [Railway token scopes](https://docs.railway.com/cli/login).

## Reproduce

Save the latest 150 objects from the paginated Actions runs endpoint as an
array in `.scratch/ci/audit/runs.json`. Use all objects when fewer exist.
For each run, save the jobs endpoint response with `filter=all` as
`.scratch/ci/audit/jobs-<run-id>.json`. Then run:

```sh
python3 docs/ci/measure-actions.py .scratch/ci/audit
gh run view 45160305590 -R shewhoknows/BillBandit --log-failed
```

The original run data, job data, and available failure logs are in
`.scratch/ci/audit/` in the audit worktree.
