# iOS Test results for the merge queue

GitHub requires the same check name on a PR and on its merge-group
commit. Xcode Cloud includes the workflow name in each native check.
PR smoke and the full queue suite use different Xcode Cloud workflows.
The GitHub Actions job reports one name, `iOS Cloud Test`, for both events.

On a PR, the job reads the configured smoke Test result for the PR head SHA.
On a merge group, it reads the configured full Test result for the group SHA.
It accepts a successful completed check from the installed Xcode Cloud
GitHub App. A failed, skipped, or missing Test result fails the gate.
A successful Build action does not satisfy it. The job has read access to
GitHub checks and does not need App Store Connect credentials.

The two repository variables contain exact native Xcode Cloud check names.
Before both are present, the job reports configuration status under the distinct name
`iOS Cloud Test setup`.
The active ruleset currently requires only the names in
`docs/ci/required-checks.txt`. Owner activation steps are in
[OWNER-TODO.md](OWNER-TODO.md).

## Read-only evidence

The Apple Build check on PR #39 succeeded in 85.23 s. It was the only
Xcode Cloud check on that head. A read-only call for the corresponding
Test check returned no result and the gate exited 1 in 0.66 s. Passing the
actual Build check name to the gate also failed validation. The live Test
success case requires both Cloud Test workflows and an actual merge group.
[PR #39 checks](https://github.com/My-apps-factory/BillBandit/pull/39/checks)
[GitHub checks API](https://docs.github.com/en/rest/checks/runs)
