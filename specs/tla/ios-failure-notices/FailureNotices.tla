--------------------------- MODULE FailureNotices ---------------------------
(***************************************************************************)
(* "No silent failures" (2026-11-21): every queued change that the server  *)
(* refuses for good is shown to the person, and shown once.                *)
(*                                                                         *)
(* Who can show a failed row (PendingLedgerOperation, retryState failed):  *)
(*   screen : the sheet that queued it and still waits for the answer      *)
(*            (T15CanonicalLedgerRuntime.reconcile(owning:)). It shows its *)
(*            own error and marks the row acknowledged.                    *)
(*   settle : the settle-up screen, for payments it queued, while it is    *)
(*            visible (SettlementStore.publishNewWriteFailures).           *)
(*   center : AppFailureCenter, for every other failed row. It queues a    *)
(*            notice; the row is acknowledged when the person presses OK.  *)
(*                                                                         *)
(* failureAcknowledgedAt is the single "already shown" mark.               *)
(*                                                                         *)
(* Fixes \subseteq {"pendingCheck"}:                                       *)
(*   pendingCheck: the settle-up screen skips a row that the center has    *)
(*                 already queued as a notice (AppFailureCenter.isPending) *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Rows, Fixes

VARIABLES state,    \* row: "queued" | "failed"
          ack,      \* failureAcknowledgedAt # nil
          owner,    \* "none" | "screen" | "settle"
          queued,   \* the center has a notice for it on screen or waiting
          shows     \* how many times the person was told

vars == <<state, ack, owner, queued, shows>>

Init ==
  /\ state = [r \in Rows |-> "queued"]
  /\ ack = [r \in Rows |-> FALSE]
  /\ owner = [r \in Rows |-> "none"]
  /\ queued = [r \in Rows |-> FALSE]
  /\ shows = [r \in Rows |-> 0]

\* A sheet queues the change and waits (beginOwning).
ScreenWaits(r) ==
  /\ state[r] = "queued" /\ owner[r] = "none" /\ ~queued[r]
  /\ owner' = [owner EXCEPT ![r] = "screen"]
  /\ UNCHANGED <<state, ack, queued, shows>>

\* The server refuses it for good (markFailed + markPending).
Fail(r) ==
  /\ state[r] = "queued"
  /\ state' = [state EXCEPT ![r] = "failed"]
  /\ UNCHANGED <<ack, owner, queued, shows>>

\* The sheet's call ends. If the row failed, the sheet showed the error and
\* acknowledged it; if it is still queued (offline), it just lets go.
ScreenDone(r) ==
  /\ owner[r] = "screen"
  /\ owner' = [owner EXCEPT ![r] = "none"]
  /\ IF state[r] = "failed" /\ ~ack[r]
       THEN /\ ack' = [ack EXCEPT ![r] = TRUE]
            /\ shows' = [shows EXCEPT ![r] = @ + 1]
       ELSE UNCHANGED <<ack, shows>>
  /\ UNCHANGED <<state, queued>>

\* The settle-up screen becomes visible for a payment it queued, or goes away.
SettleVisible(r) ==
  /\ owner[r] = "none"
  /\ owner' = [owner EXCEPT ![r] = "settle"]
  /\ UNCHANGED <<state, ack, queued, shows>>

SettleHidden(r) ==
  /\ owner[r] = "settle"
  /\ owner' = [owner EXCEPT ![r] = "none"]
  /\ UNCHANGED <<state, ack, queued, shows>>

\* The settle-up screen's refresh shows its own failed payment.
SettlePublish(r) ==
  /\ owner[r] = "settle" /\ state[r] = "failed" /\ ~ack[r]
  /\ "pendingCheck" \in Fixes => ~queued[r]
  /\ ack' = [ack EXCEPT ![r] = TRUE]
  /\ shows' = [shows EXCEPT ![r] = @ + 1]
  /\ UNCHANGED <<state, owner, queued>>

\* AppFailureCenter finds a failed row nobody owns and queues a notice.
CenterQueues(r) ==
  /\ state[r] = "failed" /\ ~ack[r] /\ owner[r] = "none" /\ ~queued[r]
  /\ queued' = [queued EXCEPT ![r] = TRUE]
  /\ UNCHANGED <<state, ack, owner, shows>>

\* The person reads the notice and presses OK. Reading it is being told,
\* even when another screen already marked the row (acknowledgeFailure is
\* then a no-op).
PersonPressesOK(r) ==
  /\ queued[r]
  /\ queued' = [queued EXCEPT ![r] = FALSE]
  /\ ack' = [ack EXCEPT ![r] = TRUE]
  /\ shows' = [shows EXCEPT ![r] = @ + 1]
  /\ UNCHANGED <<state, owner>>

Next ==
  \E r \in Rows :
    \/ ScreenWaits(r) \/ Fail(r) \/ ScreenDone(r)
    \/ SettleVisible(r) \/ SettleHidden(r) \/ SettlePublish(r)
    \/ CenterQueues(r) \/ PersonPressesOK(r)

\* Sheets finish, screens are left, the center runs and the person
\* eventually presses OK. SettleVisible/ScreenWaits need no fairness. The
\* center and the settle-up refresh are strongly fair: a screen that is
\* opened and closed again and again still lets them run.
Fairness ==
  \A r \in Rows :
    /\ WF_vars(ScreenDone(r)) /\ WF_vars(SettleHidden(r))
    /\ SF_vars(SettlePublish(r))
    /\ SF_vars(CenterQueues(r)) /\ WF_vars(PersonPressesOK(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Shown once, never twice.
ShownAtMostOnce == \A r \in Rows : shows[r] <= 1

\* The mark means it was shown (or its notice is on its way).
AckMeansShown == \A r \in Rows : ack[r] => shows[r] >= 1

\* No silent failure: every failed row is eventually shown.
EveryFailureShown == \A r \in Rows : (state[r] = "failed") ~> (shows[r] = 1)
=============================================================================
