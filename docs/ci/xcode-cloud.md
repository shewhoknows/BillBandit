# BillBandit on Xcode Cloud

The product uses `My-apps-factory/BillBandit` and
`BillBandit/BillBandit.xcodeproj`. The three workflows use the fixed release
Xcode 27.2 (27B52). The post-clone guard prints the compiler version. It accepts
release versions from 27.2 onward and rejects beta labels, prerelease build
suffixes, and older versions. A release tag must match both app marketing
versions in the project.

| Workflow | Source | Actions | State |
| --- | --- | --- | --- |
| PR build | Pull request changes | Build. Switch to the `BillBanditSmoke` Test action after the shared scheme lands. | Enabled, Build only |
| Main: TestFlight | Exact branch `main` | Build, full `BillBandit` Test, internal-only Archive | Created and disabled |
| Release: App Store | Tag name starts with `v` | App Store eligible Archive | Created and disabled |

App Store Connect returned both new workflows pinned to macOS Golden Gate
27.2.1 and Xcode 27.2. Main uses one iPhone 18 Pro / iOS 27.2 destination.
It requires all three actions to pass. The owner adds the internal TestFlight
post-action and fixture environment in the workflow editor. The public create
API supplies the actions and distribution audience. The owner list gives the
remaining clicks. [Apple workflow creation](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-ciworkflows)
[Apple distribution post-actions](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)

The shared smoke scheme uses existing signed-out onboarding and authority tests.
The full scheme uses the [disposable fixtures](ios-fixtures.md) for session,
ledger history, and offline behavior. Verify the full test action on a
no-distribution run before relying on its result. Keep test repetition disabled.
[Apple workflow actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)

The PR push to `ci/xcode-cloud` triggered a build-only run at commit
`186ce465afbedc47f23a3036a80e9cb1a2b23770`. Run
`f7087ff7-f4e8-40ac-9745-e58c38e55a48` succeeded after 20.11 s waiting and
67.27 s building, 87.38 s total. The first build-only reference was 76.49 s.
The local unsigned build took 63.12 s before this work and 61.90 s with the
smoke scheme. The hosted Test action has yet to run.
[PR build checks](https://github.com/My-apps-factory/BillBandit/pull/39/checks)

## Protected release staging

`Stage iOS release` takes a protected version tag from `main`, then finds
one successful Cloud archive for the exact tag and commit. It resolves the
processed iOS build, attaches it to the prepared App Store version, and runs
ASC validation. The owner submits through App Store Connect.

Run this inspection against a known completed Cloud run:

```sh
ASC_READ_ONLY=1 PATH="/opt/homebrew/bin:$PATH" python3 .github/scripts/stage-ios.py \
  --dry-run --run-id f7087ff7-f4e8-40ac-9745-e58c38e55a48
```

The inspection returned `SUCCEEDED`, zero successful archive actions, and
an empty build list. It made three read-only API calls. The release tag path
requires a successful archive and processed build before it can attach
anything. The existing build-only run does not establish upload or selection
behavior.
