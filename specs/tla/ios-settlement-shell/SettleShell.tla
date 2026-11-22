---------------------------- MODULE SettleShell ----------------------------
(***************************************************************************)
(* SettlementStore + SharedSettleUpScreen + SettlementServerLedgerTransport*)
(* + the shared ServerLedgerSync durable queue, as one screen sees them.  *)
(*                                                                         *)
(* Actors that really run at the same time on the main actor (they         *)
(* interleave at every `await`):                                           *)
(*   - "ref": SettlementStore.refresh (poll, foreground, manual button)    *)
(*   - tasks 1..2: the Task {} bodies started by "Confirm payment" and     *)
(*     "Reverse" taps                                                       *)
(*   - the server (with one peer device write and one peer "read only"     *)
(*     change), and the network going offline / online.                   *)
(*                                                                         *)
(* FIXED = FALSE models the code at base commit 372c5b3.                   *)
(* FIXED = TRUE models the code after this slice's fixes.                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS FIXED, MaxRev, Tasks, MaxNetFlips

Kinds  == {"settle", "reverse"}
OpIds  == Kinds \X (0..MaxRev)
Resps  == {"none", "ok", "conflict", "refused", "offline"}

VARIABLES
  \* server
  srvRev, srvReversed, srvPaid, srvBlocked, applied,
  srvReversals, srvPayments, peerWrote, participant,
  \* network
  offline, netFlips,
  \* SettlementStore
  snap, isOffline, reqReconf, isUpdatingVar, mutBusy,
  refPc, refVis, lockHolder,
  \* durable queue (ServerLedgerStore rows, creation order)
  queue, opState, lastResp, mine,
  \* tasks started by button taps
  mutPc, mutKind, uiBusy,
  \* ghost / bookkeeping for properties
  reported, spurious, startedWhileBlocked

vars == << srvRev, srvReversed, srvPaid, srvBlocked, applied,
           srvReversals, srvPayments, peerWrote, participant,
           offline, netFlips,
           snap, isOffline, reqReconf, isUpdatingVar, mutBusy,
           refPc, refVis, lockHolder,
           queue, opState, lastResp, mine,
           mutPc, mutKind, uiBusy,
           reported, spurious, startedWhileBlocked >>

Srv == [rev |-> srvRev, reversed |-> srvReversed, paid |-> srvPaid, blocked |-> srvBlocked]

Init ==
  /\ srvRev = 0 /\ srvReversed = FALSE /\ srvPaid = FALSE /\ srvBlocked = FALSE
  /\ applied = {} /\ srvReversals = 0 /\ srvPayments = 0 /\ peerWrote = FALSE
  /\ participant \in BOOLEAN          \* is the caller payer/recipient of payment S0?
  /\ offline = FALSE /\ netFlips = 0
  /\ snap = Srv                        \* screen already loaded once
  /\ isOffline = FALSE /\ reqReconf = FALSE /\ isUpdatingVar = FALSE /\ mutBusy = 0
  /\ refPc = "idle" /\ refVis = FALSE /\ lockHolder = "none"
  /\ queue = << >>
  /\ opState = [o \in OpIds |-> "none"]
  /\ lastResp = [o \in OpIds |-> "none"]
  /\ mine = {}
  /\ mutPc = [t \in Tasks |-> "idle"]
  /\ mutKind = [t \in Tasks |-> "none"]
  /\ uiBusy = FALSE
  /\ reported = {}
  /\ spurious = FALSE /\ startedWhileBlocked = FALSE

(* ---------------- derived store flags (SettlementStore.swift) ---------- *)
RefreshInFlight == refPc # "idle"
\* base: one stored Bool written by refresh() and settle()/reverse()
\* fixed: computed from the mutation count and the visible-refresh flag
IsUpdating == IF FIXED THEN (mutBusy > 0 \/ (refVis /\ RefreshInFlight))
                       ELSE isUpdatingVar
\* writesEnabled minus its requiresReconfirmation term
GatesOpen == ~IsUpdating /\ ~RefreshInFlight /\ ~isOffline /\ ~snap.blocked
WritesEnabled == GatesOpen /\ ~reqReconf
CanQueue == isOffline /\ ~snap.blocked
CanStartSettle ==
  /\ ~snap.paid                                   \* a transfer is still owed
  /\ IF FIXED THEN WritesEnabled \/ CanQueue \/ (reqReconf /\ GatesOpen)
              ELSE WritesEnabled \/ CanQueue \/ reqReconf
\* "Reverse" row button for payment S0
ReverseVisible ==
  IF FIXED THEN WritesEnabled /\ ~snap.reversed /\ participant
           ELSE WritesEnabled
MutInFlight == \E t \in Tasks : mutPc[t] \in {"drain", "fetch"}

NextOp == LET idx == {i \in 1..Len(queue) : opState[queue[i]] \in {"pending", "retrying"}}
          IN IF idx = {} THEN << >> ELSE << queue[CHOOSE i \in idx : \A j \in idx : i <= j] >>

(* server answer to one submission (kernel.ts order: idempotency, revision,  *)
(* then the per-kind rules)                                                  *)
Answer(op) ==
  IF offline THEN "offline"
  ELSE IF op \in applied THEN "ok"
  ELSE IF op[2] # srvRev THEN "conflict"
  ELSE IF op[1] = "reverse" /\ srvReversed THEN "conflict"      \* ALREADY_REVERSED 409
  ELSE IF op[1] = "reverse" /\ ~participant THEN "refused"      \* FORBIDDEN 403
  ELSE IF op[1] = "settle" /\ srvPaid THEN "conflict"           \* INVALID_SETTLEMENT_AMOUNT 409
  ELSE "apply"

ApplyOnServer(op) ==
  /\ applied' = applied \cup {op}
  /\ srvRev' = srvRev + 1
  /\ IF op[1] = "reverse"
       THEN /\ srvReversed' = TRUE /\ srvReversals' = srvReversals + 1
            /\ UNCHANGED << srvPaid, srvPayments >>
       ELSE /\ srvPaid' = TRUE /\ srvPayments' = srvPayments + 1
            /\ UNCHANGED << srvReversed, srvReversals >>

SrvUnchanged == UNCHANGED << srvRev, srvReversed, srvPaid, applied, srvReversals, srvPayments >>

(* one drain step by `who` (holds the store drain lock). Returns the result *)
(* through the actor's next pc; "thrown" is an error leaving the drain.     *)
\* result kind of a submission, as the queue records it
NewState(r) ==
  CASE r \in {"apply", "ok"} -> "succeeded"
    [] r = "conflict"        -> "failed"
    [] r = "refused"         -> IF FIXED THEN "failed" ELSE "retrying"   \* transport mapped 4xx to 500
    [] r = "offline"         -> "retrying"

DrainSubmit(op, r) ==
  /\ IF r = "apply" THEN ApplyOnServer(op) ELSE SrvUnchanged
  /\ opState' = [opState EXCEPT ![op] = NewState(r)]
  /\ lastResp' = [lastResp EXCEPT ![op] = IF r = "apply" THEN "ok" ELSE r]

(* ======================= refresh() ===================================== *)
RefStart ==
  /\ refPc = "idle"
  /\ \E vis \in BOOLEAN :          \* forceWritesDisabled && hadSnapshot
       /\ refVis' = vis
       /\ isUpdatingVar' = IF vis THEN TRUE ELSE isUpdatingVar
  /\ refPc' = "drain"
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, reqReconf, mutBusy,
                  lockHolder, queue, opState, lastResp, mine, mutPc, mutKind, uiBusy,
                  reported, spurious, startedWhileBlocked >>

\* store.beginDrain fails -> drain returns [] and the refresh goes on to fetch
RefSkipDrain ==
  /\ refPc = "drain" /\ lockHolder \notin {"none", "ref"}
  /\ refPc' = "fetch"
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, reqReconf,
                  isUpdatingVar, mutBusy, refVis, lockHolder, queue, opState, lastResp, mine,
                  mutPc, mutKind, uiBusy, reported, spurious, startedWhileBlocked >>

RefTakeLock ==
  /\ refPc = "drain" /\ lockHolder = "none"
  /\ lockHolder' = "ref"
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, reqReconf,
                  isUpdatingVar, mutBusy, refPc, refVis, queue, opState, lastResp, mine,
                  mutPc, mutKind, uiBusy, reported, spurious, startedWhileBlocked >>

\* end of refresh(): defer block. In FIXED, newly failed own operations are
\* published once (store.writeFailureNotice -> screen alert).
RefEnd(extraReconf, newSnap, rep) ==
  /\ refPc' = "idle"
  /\ isUpdatingVar' = IF refVis THEN FALSE ELSE isUpdatingVar
  /\ reqReconf' = (reqReconf \/ extraReconf)
  /\ snap' = newSnap
  /\ reported' = rep

\* who tells the person about a failed submission of `op` with answer r
\* during a refresh: a conflict shows the "Settlement changed. Confirm again."
\* banner (both versions); a refusal is shown only by the FIXED notice alert.
RefReport(op, r) ==
  IF r = "conflict" \/ (r = "refused" /\ FIXED) THEN reported \cup {op}
  ELSE reported \ {op}

RefDrainStep ==
  /\ refPc = "drain" /\ lockHolder = "ref"
  /\ IF NextOp = << >>
       THEN /\ lockHolder' = "none" /\ refPc' = "fetch"
            /\ UNCHANGED << srvRev, srvReversed, srvPaid, applied, srvReversals, srvPayments,
                            opState, lastResp, isOffline, reqReconf, isUpdatingVar, snap,
                            reported >>
       ELSE LET op == NextOp[1]
                r  == Answer(op)
            IN /\ DrainSubmit(op, r)
               /\ IF r \in {"apply", "ok"}
                    THEN /\ UNCHANGED << refPc, lockHolder, isOffline, reqReconf, isUpdatingVar,
                                         snap, reported >>
                    ELSE \* error thrown out of onForeground: no fetch this time
                         /\ lockHolder' = "none"
                         /\ isOffline' = IF r = "offline" THEN TRUE ELSE isOffline
                         /\ RefEnd(r = "conflict", snap, RefReport(op, r))
  /\ UNCHANGED << srvBlocked, peerWrote, participant, offline, netFlips, mutBusy, refVis,
                  queue, mine, mutPc, mutKind, uiBusy, spurious, startedWhileBlocked >>

RefFetch ==
  /\ refPc = "fetch"
  /\ IF offline
       THEN /\ isOffline' = TRUE /\ RefEnd(FALSE, snap, reported)
       ELSE /\ isOffline' = FALSE /\ RefEnd(FALSE, Srv, reported)
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, mutBusy, refVis, lockHolder,
                  queue, opState, lastResp, mine, mutPc, mutKind, uiBusy, spurious,
                  startedWhileBlocked >>

(* ======================= button taps and their Tasks =================== *)
\* SwiftUI action closure. Base: only `Task { ... }`; the sheet's isSubmitting
\* is set inside the Task. Fixed: the action checks and sets the busy flag
\* before it starts the Task.
Tap(t, k) ==
  /\ mutPc[t] = "idle"
  /\ IF k = "settle" THEN CanStartSettle ELSE ReverseVisible
  /\ IF FIXED THEN ~uiBusy ELSE (k = "settle" => ~uiBusy)
  /\ uiBusy' = IF FIXED THEN TRUE ELSE uiBusy
  /\ mutPc' = [mutPc EXCEPT ![t] = "spawned"]
  /\ mutKind' = [mutKind EXCEPT ![t] = k]
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, reqReconf,
                  isUpdatingVar, mutBusy, refPc, refVis, lockHolder, queue, opState, lastResp,
                  mine, reported, spurious, startedWhileBlocked >>

OtherInFlight(t) == \E u \in Tasks \ {t} : mutPc[u] \in {"drain", "fetch"}

\* settle()/reverse() synchronous prefix: guards, operationID, enqueue,
\* isUpdating = true. Runs when the Task body starts.
TaskStart(t) ==
  LET k     == mutKind[t]
      op    == << k, snap.rev >>
      guard == IF k = "settle"
                 THEN IF FIXED THEN WritesEnabled \/ CanQueue \/ (reqReconf /\ GatesOpen)
                               ELSE WritesEnabled \/ CanQueue \/ reqReconf
                 ELSE WritesEnabled \/ CanQueue
  IN
  /\ mutPc[t] = "spawned"
  /\ IF ~guard
       THEN \* throws writeDisabled -> actionError / "Payment not reversed" alert
            /\ mutPc' = [mutPc EXCEPT ![t] = "idle"]
            /\ spurious' = (spurious \/ OtherInFlight(t))
            /\ uiBusy' = IF FIXED \/ k = "settle" THEN FALSE ELSE uiBusy
            /\ UNCHANGED << queue, opState, mine, isUpdatingVar, mutBusy, reqReconf,
                            startedWhileBlocked, reported >>
       ELSE IF opState[op] = "failed"
       THEN \* operationID(for:) finds the failed row: requiresReconfirmation
            /\ mutPc' = [mutPc EXCEPT ![t] = "idle"]
            /\ reqReconf' = TRUE
            /\ uiBusy' = IF FIXED \/ k = "settle" THEN FALSE ELSE uiBusy
            /\ UNCHANGED << queue, opState, mine, isUpdatingVar, mutBusy, spurious,
                            startedWhileBlocked, reported >>
       ELSE /\ IF opState[op] = "none"
                 THEN /\ queue' = Append(queue, op)
                      /\ opState' = [opState EXCEPT ![op] = "pending"]
                 ELSE UNCHANGED << queue, opState >>
            /\ mine' = mine \cup {op}
            /\ reqReconf' = IF k = "settle" THEN FALSE ELSE reqReconf
            /\ isUpdatingVar' = TRUE
            /\ mutBusy' = mutBusy + 1
            /\ uiBusy' = IF ~FIXED /\ k = "settle" THEN TRUE ELSE uiBusy
            /\ startedWhileBlocked' = (startedWhileBlocked \/ snap.blocked)
            /\ mutPc' = [mutPc EXCEPT ![t] = "drain"]
            /\ UNCHANGED << spurious, reported >>
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, refPc, refVis,
                  lockHolder, lastResp, mutKind >>

\* end of the Task: defer { isUpdating = false } and the screen's handling.
\* alert = TRUE when the screen shows actionError / reverseError.
TaskEnd(t, newSnap, newOffline, newReconf, rep) ==
  /\ mutPc' = [mutPc EXCEPT ![t] = "idle"]
  /\ isUpdatingVar' = FALSE
  /\ mutBusy' = mutBusy - 1
  /\ uiBusy' = IF FIXED \/ mutKind[t] = "settle" THEN FALSE ELSE uiBusy
  /\ snap' = newSnap /\ isOffline' = newOffline /\ reqReconf' = newReconf
  /\ reported' = rep

TaskSkipDrain(t) ==
  /\ mutPc[t] = "drain" /\ lockHolder \notin {"none", t}
  /\ mutPc' = [mutPc EXCEPT ![t] = "fetch"]
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, reqReconf,
                  isUpdatingVar, mutBusy, refPc, refVis, lockHolder, queue, opState, lastResp,
                  mine, mutKind, uiBusy, reported, spurious, startedWhileBlocked >>

TaskTakeLock(t) ==
  /\ mutPc[t] = "drain" /\ lockHolder = "none"
  /\ lockHolder' = t
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, snap, isOffline, reqReconf,
                  isUpdatingVar, mutBusy, refPc, refVis, queue, opState, lastResp, mine,
                  mutPc, mutKind, uiBusy, reported, spurious, startedWhileBlocked >>

TaskDrainStep(t) ==
  /\ mutPc[t] = "drain" /\ lockHolder = t
  /\ IF NextOp = << >>
       THEN /\ lockHolder' = "none" /\ mutPc' = [mutPc EXCEPT ![t] = "fetch"]
            /\ UNCHANGED << srvRev, srvReversed, srvPaid, applied, srvReversals, srvPayments,
                            opState, lastResp, snap, isOffline, reqReconf, isUpdatingVar,
                            mutBusy, uiBusy, reported >>
       ELSE LET op == NextOp[1]
                r  == Answer(op)
            IN /\ DrainSubmit(op, r)
               /\ IF r \in {"apply", "ok"}
                    THEN UNCHANGED << mutPc, lockHolder, snap, isOffline, reqReconf,
                                      isUpdatingVar, mutBusy, uiBusy, reported >>
                    ELSE /\ lockHolder' = "none"
                         /\ CASE r = "offline" ->   \* queued: settle returns nil, no alert
                                   TaskEnd(t, snap, TRUE, reqReconf, reported)
                              [] r = "conflict" ->  \* loadCachedSnapshot + alert
                                   TaskEnd(t, Srv, isOffline, TRUE, reported \cup {op})
                              [] r = "refused" ->   \* alert
                                   TaskEnd(t, snap, isOffline, reqReconf, reported \cup {op})
  /\ UNCHANGED << srvBlocked, peerWrote, participant, offline, netFlips, refPc, refVis,
                  queue, mine, mutKind, spurious, startedWhileBlocked >>

TaskFetch(t) ==
  /\ mutPc[t] = "fetch"
  /\ IF offline
       THEN TaskEnd(t, snap, TRUE, reqReconf, reported)
       ELSE TaskEnd(t, Srv, FALSE, FALSE, reported)
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, offline, netFlips, refPc, refVis, lockHolder,
                  queue, opState, lastResp, mine, mutKind, spurious, startedWhileBlocked >>

(* ======================= environment =================================== *)
PeerWrite ==        \* another phone changes the group (revision + 1)
  /\ ~peerWrote /\ srvRev < MaxRev
  /\ peerWrote' = TRUE /\ srvRev' = srvRev + 1
  /\ UNCHANGED << srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  participant, offline, netFlips, snap, isOffline, reqReconf, isUpdatingVar,
                  mutBusy, refPc, refVis, lockHolder, queue, opState, lastResp, mine, mutPc,
                  mutKind, uiBusy, reported, spurious, startedWhileBlocked >>

PeerBlocks ==       \* group becomes read only (migration / stale read model)
  /\ ~srvBlocked /\ srvBlocked' = TRUE
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, applied, srvReversals, srvPayments, peerWrote,
                  participant, offline, netFlips, snap, isOffline, reqReconf, isUpdatingVar,
                  mutBusy, refPc, refVis, lockHolder, queue, opState, lastResp, mine, mutPc,
                  mutKind, uiBusy, reported, spurious, startedWhileBlocked >>

NetFlip ==
  /\ netFlips < MaxNetFlips
  /\ offline' = ~offline /\ netFlips' = netFlips + 1
  /\ UNCHANGED << srvRev, srvReversed, srvPaid, srvBlocked, applied, srvReversals, srvPayments,
                  peerWrote, participant, snap, isOffline, reqReconf, isUpdatingVar, mutBusy,
                  refPc, refVis, lockHolder, queue, opState, lastResp, mine, mutPc, mutKind,
                  uiBusy, reported, spurious, startedWhileBlocked >>

Next ==
  \/ RefStart \/ RefSkipDrain \/ RefTakeLock \/ RefDrainStep \/ RefFetch
  \/ \E t \in Tasks : \/ \E k \in Kinds : Tap(t, k)
                      \/ TaskStart(t) \/ TaskSkipDrain(t) \/ TaskTakeLock(t)
                      \/ TaskDrainStep(t) \/ TaskFetch(t)
  \/ PeerWrite \/ PeerBlocks \/ NetFlip

Spec == Init /\ [][Next]_vars

(* ======================= properties ==================================== *)
TypeOK ==
  /\ refPc \in {"idle", "drain", "fetch"}
  /\ \A t \in Tasks : mutPc[t] \in {"idle", "spawned", "drain", "fetch"}
  /\ mutBusy \in 0..Cardinality(Tasks)

\* A payment/reversal control is never live while one of our writes is in flight.
NoWriteWhileMutating == MutInFlight => ~WritesEnabled

\* Money: the server applies each logical action at most once.
MoneySafe == srvReversals <= 1 /\ srvPayments <= 1

\* A server refusal (4xx that is not a conflict) is final: it is not retried.
RefusalIsTerminal == \A o \in OpIds : lastResp[o] = "refused" => opState[o] = "failed"

\* A write cannot start while the group is read only.
NoStartWhileReadOnly == ~startedWhileBlocked

\* "Reverse" is offered only for a payment that can be reversed.
ReverseOnlyWhenReversible == ReverseVisible => ~snap.reversed

\* A second tap never shows an error while the first one is still saving.
NoSpuriousError == ~spurious

Quiescent == refPc = "idle" /\ \A t \in Tasks : mutPc[t] = "idle"
\* Every failed submission of a write this screen made reaches the person
\* (alert, banner or notice) by the time the screen is idle again.
FailureReported ==
  Quiescent => \A o \in mine : lastResp[o] \in {"conflict", "refused"} => o \in reported

=============================================================================
