# Owner actions for BillBandit CI

All prices are USD. GitHub transferred the public repository to
`My-apps-factory/BillBandit` during the audit. On November 24, 2026,
GitHub reported the organization as owner and no active rules for `main`.

1. **Restore Railway deploy credentials.** In Railway, open the BillBandit
   project. Open **Settings → Tokens** and create a Project Token for the
   production environment. Copy the API service ID from the correct service.
   In GitHub, open **Settings → Secrets and variables → Actions → Secrets**.
   Replace `RAILWAY_TOKEN` and confirm `RAILWAY_SERVICE_ID`. Set
   `RAILWAY_ENVIRONMENT` if the environment name differs from `production`.
   If the workflow needs an explicit project, set `RAILWAY_PROJECT_ID`.
   Review the next authorized main deploy. It must pass the exact deployed SHA
   verification. Incremental cost is $0 for the credential. Deployment uses
   the existing Railway plan. [Railway project tokens](https://docs.railway.com/cli/login)

2. **Enforce the GitHub merge queue.** Review the PRs in the order in the
   [report](report.md). Keep existing required checks during rollout. After the
   new workflows report, open **Settings → Rules → Rulesets → New branch
   ruleset**. Target the default branch. Set **Active**. Require a pull request,
   required status checks, and a merge queue. Leave the bypass list empty.
   Require `API checks`, `API build`, each `API E2E (0)` through
   `API E2E (4)`, and each of the four TLA+ contexts. Allow enough queue
   status-check time for the model runner's fixed limit. Verify a queued PR
   produces `merge_group` jobs for its queue SHA. Verify the queue blocks a
   failed group. Before enabling delivery, require the full iOS result for
   the queue SHA too. Use a no-distribution Cloud workflow or status bridge for
   `gh-readonly-queue/main/*` and prove the context reaches the queue SHA.
   Never attach a publishing workflow to the queue ref. GitHub's merge queue
   and standard Actions runners cost $0 for this public organization repo.
   Public cache and artifact usage remains subject to account limits.
   [Merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
   [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

3. **Connect and measure Blacksmith.** Sign in to Blacksmith. Install its
   GitHub App for `My-apps-factory/BillBandit` only. Open GitHub
   **Settings → Secrets and variables → Actions → Variables**. Add
   `BILLBANDIT_CI_RUNNER` with `blacksmith-4vcpu-ubuntu-2404`.
   Verify the provider's runner isolation for public fork PRs. Use a supported
   image with Bun 1.3.14, Node, PostgreSQL tools, Java, Python, Git and
   GitHub CLI available. Confirm image and warm capacity options in the
   Blacksmith account before purchasing either. A successful main run seeds
   the exact lock and Prisma-schema dependency cache. Compare at least
   20 subsequent PRs against the GitHub sample for waiting, setup, and cache
   hits. Expect $0 within the published 3,000 free minutes and without paid
   add-ons. The published 2-vCPU Linux rate is $0.004/min beyond the included
   usage. Confirm the 4-vCPU rate in the account before enabling paid usage.
   Optional sticky disk costs $0.50 per GB per month.
   [Blacksmith pricing](https://www.blacksmith.sh/pricing)
   [Blacksmith runner setup](https://info.blacksmith.sh/blog/speed-up-github-actions-with-blacksmith)

4. **Create the Xcode Cloud product.** In release Xcode 27.2, sign in under
   **Xcode → Settings → Accounts** with the BillBandit Apple Developer team.
   Open `BillBandit/BillBandit.xcodeproj` from the checkout.
   Open **Report navigator → Cloud → Get Started**. Choose BillBandit and
   connect the existing App Store Connect app `com.billbandit.app`.
   Select GitHub, authorize the Xcode Cloud integration for
   `My-apps-factory/BillBandit`, return to Xcode, and finish product setup.
   Start with the smoke workflow and leave distribution off. In App Store
   Connect, open **Apps → BillBandit → Xcode Cloud → Workflows** and add the
   configurations in [Xcode Cloud](xcode-cloud.md).
   Confirm the fixed Xcode 27.2 selection. Check automatic distribution
   signing and the capabilities for the existing ID. Ensure the next
   distributable build number is higher than the latest uploaded build.
   Confirm the number Apple assigns in the first run. Onboarding uses the
   existing Apple Developer membership and its 25 compute hours per month.
   [Apple onboarding](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
   [Build numbers](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds/)

5. **Enable iOS full-suite and internal delivery.** Provide a disposable
   fixture API reachable from the Cloud test machine. It needs the UI
   session, trip accounts and group, overview fixture, and offline-control
   proxy described in the existing UI tests and handoff. Provision and
   destroy test data per run. Use test-only credentials and keep them out of
   PR workflows and artifacts. Complete the Cloud fixture handoff and repair
   the documented stale UI tests before requiring the iOS queue check.
   In App Store Connect, open **TestFlight → Internal Testing**, select
   the internal group, and verify membership. In the main Cloud workflow,
   add **TestFlight Internal Testing** using that group after the full
   suite passes. No new TestFlight fee. A separately hosted test fixture
   has an unmeasured cost until the owner chooses a host.
   [Xcode Cloud workflows](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)

6. **Protect and enable App Store staging.** Create tag rulesets under
   **GitHub → Settings → Rules → Rulesets** for `refs/tags/v*`. Limit tag
   creation to release maintainers. Use a separate active rule to block
   updates and deletions. In **Settings → Environments**, create
   `app-store-staging` and allow only matching tags under deployment
   branches and tags. Add `ASC_KEY_ID`, `ASC_ISSUER_ID` and
   `ASC_PRIVATE_KEY_B64` as environment secrets. Use an App Store Connect
   key permitted to read Xcode Cloud runs, attach the BillBandit build and
   read release metadata. Store the App Store Cloud workflow ID as
   `BILLBANDIT_APP_STORE_WORKFLOW_ID` in the same environment. Prepare
   the editable App Store version and its release notes before creating a
   tag from `main`. Confirm the protected tag workflow first in a rehearsal.
   After it validates the selected release build, submit in App Store
   Connect. GitHub standard runner costs $0 for this public repo. App Store
   Connect keys have no separate fee.
   [GitHub environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

7. **Review compute usage.** Open **App Store Connect → Xcode Cloud → Usage**.
   Record compute hours for each of the three workflows. Review the team
   total before upgrading. The Apple Developer app Account page offers
   25 hours included, 100 for $49.99/month, 250 for $99.99/month, 1,000 for
   $399.99/month, and 10,000 for $3,999.99/month. At the current repo volume
   the GitHub runner estimate is $0/month. Xcode Cloud's after-cost remains
   unmeasured until the first real runs.
   [Apple compute tiers](https://developer.apple.com/xcode-cloud/get-started/)
