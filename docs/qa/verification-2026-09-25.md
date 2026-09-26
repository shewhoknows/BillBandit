# BillBandit local E2E and failure-ledger verification — 2026-09-25 IST

## Conclusion

The final signed **local** iPhone suite passed **96/96** configured tests after the seven-case unit pruning, with zero failures or skips. The earlier pre-prune suite passed 103/103. On disposable simulators, iPad compatibility-window controls no longer cover the tested Home title or Add Expense close button; empty and populated local group deletion now requires a visible Cancel/confirm choice; negative exact and percentage splits now show a specific error instead of saving. The SSH session exited 255 when the Mac went offline, but the Mac's completed Xcode log says `** TEST SUCCEEDED **` and the final `.xcresult` reports 96 passed. These readbacks, not the SSH exit, establish the final test result. This is **not release approval**. Real Apple/two-account/CloudKit end-to-end paths, shared-group deletion policy, injected save failures, and the reviewer's iPadOS 26.6/build-29 path remain blocked or unverified.

Repository: `~/Cowork/BillBandit` on the Mac; branch `codex/profile-sync-ui-build-14`; initial HEAD `8397b4cd57ef22852254c7b0b8b9065f139b30a0` **plus uncommitted scoped edits**. The active app and tests use `BillBandit/BillBandit.xcodeproj`, not the retired root scaffold. Xcode ran on macOS 27.0 with iPhone 18 Pro and iPad Air 11-inch (M3) **iOS/iPadOS 27.0** Simulators, signed Debug configuration. No personal account, real shared group, production database, App Store upload, deployment, submission, or release was changed. Unrelated `BillBandit/Config/Debug.xcconfig` and `.scratch/shared-settle-up/` were preserved.

## Outcome by boundary

| Boundary | Result | Evidence and limit |
|---|---|---|
| Home and Add Expense in iPad compatibility window | **PASS locally** | Final-head settled screenshots `ipad-final-home.png`, `ipad-final-add-before-close.png`, and direct X tap → `ipad-final-add-after-close.png` on iPadOS 27.0. Repeated two earlier fresh launches and close taps. No iPadOS 26.6 parity. |
| Empty local-group deletion | **PASS locally** | Fresh synthetic group: Cancel kept it, explicit Delete removed it, and a no-reset relaunch kept it absent. See ledger BB-QA-002 and private QA screenshots. |
| Populated local-group deletion | **PASS locally** | Existing-file signed UI E2E cancelled and confirmed deletion of a seeded five-member, multi-expense group. Focused `.xcresult`: 1/1 passed; sanitized confirmation crop is in the evidence package. No shared group touched. |
| Negative exact and percentage split | **PASS on replay** | Before fix, separate local fixtures saved invalid negative components and appeared in Activity. After fix, each same-sign replay stayed in Add Expense and showed `split values can't be negative`; exact-mode Activity had no new entry. The shares branch uses the same guard but lacks direct negative-input replay. |
| Final signed active iOS suite | **PASS: 96/96** | Mac `full-signed-postprune.log`: `** TEST SUCCEEDED **`. `xcresulttool` read back result `Passed`, 96 passed, 0 failed, 0 skipped from `~/Library/Caches/bb-qa-20260925/DerivedData/Logs/Test/Test-BillBandit-2026.09.25_21-39-47-+0530.xcresult`. Source hash for final `BalanceEngineTests.swift` was `42b7609d15338f5171e4829d48bdf22d52e45f5e23c40441a5ec0fe0884facae`, matching the remote file and local reviewed copy. The parent SSH process exited 255 due to lost connection while Xcode finished on the Mac. A pre-prune full result was 103/103; it is not the final-tree count. |
| API repository isolation checks | **PASS at this source scope** | 57/57 on an isolated disposable PostgreSQL database; CloudKit importer schema command exit 0 and runtime 1/1 on a separate disposable database. Both databases were dropped. The final source edits were Swift-only, not API changes. No authenticated API E2E is inferred. |
| Real Apple onboarding, A/B invite and group membership, CloudKit round trip, final account deletion | **BLOCKED** | No controlled disposable Apple/iCloud identities, staging endpoint, or human 2FA session was supplied. The live API destination alone does not authorize use of a real account. |
| Shared-group swipe deletion and save-error injection | **BLOCKED / NOT RUN** | App now refuses local deletion of a server-shared group and shows a user message; its product policy is undecided. The local save-failure catch/rollback is code-reviewed but no controlled failure was injected. |
| App Review iPadOS 26.6/build-29 replay | **BLOCKED** | The available diagnostic iPad runtime is 27.0; no parity runtime/device was supplied. Build 29 remains the previously attached rejected version. |
| Earlier percent-validation-message delay | **NOT REPRODUCED in this pass** | Prior minor observation BB-QA-003 remains historical; it was not used as a fix basis. |

## What changed and why

- `Shell/PlaceholderScreens.swift` and `UI/AddExpenseSheet.swift`: iPad-host-only top clearance on the two obstructed headers, leaving iPhone geometry and other full-screen sheets unchanged.
- `UI/GroupsScreen.swift`: explicit local-group Cancel/Delete alert; save failure is presented and deletion is rolled back; a shared-group swipe explains that local deletion is unavailable instead of implying a server delete. No Activity retention rule was invented.
- `Engine/SplitEngine.swift` and `UI/AddExpenseSheet.swift`: non-equal split inputs reject negative components before rounding or persistence; a specific UI error replaces a silent successful save.
- Existing `BillBanditUITests.swift`: one observable local-group Cancel/confirm E2E was added **in the existing file**. No new unit test or test-only file was created.
- Test pruning: previously dead alternate-target test files and target were removed from root `project.yml`; `xcodegen generate -s project.yml -p .` rebuilt the ignored root generated project, and a readback found no obsolete test-file reference. Active test deletions were reviewed at assertion level; four original cases were restored at an earlier stage. A later exhaustive case-level pass identified seven further no-value registrations; they were removed from the remote worktree. The other active unit registrations remain. See [the full individual case disposition](unit-case-disposition.md). Final signed testing of the post-prune tree passed **96/96**; registration and dynamic execution counts are kept distinct.

## Replay and artifacts

From the Mac repository root, with the two dedicated **disposable** simulators available:

```sh
/Users/prateekranka/.codex/bin/disk-preflight.sh
xcodebuild -project BillBandit/BillBandit.xcodeproj -scheme BillBandit \
  -configuration Debug -destination 'platform=iOS Simulator,name=BB QA 2026-09-25 iPhone 18 Pro,OS=27.0' \
  -derivedDataPath ~/Library/Caches/bb-qa-20260925/DerivedData \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=4JRB53LG5C test
xcrun xcresulttool get test-results summary --path '<path printed by xcodebuild>'
```

For visual replay, terminate the running app first, then `simctl launch` on a disposable simulator with `-resetDemoData -skipOnboarding` for Home, and separately `-resetDemoData -skipOnboarding -showAdd` for the sheet. On iPadOS 27.0, wait for a settled frame, capture with `simctl io ... screenshot`, and touch the visible X. On iPhone, a synthetic local group can be swiped Delete twice: Cancel must keep it, explicit Delete must remove it; relaunch **without** the reset flag to check persistence. The dated [failure ledger](failure-ledger-2026-09-25.md) has before/fix/after steps and private local evidence paths for each case. Do not use `-resetDemoData` on an authenticated device.

The small sanitized screenshot set contains only header, confirmation, and validation crops without financial values or private identifiers. Unredacted simulator screenshots and the full `.xcresult` remain **local** in `~/Library/Caches/bb-qa-20260925/` and must not be forwarded without review. No credentials, invite codes, raw account/CloudKit IDs, or financial payloads are included in the shared report. An aborted pre-fix focused UI test exited 65 because the popover omitted Cancel; BB-QA-004 records it before the alert replacement and the rerun that passed. Intermediate exit-143 Xcode attempts from an older baseline are not passes.

## Next gate

Controlled real-account QA needs two disposable Apple/iCloud identities, a safe API endpoint or specific live-API authorization, and Bobby's own sign-in/2FA; clarify whether invitation means CloudKit friend link, API group membership, or both. Choose shared-group deletion semantics before enabling a server action. Matching iPadOS 26.6 review-path evidence and separate publication approval remain required. The request for these inputs timed out in this run, so they remain **blocked**, not passed.

## Post-merge note (rebased onto the branch tip)

After the verification above, the branch tip had advanced 14 commits (`ba575cd`, "Fix handwritten text clipping and settlement refresh"). This change was rebased onto it. Two files conflicted and were resolved by combining both sides: `UI/GroupsScreen.swift` keeps the newer `visibleGroups` indirection together with the pending local-group delete confirmation and the shared-group guard (the delete path still calls `CloudCollaborationService.groupWasDeleted`), and `UI/AddExpenseSheet.swift` keeps the newer `isEditingExpense` header title with the iPad-host top padding re-applied. All other files auto-merged, including the newer regression tests the branch added.

Merged-tree result: signed full iOS suite passed — **124 tests, 0 failed, 0 skipped** (`Test-BillBandit-2026.09.26_22-13-15-+0530.xcresult`; log `full-signed-postmerge.log` ends with `** TEST SUCCEEDED **`).

Still excluded from this change and left local-only: the modified `BillBandit/Config/Debug.xcconfig` and the untracked `.scratch/shared-settle-up/` and `.hermes/` directories.
