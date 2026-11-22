# No silent failures (iOS, 2026-11-21)

Rule: when something the person did, or something the app did for them,
fails for good, the person is told once.

## Where each failure is shown

| Failure | Shown by | Where in code |
|---|---|---|
| A sheet's own change fails while the sheet waits (add/edit expense, delete expense, add member) | the sheet's own error text (as before) | `T15CanonicalLedgerRuntime.reconcile(scope:owning:)` marks the row shown |
| A payment or reversal fails while the settle-up screen is open | the screen's alert or the "Settlement changed. Confirm again." banner (as before) | `SettlementStore.publishNewWriteFailures` |
| Any queued change fails after its screen closed (offline first, refused later) | **new** app-wide notice at the top of the app, with OK | `AppFailureCenter` (`Store/AppStore.swift`), `FailureNoticeView` (`RootTabView.swift`) |
| The old CloudKit data move stops ("needs repair") | **new** notice, once per account | `CloudCollaborationService.reportLegacyImportNeedsRepair` |
| iCloud profile and friend-photo sync stops | **new** notice, once per reason | `CloudCollaborationService.lastIssue` `didSet` |
| Friends and groups cannot be refreshed (a refresh failed, or 2 polls in a row) | **new** small "Couldn't refresh … retry" line at the top | `ServerSocialSyncService.showsRefreshProblem`, `RefreshProblemLine` |
| Local-only "Record payment" save fails | **new** red text in the sheet; the change is undone | `RecordPaymentSheet.save` |
| Sign-out would delete changes that are not on the server yet | **new** count in the sign-out alert | `ProfileScreen.signOutWarning` |
| A failed change in a group's pending list | plain words ("not saved · Someone changed this group …") instead of codes; it leaves the list after OK | `PendingExpensePreview`, `LedgerFailureCopy` |

Temporary problems (offline, server busy) are not failures: the change stays
queued and is sent again. The existing "saved on this device · waiting to
sync" and offline balance lines show them.

Not changed on purpose: reward and badge (XP) updates still fail quietly. A
missed badge does not lose any data, and an alert for it would be noise.

## The "shown once" state machine

`PendingLedgerOperation.failureAcknowledgedAt` (new optional SwiftData
attribute) is the one mark that a failed row was shown.

```
queued ──server refuses──▶ failed, not shown
failed, not shown ──owner shows it──────────────▶ shown   (sheet waiting / settle-up screen)
failed, not shown ──no owner, 1 s later──▶ notice waiting ──OK──▶ shown
```

- A sheet that waits for its change owns it (`beginOwning` / `endOwning`).
  The settle-up screen owns the payments it queued while it is visible.
- The center waits 1 s after a failure, so the owning screen can show it first.
- The settle-up screen skips a row whose notice is already waiting
  (`AppFailureCenter.isPending`).
- Sign-out or an account switch drops waiting notices
  (`.serverLedgerAccountCleared`).

TLA+ model: `specs/tla/ios-failure-notices/FailureNotices.tla`.
`FailureNotices_before.cfg` (without the `isPending` check) shows a payment
failure told twice: the notice is waiting, the person opens Settle up, the
screen shows it again. `FailureNotices_after.cfg` checks `ShownAtMostOnce`,
`AckMeansShown` and `EveryFailureShown` (no silent failure) and passes.

## Checks on a Mac (Swift was not compiled here)

1. Build. Launch once over an existing store (new optional attributes
   `basedOnRevision` and `failureAcknowledgedAt`).
2. Offline, add an expense, close the sheet. From a second account, change
   the group. Go online. Expected: the notice "Expense “…” not saved" appears
   at the top; after OK it leaves the group's pending list.
3. Offline, record a payment on Settle up, leave the screen, make the server
   refuse it (reverse the same payment from the other phone). Expected: one
   notice. Repeat with the screen open: the screen's own alert, no notice.
4. Turn off Wi-Fi and cellular for 15 s on Home. Expected: the "Couldn't
   refresh friends and groups" line; it goes away when the connection returns.
5. With a queued change, open Profile → Sign out. Expected: the alert says
   how many changes are not on the server yet.
