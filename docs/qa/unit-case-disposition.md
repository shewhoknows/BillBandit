# BillBandit active unit-case disposition — 2026-09-25 IST

Repository: `~/Cowork/BillBandit`, branch `codex/profile-sync-ui-build-14`, HEAD `8397b4c` with uncommitted QA changes. Scope: the **active nested** `BillBandit/BillBandit.xcodeproj` scheme, not the retired root test target. Reviewed assertion bodies, active production callers, and 13 configured UI cases on the pre-final-prune tree. The UI suite uses local seeded or forced-preview state; it does not sign into a real Apple account, accept a real invitation, exercise server-backed ledger sync, or record a settlement and inspect the final balances. It does not check all split allocations. Therefore most isolation cases still detect plausible production defects the current E2E suite misses. No new unit tests were written.

Disposition key: **KEEP** protects the named real failure absent from UI assertions; **DROP** has no unique reachable failure under the active contract; **UNCERTAIN** keeps coverage until the UI/currency product boundary is established. The table refers to registrations, not assertions within a registration. Loop iterations are not separate cases. Read-only audit input had 61 cases in `BalanceEngineTests.swift` and 29 in the other three active unit files; seven listed removals reduce those registration counts. This source inventory is not a claim about the number of dynamic tests reported by Xcode.

## BalanceEngineTests.swift — removed seven cases

| Case | Disposition and reason |
|---|---|
| `testDemoSeedGroupIDsAreStableAcrossFreshInstalls` | **DROP.** Compares two in-memory DEBUG fixture sets; stable fixture IDs are not a normal-install contract. The separate upgrade/real-data repair cases remain. |
| `testPersonUploadsWriteProfileTimestamp` | **DROP.** Asserts an unused `CloudPersonRecordPolicy` constant rather than a production `BBFriendProfile` write. |
| `testPersonUploadPolicyMatchesCheckedInCloudKitSchema` | **DROP.** Compares that unused policy with legacy `BBPerson` schema; does not cover current friend-profile upload or the active one-time legacy import. |
| `testPartialCloudFailureStopsWhenAnyRecordHasASchemaFailure` | **DROP.** Checks unused `.disposition` plus a nested code; the active readable error path is covered by `testReadableUnwrapsPartialFailureCloudCodes`. |
| `testSimplifyIgnoresDust` | **DROP.** Injects 0.004/-0.004 directly into the simplifier, but active inputs are rounded to whole units first. |
| `testRupeeIsDefaultCurrency` | **DROP.** Explicitly passes `.inr` and therefore cannot assert a *default*. The UI checks a rupee-formatted balance; the half-up number boundary remains in `testMoneyRoundsHalfUp`. An earlier review recommended restoration before these assertions were compared; this later case-level review supersedes that narrower recommendation. |
| `existingDefaultsRemainAuthoritative` | **DROP.** Stored ID and sole active account match. Its only extra flag, `recoveredFromProfile`, is discarded by the production caller; it never creates a conflicting-account choice. |

## BalanceEngineTests.swift — retained XCTest methods

| Case | Disposition: real defect outside UI E2E |
|---|---|
| `testUsernameHandlesNormalizeAndRejectInvalidValues` | **KEEP:** malformed/reserved handle or case normalization bypass. |
| `testCloudSyncMessageNeverExposesCloudKitImplementationDetails` | **KEEP:** internal CloudKit error details exposed in public-profile/friend-sync UI. |
| `testReadableUnwrapsPartialFailureCloudCodes` | **KEEP:** nested record failure loses its actionable schema/update copy. |
| `testDemoRepairRemovesOnlyExactDuplicateLedgers` | **KEEP:** upgrade repair deletes real similarly named group or leaves duplicate fixture. |
| `testConnectedFriendIdentityPrefersCloudLinkedLegacyDuplicate` | **KEEP:** legacy contact maps to wrong connected friend. |
| `testConnectedFriendIdentityDoesNotGuessBetweenSameNamedAccounts` | **KEEP:** same-name accounts are silently conflated. |
| `testFriendAccountRepairLeavesOneRowPerCloudAccountAndRetargetsLedger` | **KEEP:** duplicate connected friend or dangling expense/settlement/activity references. |
| `testDemoPersonRepairRemovesOnlyKnownSeedDuplicatesAndRetargetsLedger` | **KEEP:** upgrade cleanup loses ledger references or removes a real similar contact. |
| `testDemoPersonRepairDoesNotGuessFromOneMatchingContact` | **KEEP:** repair deletes real contact on a weak name/avatar match. |
| `testOrdinaryLaunchRetiresFixturesButPreservesRealConnectedData` | **KEEP:** startup removes real connected data while retiring demo fixtures. |
| `testConnectedFriendSurvivesSaveAndFreshContext` | **KEEP:** connected friend disappears after persisted-context reload. |
| `testAppleAccountCanonicalizationLeavesOneProfileAndRetargetsLedger` | **KEEP:** duplicate self profile or references left on old profile. |
| `testCloudIdentityChangeCreatesANewCurrentProfileInsteadOfReusingOldAccount` | **KEEP:** account switch reuses prior identity/data. |
| `testGroupMemberOptionsExcludeStaleAccountsAndIncludeConnectedFriends` | **KEEP:** stale account selected, connected friend excluded. |
| `testCloudIdentityWinsOverAStaleAppleIdentifier` | **KEEP:** old Apple identifier retargets a different CloudKit identity. |
| `testStaleRemoteProfileCannotOverwriteProfilePageUsername` | **KEEP:** older remote profile rolls back a newer name on refresh. |
| `testConnectedFriendMigrationRetargetsCompleteLedger` | **KEEP:** real invitation migration loses legacy contact's local ledger references. |
| `testSingleExpenseNets` | **KEEP:** payer/participant balance wrong for one expense. |
| `testSettlementMovesNet` | **KEEP:** recorded settlement moves balances in the wrong direction. |
| `testNetsSumToZero` | **KEEP:** combined expenses and settlements create/destroy money. |
| `testSimplifyPairsExtremesFirst` | **KEEP:** suggested plan has wrong debtor/creditor or extra transfer. |
| `testSimplifyChainsThroughMiddle` | **KEEP:** one debtor cannot distribute debt among several creditors. |
| `testSuggestedPaymentMatchesSelectedDirection` | **KEEP:** reversed/irrelevant settlement direction gets a payment suggestion. |
| `testOverpaymentDetection` | **KEEP:** deleting expense misses a remaining overpayment/refund warning. |
| `testMoneyRoundsHalfUp` | **KEEP:** fractional boundary or grouped whole-unit formatting rounds wrong. |
| `testSelectableCurrencyFormattingAndParsing` | **UNCERTAIN / RETAIN:** active pasted-input parser covers prefixed and decimal-comma amounts not entered in E2E; explicit USD/AED formatting currently lacks a visible currency-selection path. Do not drop a whole method while it still protects reachable parsing. |
| `testMoneyInputDistinguishesGroupingAndDecimalCommas` | **KEEP:** grouped pasted amount parses as decimal or vice versa. |
| `testCapitalizesOnlyFirstLetter` | **KEEP:** pasted lowercase title/group/contact is normalized incorrectly. |
| `testFriendInviteCodesNormalizeAndValidate` | **KEEP:** real formatted invite is rejected or malformed one accepted. |
| `testGeneratedFriendInviteCodesAreStrongAndUnambiguous` | **KEEP:** production-generated code collides or uses ambiguous characters. |
| `testRewardEventAwardsExactlyOnce` | **KEEP:** retry awards XP twice. |
| `testRewardActionsUnlockOnlyTheirStarterPins` | **KEEP:** group/settlement action unlocks wrong reward. |
| `testAchievementShelfContainsEightDistinctPins` | **KEEP:** catalog duplicates or omits achievement pin. |
| `testMilestoneAchievementUnlockIsIdempotent` | **KEEP:** repeated milestone evaluation inserts duplicate unlocks. |
| `testDisabledProgressProcessesWithoutAwarding` | **KEEP:** event performed while rewards are off is awarded later. |
| `testEarlyProgressLevelBoundaries` | **KEEP:** XP threshold shows wrong level. |
| `testActivitySummaryIncludesItsGroup` | **KEEP:** group-created activity has wrong group suffix. |
| `testActivitySectioningKeepsFiveNewestDatesThenEarlierActivity` | **KEEP:** older activity is lost or misordered. |
| `testUnreadActivityCountsOnlyNewActionsFromOtherPeople` | **KEEP:** unread count includes self/old events or misses friend events. |
| `testLegacyReminderCleanupRemovesRetiredPreferences` | **KEEP:** startup leaves retired notification preferences scheduled. |
| `testEmptyGroupSettlementCleanupRestoresAllSquare` | **KEEP:** empty group retains stale settlement or nonzero balance. |

## BalanceEngineTests.swift — retained Swift Testing cases

| Case | Disposition: real defect outside UI E2E |
|---|---|
| `serverHandleVerifiesLocalAccount` | **KEEP:** returning API handle asks for a second claim or uses noncanonical case. |
| `missingServerHandleRequiresClaim` | **KEEP:** nil/empty server handle counts as a completed account. |
| `existingServerHandleDoesNotNeedASecondClaim` | **KEEP:** returning user must claim an already-owned handle. |
| `appleIdentityAloneCannotCompleteOnboarding` | **KEEP:** Apple-authenticated incomplete account reaches app shell. |
| `missingDefaultsRestorePersistedSession` | **KEEP:** lost defaults wrongly sign out one active saved account. |
| `legacySessionRestoresAfterDefaultsLoss` | **KEEP:** legacy persisted profile cannot recover session after defaults loss. |
| `explicitSignOutStaysSignedOut` | **KEEP:** bootstrap resurrects an intentionally signed-out account. |
| `conflictingPersistedAccountsStaySignedOut` | **KEEP:** bootstrap guesses one of two active identities. |
| `freshAuthorizationSkipsCredentialStateCheck` | **KEEP:** fresh Apple auth is immediately revalidated/rejected. |
| `simulatorLaunchSkipsCredentialStateCheck` | **KEEP:** simulator's unreliable credential state signs out an existing user. |
| `credentialStateErrorPreservesSession` | **KEEP:** transient credential-query error erases session. |
| `missingCredentialStatePreservesSession` | **KEEP:** `.notFound` without query error erases persisted session. |
| `confirmedRevocationSignsOut` | **KEEP:** confirmed Apple revocation fails to sign out user. |

## SplitEngineTests.swift — eleven retained cases

| Case | Disposition: real defect outside UI E2E |
|---|---|
| `testEqualSplitClean` | **KEEP:** clean equal split assigns wrong per-person shares. |
| `testEqualSplitRemainderIsDeterministic` | **KEEP:** remainder rupee lost or assigned to wrong member. |
| `testSubRupeeTotalIsRejected` | **KEEP:** tiny positive total rounds to zero but is accepted. |
| `testExactMustSum` | **KEEP:** mismatched exact components accepted. |
| `testExactOk` | **KEEP:** valid exact split rejected or wrongly allocated. |
| `testPercentMustBe100` | **KEEP:** percentage inputs below full total accepted. |
| `testPercentRoundingDriftFixed` | **KEEP:** percent rounding drops total or assigns drift wrong. |
| `testSharesProportional` | **KEEP:** weighted share is treated as equal. |
| `testSharesRoundingDriftFixed` | **KEEP:** shares rounding loses remainder or changes order. |
| `testHalfRupeeTotalRoundsAndDistributesAsWholeRupees` | **KEEP:** half-up total boundary rounds down or produces fractions. |
| `testRejectsGarbage` | **KEEP:** zero total or empty participant list accepted. |

Several cases also assert `sum == total` after checking every exact member share. Those *assertions* are redundant, but each method exercises a distinct active split branch or rounding boundary. The new negative-component guard is directly replayed for exact and percent in the dated failure ledger, but it has no automated E2E regression case. No new unit test was added under the user's constraint.

## ServerLedgerCacheTests.swift — thirteen retained cases

| Case | Disposition: real defect outside UI E2E |
|---|---|
| `testCacheAndQueueAreAccountScoped` | **KEEP:** cached group/account data or queued write leaks across account scope. |
| `testRetryKeepsTheSameOperationIDAndRequestPayload` | **KEEP:** retry changes idempotency key/payload and duplicates write. |
| `testLocalOnlyScopeCannotCreateAQueuedServerMutation` | **KEEP:** local group becomes server write. |
| `testCacheModelsAreInTheProductionSwiftDataSchema` | **KEEP:** cache/queue/import model omitted from production schema. |
| `testV2MoneyRequiresCanonicalStringMinorUnits` | **KEEP:** wire money accepts noncanonical numeric or leading-zero values. |
| `testOptimisticSnapshotIsReplacedAndSuccessfulOperationIsNotReplayed` | **KEEP:** optimistic state remains after success or completed write retries. |
| `testRevisionConflictRefreshesAndRequiresExplicitReconfirmation` | **KEEP:** stale mutation replays without refreshed canonical revision and consent. |
| `testSwitchingAccountsClearsOldCacheAndQueue` | **KEEP:** prior account's local cache/write queue survives switch. |
| `testSurfaceProjectionRequiresOneCanonicalReadRevision` | **KEEP:** balances from different read revisions blend as one current state. |
| `testSurfaceScopePolicySeparatesLocalOnlyAndSharedGroups` | **KEEP:** blank server ID misclassifies a local group as shared. |
| `testSurfaceSnapshotCannotCrossAccountOrGroupScopes` | **KEEP:** another account/group's snapshot is accepted into current surface. |
| `testUserFacingCopyMapsLedgerReadUnavailable` | **KEEP:** API read-unavailable code lacks actionable refresh copy. |
| `testSurfaceStatusErrorLabelNeverShowsRawCode` | **KEEP:** raw internal error code reaches visible status label. |

## SettlementStoreTests.swift — five retained cases

| Case | Disposition: real defect outside UI E2E |
|---|---|
| `testCanonicalDisplayUsesLedgerSnapshotAndReadRevision` | **KEEP:** canonical balance/plan or exact minor-unit arithmetic is wrong; note one-expense fixture cannot distinguish total from my-paid filtering. |
| `testStaleMutationRefreshesCanonicalStateAndRequiresReconfirmation` | **KEEP:** stale settlement persists or refreshed revision permits unconfirmed retry. |
| `testSuccessfulMutationIsExactlyOnceAndNeverReplaysTheOperation` | **KEEP:** settlement is submitted twice or replayed from queue. |
| `testOfflineRefreshUsesCachedCanonicalStateAndSurfacesError` | **KEEP:** offline refresh hides error/discards usable cache; this case does not actually queue a settlement. |
| `testCanonicalSettlementDoesNotInsertLegacyLocalSettlement` | **KEEP:** canonical write also inserts divergent legacy local settlement. |

## Evidence and limits

The two independent read-only GPT-6 Luna reviews examined assertion bodies and production call sites before the coordinator removed seven cases. The **post-prune** signed full iOS run passed 96/96 (0 failed, 0 skipped), per `Test-BillBandit-2026.09.25_21-39-47-+0530.xcresult`; the SSH parent exited 255 when the Mac went offline, but Xcode's own log says `** TEST SUCCEEDED **`. This inventory has 83 retained unit registrations, not 83 claimed Xcode dynamic executions. The current UI does not directly exercise negative `.shares` input; account, CloudKit, API shared-ledger, and iPadOS 26.6 parity remain outside this unit-case audit. The source copy on the Mac matches local SHA-256 `42b7609d15338f5171e4829d48bdf22d52e45f5e23c40441a5ec0fe0884facae`.
