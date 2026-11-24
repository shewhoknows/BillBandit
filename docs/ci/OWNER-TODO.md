# Owner actions for BillBandit CI

All prices are USD. The GitHub integration and Xcode Cloud product already
point to `My-apps-factory/BillBandit`. The two distribution workflows exist
and are disabled. Use the order in [report.md](report.md). The owner starts with #47. It has
all seven current required check results. Open its GitHub PR and select
**Merge when ready** to put it in the queue. Review its merge-group run
before advancing the remaining PRs.

1. **Verify the first Railway deploy after #47 lands.** Open Railway →
   BillBandit → production API → Deployments. Confirm a single deployment
   originated from GitHub with the merged commit SHA. Confirm that deployment
   is active. Read the API health endpoint and compare its `commit` field to
   the same SHA. This uses the existing Railway plan. GitHub does not need
   a Railway token for deployment. [Railway GitHub deployments](https://docs.railway.com/deployments/github-autodeploys)

2. **Add the PR smoke Test action after #39 lands.** Open App Store Connect →
   Apps → BillBandit → Xcode Cloud → Workflows → **PR build** → **Edit**.
   Under **Start Conditions → Pull Request Changes**, set the target to
   `main`. Under **Actions**, choose **+ → Test → iOS → BillBanditSmoke**.
   Select the `BillBanditSmoke` test plan and one iPhone 18 Pro / iOS 27.2
   destination. Set **Required to Pass** and leave test repetition disabled.
   Remove the redundant **Build** action. The Test action builds the app.
   Keep fixed release Xcode 27.2 and save. Verify the next PR includes a
   passing test result bundle. [Apple workflow actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)

3. **Complete internal delivery after #39 lands.** In the same workflow
   editor, open **Main: TestFlight**. Leave the workflow disabled until its
   PR merges. Under **Environment → Environment Variables**, set
   `BILLBANDIT_UI_FIXTURE_DIR=/tmp/billbandit-ui-fixtures`. Use the existing
   `BillBandit` full Test action. For a no-distribution rehearsal, duplicate
   the workflow, keep only Test, and use a manual-only start. Verify all
   20 tests and the fixture log in that run. Return to Main: TestFlight.
   Under
   **Post-Actions → + → TestFlight Internal Testing**, select
   **BillBandit Internal QA**. Review the group and confirm the next Cloud
   build number exceeds the latest uploaded build number. Save. Enable when
   distribution is authorized. No separate TestFlight fee.
   [Apple distribution post-actions](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)
   [Cloud build numbers](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds/)

4. **Protect App Store staging before enabling release distribution.** In
   GitHub **Settings → Rules → Rulesets**, protect version tags
   `refs/tags/v*`. Allow only release maintainers to create tags and block
   their updates and deletions. In **Settings → Environments**, create
   `app-store-staging`. Allow deployments only from matching tags. Add
   `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY_B64` as environment
   secrets. Use an App Store Connect key authorized to read Xcode Cloud
   and attach a processed build to the BillBandit version. Add
   `BILLBANDIT_APP_STORE_WORKFLOW_ID=01fda70f-cf21-4e9d-bb4e-d4305aa04312`
   as an environment variable. After the release is authorized, enable
   **Release: App Store** in the Cloud workflow editor. It already targets
   tags that start with `v` and has an App Store eligible archive action.
   Prepare the editable version and review metadata before creating its tag
   from `main`. Verify staging selects the expected build. Submit in
   App Store Connect when ready. GitHub standard runner and API key
   incremental costs are $0. [GitHub environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

5. **Require the full suite on the queue.** After #39, #48 and #51 land,
   open the Xcode Cloud workflow editor. Duplicate **Main: TestFlight** as
   **BillBandit merge queue**. Keep just the full `BillBandit` iOS
   **Test** action and its fixture variable. Remove all post-actions.
   Under **Start Conditions → Branch Changes**, set a custom branch
   **Starts With** `gh-readonly-queue/main/`. Enable this test-only
   workflow. Leave the two distribution workflows disabled until authorized.

   Use **GitHub → Settings → Secrets and variables → Actions → Variables**.
   Set `BILLBANDIT_IOS_PR_TEST_CHECK` to the observed native smoke Test
   check name. Set `BILLBANDIT_IOS_QUEUE_TEST_CHECK` to the full workflow's
   native Test check name. With the action named **Test - iOS**, the
   expected names are `BillBandit | PR build | Test - iOS` and
   `BillBandit | BillBandit merge queue | Test - iOS`. Confirm the PR
   smoke result appears as `iOS Cloud Test` on a new PR event.

   In **GitHub → Settings → Rules → Rulesets**, edit **Protect main with
   merge queue**. Keep the existing seven API checks. Add
   `TLA+ (ledger-kernel)`, `TLA+ (ios-ledger-sync)`,
   `TLA+ (ios-settlement-shell)`, `TLA+ (other-models)` and
   `iOS Cloud Test`. Queue the next reviewed PR. Check that all five
   added contexts report on the exact `merge_group.head_sha`. The iOS
   check waits for the matching native full Test result. The merge
   stays gated if that result is missing. Standard GitHub compute
   remains $0. The additional Cloud Test minutes remain unmeasured.
   [GitHub merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
   [iOS Test status](ios-merge-queue.md)

6. **Review Xcode Cloud compute usage.** Open **App Store Connect → Xcode
   Cloud → Usage**. Record action minutes for PR smoke, the merge queue, main, and release.
   The Apple Developer account includes 25 hours of team usage each month.
   Published tiers are 100 hours at $49.99/month, 250 at $99.99/month,
   1,000 at $399.99/month, and 10,000 at $3,999.99/month. Standard
   GitHub Actions runner compute costs $0 per month for this public repo.
   [Apple compute tiers](https://developer.apple.com/xcode-cloud/get-started/)
   [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
