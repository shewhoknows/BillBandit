# BillBandit on Xcode Cloud

The App Store Connect API returned zero Xcode Cloud products for
`com.billbandit.app` on November 24, 2026. It listed the fixed **Xcode 27.2**
entry as build **27B52**. The post-clone script also enforces that exact
version and rejects a mismatched marketing version on a release tag.

Use the fixed **Xcode 27.2** entry under Environment for every workflow.
Choose a compatible macOS entry without a beta label. Use the shared project
at `BillBandit/BillBandit.xcodeproj` and leave clean builds off where Apple
permits caching. Use one iPhone 18 Pro / iOS 27.2 destination. Keep test
repetition disabled.

| Workflow | Start condition | Actions | Post-actions |
| --- | --- | --- | --- |
| BillBandit PR smoke | Pull Request Changes, target branch `main`, require approval for untrusted sources where available | Test, scheme `BillBanditSmoke`, test plan `BillBanditSmoke`. This action also builds the app. | None |
| BillBandit main internal | Branch Changes, branch `main` | Test, scheme `BillBandit`, and Archive, scheme `BillBandit` | TestFlight Internal Testing to the existing internal group |
| BillBandit App Store | Tag Changes, custom starts with `v` | Archive, scheme `BillBandit`, App Store Connect distribution | Upload to App Store Connect. Select the processed build through release staging. |

Owner access and onboarding are in [OWNER-TODO.md](OWNER-TODO.md) after the
owner handoff PR lands. After onboarding, go to App Store Connect → Apps →
BillBandit → Xcode Cloud → Workflows → **+**. For each row, name the workflow,
select Environment, add the Start Condition, add the Actions, and add the
specified Post-actions. Save each configuration after reviewing the destination.
The installed ASC CLI supports `asc xcode-cloud workflows create --file` after
a product and source repository exist. The deployment account must configure
workflow IDs from that product.

Use the smoke workflow first. It includes the existing signed-out onboarding
and authority tests. The full scheme has UI tests that read local JSON session
fixtures and depend on a disposable API and its offline-control proxy. Xcode
Cloud runs the test action on a separate test machine. It does not get the
developer's local files or servers. Keep the main workflow's internal
distribution off until the full fixture handoff is implemented and all tests
pass on Cloud. The full scheme remains the acceptance gate. See
[Apple's workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
and [custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts).

For App Store releases, confirm the archive is from the requested tag and
Cloud build. Resolve its App Store Connect build by Cloud run ID:

```sh
asc xcode-cloud build-runs builds --run-id "$CLOUD_RUN_ID"
asc release stage --app 6792712181 --platform IOS --version "$VERSION" \
  --build-id "$BUILD_ID" --copy-metadata-from "$PREVIOUS_VERSION" --dry-run
```

The release bridge must resolve one processed build from the successful tag run
and confirm staging. Staging selects the build and validates review readiness.
The owner submits through App Store Connect. Keep release distribution disabled
until the full suite and staging work on a rehearsal. See
[Apple's build number guidance](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds/).

No Cloud timings exist yet. The local unsigned build ran on Xcode 27.2.
It measures compile time on this Mac. Apple adds queue time, checkout,
simulator preparation, UI tests, and archive upload or processing as applicable.
