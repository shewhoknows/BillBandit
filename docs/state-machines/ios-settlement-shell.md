# State machines: iOS settlement screen and app shell (`ios-settlement-shell`)

Files: `Settlement/SettlementStore.swift`, `UI/SharedSettleUpScreen.swift`,
`Shell/RootTabView.swift` (AppRootView gate, ServerLedgerSurfaceStore),
`Store/UsernameIdentity.swift`, `Store/CloudCollaboration.swift`.
Models: `specs/tla/ios-settlement-shell/SettleShell.tla`, `AccountGate.tla`.
Line numbers are for this branch.

## 1. SettlementStore write gate (one Settle up screen)

The store keeps state in separate flags. The legal combinations are below.

| Flag | Owner (only writer) | Meaning |
|---|---|---|
| `isLoading` | `refresh()` L302/L307 | first read, no snapshot yet |
| `isRefreshInFlight` | `refresh()` L298/L311 | a refresh is between start and its `defer` |
| `isVisibleRefreshInFlight` (new) | `refresh()` L304/L309 | refresh with `forceWritesDisabled` while a snapshot is shown |
| `mutationsInFlight` (new) | `settle()` L428, `reverse()` L469 | calls between enqueue and their end |
| `isUpdating` | **derived** L77 = `mutationsInFlight > 0 \|\| isVisibleRefreshInFlight` | spinner + write gate |
| `isOffline` | `refresh()` L332/L341, `reconcileAfterMutation` L666/L671, `markIdentityUnavailable` L256 | last network call was offline |
| `requiresReconfirmation` | set: L345, L384, L625, L651, L677, `publishNewWriteFailures`; cleared: L237 (scope change), L427 (settle start), L668 (mutation reconciled) | a write conflicted; banner "Settlement changed. Confirm again." |
| `hasFreshCanonicalRead` | L232 (scope change → false), L331/L665 (→ true) | at least one server read succeeded |
| `isMigrationBlocked` | `applyCanonical` L571 | group is read only |
| `isVisible`, `isInteractionActive` | `setVisible` L260, `setInteractionActive` L274 | screen shown / confirm sheet open (polling paused) |
| `writeFailureNotice` (new) | `publishNewWriteFailures` (set), `clearWriteFailureNotice` (clear) | queued write refused after its call returned |

Derived gates:

- `writeGatesOpen` = snapshot ∧ ¬isUpdating ∧ ¬isRefreshInFlight ∧ ¬isOffline ∧ ¬isMigrationBlocked ∧ ¬stale ∧ ¬archived ∧ canSettleOrReverse
- `writesEnabled` = writeGatesOpen ∧ ¬requiresReconfirmation
- `canQueueSettlement` = isOffline ∧ ¬isMigrationBlocked ∧ ¬stale ∧ ¬archived ∧ canSettleOrReverse
- `canStartSettlement` = transfer current ∧ caller may settle ∧ (writesEnabled ∨ canQueueSettlement ∨ (requiresReconfirmation ∧ writeGatesOpen))
- `canReverse(id)` (new) = writesEnabled ∧ payment is `settlement`, not reversed, and the caller is payer or recipient

Activity states (one screen):

```
             tap Confirm / Reverse                 drain + fetch done
   Idle ───────────────────────────▶ Saving(n) ─────────────────────────▶ Idle
    │  ▲                               │ offline: row stays queued, no alert
    │  │ defer                         │ conflict: banner + alert, reconfirm
    ▼  │                               │ refusal (4xx): alert, row failed (final)
 Refreshing(visible|background) ───────┘
```

Saving and Refreshing can overlap (foreground refresh, coalesced re-run,
realtime). Illegal combos and their guard:

| Combo | Before | Now |
|---|---|---|
| Saving ∧ writesEnabled | reachable: a visible refresh's `defer` set the shared `isUpdating = false` while settle/reverse still awaited | impossible: `isUpdating` is derived from both owners |
| requiresReconfirmation ∧ (Saving ∨ Refreshing ∨ readOnly) ∧ canStartSettlement | reachable: `|| requiresReconfirmation` lifted every gate | impossible: it lifts only its own gate |
| Reverse shown on a reversed payment / a payment of other members | reachable (server answers 409 / 403) | hidden by `canReverse` |
| two Tasks from one double tap | reachable: `isSubmitting` was set inside the Task; Reverse had no guard | button action checks and sets the flag before `Task {}` |

Queue row as this screen sees it (rows live in ServerLedgerStore; the sync
slice owns the full table):

| Row state | Event | Next | Code |
|---|---|---|---|
| none | settle/reverse enqueue (actionKey → operationID) | pending | `enqueueIfNeeded` |
| pending/retrying | drain: 2xx or already applied | succeeded | ServerLedgerSync drain |
| pending/retrying | 409 (revision, ALREADY_REVERSED, amount) | failed (reconfirm) | transport L912 → `revisionConflict` |
| pending/retrying | other 4xx (403 FORBIDDEN, 404, 400) | **failed** (was: retrying forever) | transport L922 keeps the real status |
| pending/retrying | offline / 5xx / 408 / 429 | retrying (backoff) | recordFailure |
| failed (own) | next refresh | reported once: banner (conflict) or "Payment not reversed" / "Payment not recorded" alert | `publishNewWriteFailures` |

Invariants (checked by TLC, `SettleShell.tla`): NoWriteWhileMutating,
MoneySafe (each payment/reversal applied at most once), RefusalIsTerminal,
NoStartWhileReadOnly, ReverseOnlyWhenReversible, NoSpuriousError,
FailureReported (every failed submission of this screen's writes is shown by
alert, banner or notice before the screen is idle).

Polling/realtime: `pollingTask` runs only when visible ∧ ¬interaction
(L656). A realtime version during Saving/Refreshing/interaction is kept in
`pendingRefreshVersion` (L504) and replayed by the refresh `defer` or when the
sheet closes. `refreshOnForeground` ignores `isInteractionActive` (by design:
the confirm sheet re-reads the version on every render and `isCurrentTransfer`
disables Confirm if the transfer changed).

## 2. Account gate (`AppRootView.AccountGateState`)

```
checking ──flags incomplete / ambiguous──────────────▶ signedOut
checking ──/auth/me fails, no token──────────────────▶ signedOut
checking ──/auth/me ok (or outage with token)──▶ checking (Apple credential)
checking ──credential authorize ∧ token──────────────▶ authorized
checking ──credential authorize ∧ ¬token (new guard)─▶ signedOut
checking ──credential revoked────────────────────────▶ signedOut (full sign-out)
signedOut ──onboarding complete (Apple sign-in, auto handle)──▶ authorized
authorized ──Profile sign-out / delete account──▶ (flags false) Onboarding shown
authorized ──401 anywhere──▶ authorized, no token ("session expired": Profile can sign in again; queued rows kept)
```

RootTabView is shown iff `accountGateState == .authorized ∧ appleUserIdentifier ≠ "" ∧
accountOnboardingComplete ∧ usernameHandleVerified` (L1483). The `-skipOnboarding`
family of launch flags bypasses the gate (UI tests). There is no App Review
"review code" login in this revision (no client path, no server route under
`/api/mobile/auth/`).

ServerLedgerSurfacePhase (`ServerLedgerSurfaceStore.status`):
signedOut → loading → {ready | cached | stale | empty | error}; `refreshGeneration`
drops late results after sign-out, account change or a newer refresh.
`accountDidLoseAuthorization` (L838) → signedOut, snapshot cleared, queue kept.
New: `UsernameIdentityService.invalidateUnauthorizedSession` calls it, so a 401
no longer leaves "Balances are current" on Home with no session.

Invariants (`AccountGate.tla`): ReadyNeedsSession, NoBalancesWithoutSession,
RootNeedsSession (shown only with a session, or the designed expired state),
NoRootWhileChecking.

## 3. Smaller machines (documented, not changed)

- `CloudCollaborationService.State` idle → checking → syncing → ready | idle,
  `unavailable` is never set. `prepare()` stops on an account-generation change
  only before its last awaits, so it can set `.ready` after a sign-out; and
  `synchronize()` does not check `isPreparing`. No view reads `state`, so this
  is cosmetic.
- `OutboundFriendInvite.Status` pending → expired (by clock, `expireOldInvites`);
  `accepted` only comes from the server at creation; `isUsable` = pending ∧ not
  expired. `createInvite` / `accept` set `isWorking` but do not refuse a second
  call while working.
- `UsernameIdentity` session: none → token+binding (`persistVerifiedSession`) →
  cleared by sign-out/delete (`clearSessionAndInvalidateLedger`, clears queue) or
  by 401 (`invalidateUnauthorizedSession`, keeps queue). Sign in with Apple →
  existing handle or `claimAutomaticHandle` (tries candidates on 409).
- `NewGroupRouter.pendingGroupID` → RootTabView `onChange` → `selectTab(.groups)`.

## Simplify-debts switch (added 2026-11-21)

`SettlementStore.setSimplifyDebts(_:)` → `PATCH /api/groups/{id}/settlement-settings`.

```
idle ──owner taps (online, writes open)──▶ saving ──200──▶ refresh ──▶ idle
                                            │ error ──▶ refresh ──▶ "Setting not changed" alert ──▶ idle
```

- Only the owner can tap it (`permissions.canChangeSetting` = can write and role `owner`). Others see "Only the group owner can change this."
- Not queued offline: it changes now, or the person is told why not (offline, session expired, not owner, group changed, server).
- A second tap while saving does nothing (`pendingSimplify` is set before the Task; the store also ignores a call while `isChangingSimplify`).
- The idempotency key is kept per (group, version, value) until it succeeds, so a retry after a dropped connection replays on the server.
- Never sent with another account's token (same check as payments).

Mac checks: as the owner, tap the panel and see the plan change from 1 payment to 2 (or back) on both phones; as a member, the panel does not react and shows the owner line; in airplane mode, tap it and see "You are offline. The setting was not changed."
