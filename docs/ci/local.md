# Local CI checks

Install Bun 1.3.14 and hk 2.14.0. From the repository root, run:

```sh
bun install --frozen-lockfile --ignore-scripts
bun run --bun --cwd apps/api db:generate
hk install
```

Pre-commit formats and lints staged API source. Git stashing protects
unstaged changes. Pre-push uses the same static-check script as GitHub Actions.
It compares the current checked-out commit to the merge base of
`origin/main`. Build, database, and model jobs run in GitHub Actions.

Run `hk run pre-commit --plan` to see staged work. Run
`hk run pre-push origin "$(git remote get-url origin)"` to replay the
local static gate. See [hk installation](https://hk.jdx.dev/getting_started.html).
