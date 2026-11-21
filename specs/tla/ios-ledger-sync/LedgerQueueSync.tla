---------------------------- MODULE LedgerQueueSync ----------------------------
(***************************************************************************)
(* BillBandit iOS offline mutation queue + server mutation kernel.         *)
(*                                                                         *)
(* Device 1 belongs to account A. It queues ops 1..N for ONE shared group  *)
(* (PendingLedgerOperation rows) and drains them in creation order through  *)
(* one of several ServerLedgerSync instances that share one durable store: *)
(*   "L" = ServerLedgerAccountLifecycle.sync (generation bumped on switch)  *)
(*   "S" = an older SettlementStore/T15 instance (generation never bumped)  *)
(* Device 2 is the peer: it writes to the same group (PeerWrite).           *)
(* The server is apps/api/lib/ledger/mutation/kernel.ts:                    *)
(*   receipt key = (session account, operationId); a COMMITTED receipt      *)
(*   replays; otherwise expectedRevision must equal settlementVersion.      *)
(*                                                                         *)
(* Flags select the code AS IT WAS (all FALSE) or AS FIXED (all TRUE):     *)
(*   ReserveAll    - every kind reserves the next queued revision           *)
(*                   (was: only expense.create)                            *)
(*   HeadOfLine    - a group's later op waits while an earlier one is in    *)
(*                   backoff (was: any due row is sent)                     *)
(*   AccountFence  - store epoch + token subject check before each send     *)
(*   ReservedGuard - a reserved non-create op is sent only if every         *)
(*                   revision between the one the user saw and the one it   *)
(*                   expects was produced by one of the device's own        *)
(*                   succeeded ops; otherwise it fails as a conflict        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS Kind,          \* <<"create", "create", "edit">> : kind of op i
          MaxPeer,       \* peer writes
          MaxLoss,       \* lost requests/responses (offline, timeouts)
          MaxCrash,      \* app killed mid-drain
          AllowSwitch,   \* 401 -> sign in as account B on the same phone
          ReserveAll, HeadOfLine, AccountFence, ReservedGuard

KCC  == <<"create", "create">>
KCE  == <<"create", "edit">>
KCCE == <<"create", "create", "edit">>

N      == Len(Kind)
Ops    == 1..N
MaxRev == N + MaxPeer
Owners == {"L", "S"}
Waiting == {"pending", "inflight", "retrying"}
Terminal == {"succeeded", "failed", "deleted"}

VARIABLES
  srvRev,      \* Group.settlementVersion
  writer,      \* writer[r] = who produced revision r: "peer" or "own"
  applied,     \* applied[o] = times op o's effect was committed (any account)
  receipt,     \* set of <<account, op>> COMMITTED LedgerOperation rows
  peerWrites,
  cacheRev,    \* CachedLedgerSnapshot.revision for (A, group)
  rd,          \* outstanding poll/refresh read: -1 or the revision read
  st, exp, due, seen,   \* PendingLedgerOperation rows (seen = basedOnRevision)
  token,       \* subject of the bearer token in the keychain
  instActive, gen,  \* per ServerLedgerSync instance
  epoch,       \* ServerLedgerStore account epoch (bumped by clear)
  drain,       \* the one drain allowed by store.beginDrain
  net,         \* the one request of that drain
  losses, crashes, switched,
  crossSent, lostUpdate, selfFail

vars == <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st, exp,
          due, seen, token, instActive, gen, epoch, drain, net,
          losses, crashes, switched, crossSent, lostUpdate, selfFail>>

NoDrain == [on |-> FALSE, owner |-> "L", acct |-> "none", g |-> 0, ep |-> 0,
            list |-> <<>>, wait |-> FALSE]
NoNet   == [op |-> 0, tok |-> "none", e |-> 0, phase |-> "none",
            result |-> "none", rev |-> 0]

Init ==
  /\ srvRev = 0 /\ writer = [r \in 1..MaxRev |-> "none"]
  /\ applied = [o \in Ops |-> 0] /\ receipt = {} /\ peerWrites = 0
  /\ cacheRev = 0 /\ rd = -1
  /\ st = [o \in Ops |-> "none"] /\ exp = [o \in Ops |-> 0]
  /\ due = [o \in Ops |-> TRUE] /\ seen = [o \in Ops |-> 0]
  /\ token = "A" /\ instActive = [i \in Owners |-> "A"]
  /\ gen = [i \in Owners |-> 0] /\ epoch = 0
  /\ drain = NoDrain /\ net = NoNet
  /\ losses = 0 /\ crashes = 0 /\ switched = FALSE
  /\ crossSent = FALSE /\ lostUpdate = FALSE /\ selfFail = FALSE

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
WaitingOps == {o \in Ops : st[o] \in Waiting}
\* A failure is "justified" only if a peer wrote a revision the user had not seen.
PeerWroteAfter(r) == \E x \in (r+1)..srvRev : writer[x] = "peer"

(* ServerLedgerStore.nextQueuedExpenseRevision *)
Reserve(o) ==
  IF (Kind[o] = "create" \/ ReserveAll) /\ WaitingOps # {}
     /\ Max({exp[j] : j \in WaitingOps}) >= cacheRev
  THEN Max({exp[j] : j \in WaitingOps}) + 1
  ELSE cacheRev

(* The user saves a shared expense/edit while signed in as A (online or  *)
(* offline). Rows are created in id order (createdAt order).            *)
Create(o) ==
  /\ st[o] = "none" /\ IF o = 1 THEN TRUE ELSE st[o-1] # "none"
  /\ token = "A" /\ instActive["L"] = "A"
  /\ st' = [st EXCEPT ![o] = "pending"]
  /\ exp' = [exp EXCEPT ![o] = Reserve(o)]
  /\ seen' = [seen EXCEPT ![o] = cacheRev]
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, due,
                 token, instActive, gen, epoch, drain, net, losses,
                 crashes, switched, crossSent, lostUpdate, selfFail>>

PeerWrite ==
  /\ peerWrites < MaxPeer /\ srvRev < MaxRev
  /\ srvRev' = srvRev + 1
  /\ writer' = [writer EXCEPT ![srvRev + 1] = "peer"]
  /\ peerWrites' = peerWrites + 1
  /\ UNCHANGED <<applied, receipt, cacheRev, rd, st, exp, due, seen,
                 token, instActive, gen, epoch, drain, net, losses, crashes,
                 switched, crossSent, lostUpdate, selfFail>>

(* Backoff timer expires (nextRetryAt <= now). *)
Tick(o) ==
  /\ st[o] = "retrying" /\ ~due[o]
  /\ due' = [due EXCEPT ![o] = TRUE]
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, seen, token, instActive, gen, epoch, drain, net,
                 losses, crashes, switched, crossSent, lostUpdate, selfFail>>

(* Lifecycle 15 s reconcile / surface refresh: GET group snapshot. *)
ReadStart ==
  /\ rd = -1 /\ instActive["L"] = "A"
  /\ rd' = srvRev
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, st, exp,
                 due, seen, token, instActive, gen, epoch, drain, net,
                 losses, crashes, switched, crossSent, lostUpdate, selfFail>>

(* ServerLedgerSync.refresh: stale snapshot -> staleRevision; cache fence >=. *)
ReadEnd ==
  /\ rd # -1
  /\ cacheRev' = IF rd >= cacheRev /\ instActive["L"] = "A" THEN rd ELSE cacheRev
  /\ rd' = -1
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, st, exp, due, seen,
                 token, instActive, gen, epoch, drain, net, losses,
                 crashes, switched, crossSent, lostUpdate, selfFail>>

(* store.pendingOperations(dueAt: now) in creation order.                    *)
(* Old: every due waiting row. Fixed: stop the group at the first row that   *)
(* is not due (ServerLedgerQueueOrder.drainable).                            *)
RECURSIVE Prefix(_)
Prefix(i) == IF i > N THEN <<>>
             ELSE IF st[i] \in Waiting
                  THEN IF due[i] THEN <<i>> \o Prefix(i+1) ELSE <<>>
                  ELSE Prefix(i+1)
RECURSIVE AllDue(_)
AllDue(i) == IF i > N THEN <<>>
             ELSE IF st[i] \in Waiting /\ due[i] THEN <<i>> \o AllDue(i+1)
             ELSE AllDue(i+1)
DrainList == IF HeadOfLine THEN Prefix(1) ELSE AllDue(1)

DrainStart(owner) ==
  /\ ~drain.on /\ net.phase = "none"
  /\ instActive[owner] = "A"            \* ensureActiveAccount(A)
  /\ DrainList # <<>>
  /\ drain' = [on |-> TRUE, owner |-> owner, acct |-> instActive[owner],
               g |-> gen[owner], ep |-> epoch, list |-> DrainList, wait |-> FALSE]
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, token, instActive, gen, epoch, net,
                 losses, crashes, switched, crossSent, lostUpdate, selfFail>>

(* ensureGeneration + (fixed) store epoch + token subject check *)
SendAllowed ==
  /\ gen[drain.owner] = drain.g /\ instActive[drain.owner] = drain.acct
  /\ (AccountFence => (epoch = drain.ep /\ token = drain.acct))

(* ServerLedgerQueueOrder.reservationIsIntact *)
Guarded(o) ==
  /\ ReservedGuard /\ Kind[o] # "create"
  /\ \E k \in seen[o]..(exp[o] - 1) :
        ~\E j \in Ops : st[j] = "succeeded" /\ exp[j] = k

MarkFailed(o) ==
  /\ st' = [st EXCEPT ![o] = "failed"]
  /\ selfFail' = (selfFail \/ ~PeerWroteAfter(seen[o]))

(* One loop iteration of drainPendingOperations: check, markInFlight, send. *)
DrainSend ==
  /\ drain.on /\ ~drain.wait /\ drain.list # <<>>
  /\ LET o == Head(drain.list) IN
     IF ~SendAllowed
     THEN \* throws accountChanged; row untouched
          /\ drain' = NoDrain
          /\ UNCHANGED <<st, selfFail, net, crossSent>>
     ELSE IF Guarded(o)
     THEN \* fixed: reservation is void -> visible conflict, nothing sent
          /\ MarkFailed(o)
          /\ drain' = NoDrain
          /\ UNCHANGED <<net, crossSent>>
     ELSE \* old code also reaches here for a row deleted by clear()
          /\ st' = IF st[o] = "deleted" THEN st ELSE [st EXCEPT ![o] = "inflight"]
          /\ net' = [op |-> o, tok |-> token, e |-> exp[o], phase |-> "req",
                     result |-> "none", rev |-> 0]
          /\ crossSent' = (crossSent \/ (token # "none" /\ token # drain.acct))
          /\ drain' = [drain EXCEPT !.wait = TRUE]
          /\ UNCHANGED <<selfFail>>
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, exp,
                 due, seen, token, instActive, gen, epoch, losses, crashes, switched,
                 lostUpdate>>

DrainEmpty ==
  /\ drain.on /\ ~drain.wait /\ drain.list = <<>>
  /\ drain' = NoDrain
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, token, instActive, gen, epoch, net,
                 losses, crashes, switched, crossSent, lostUpdate, selfFail>>

(* kernel.ts executeInTransaction *)
Server ==
  /\ net.phase = "req"
  /\ LET o == net.op IN
     IF net.tok = "none"
     THEN /\ net' = [net EXCEPT !.phase = "resp", !.result = "unauth"]
          /\ UNCHANGED <<srvRev, writer, applied, receipt, lostUpdate>>
     ELSE IF <<net.tok, o>> \in receipt
     THEN /\ net' = [net EXCEPT !.phase = "resp", !.result = "ok", !.rev = srvRev]
          /\ UNCHANGED <<srvRev, writer, applied, receipt, lostUpdate>>
     ELSE IF net.e # srvRev
     THEN /\ net' = [net EXCEPT !.phase = "resp", !.result = "conflict", !.rev = srvRev]
          /\ UNCHANGED <<srvRev, writer, applied, receipt, lostUpdate>>
     ELSE /\ srvRev < MaxRev
          /\ srvRev' = srvRev + 1
          /\ writer' = [writer EXCEPT ![srvRev + 1] = "own"]
          /\ applied' = [applied EXCEPT ![o] = @ + 1]
          /\ receipt' = receipt \cup {<<net.tok, o>>}
          \* An edit that commits over a peer revision the user never saw.
          /\ lostUpdate' = (lostUpdate \/
                (Kind[o] # "create" /\ PeerWroteAfter(seen[o])))
          /\ net' = [net EXCEPT !.phase = "resp", !.result = "ok", !.rev = srvRev + 1]
  /\ UNCHANGED <<peerWrites, cacheRev, rd, st, exp, due, seen, token,
                 instActive, gen, epoch, drain, losses, crashes, switched, crossSent,
                 selfFail>>

(* Request or response lost: URLError -> ServerLedgerAPIClientError.offline *)
Lose ==
  /\ net.phase \in {"req", "resp"} /\ losses < MaxLoss /\ net.result # "offline"
  /\ net' = [net EXCEPT !.phase = "resp", !.result = "offline"]
  /\ losses' = losses + 1
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, token, instActive, gen, epoch, drain,
                 crashes, switched, crossSent, lostUpdate, selfFail>>

(* Response handling in drainPendingOperations + recordFailure. *)
Receive ==
  /\ drain.on /\ drain.wait /\ net.phase = "resp"
  /\ LET o == net.op
         r == net.result
         live == st[o] # "deleted"
     IN
     IF ~(gen[drain.owner] = drain.g /\ instActive[drain.owner] = drain.acct
          /\ (AccountFence => epoch = drain.ep))
     THEN /\ drain' = NoDrain            \* accountChanged: row stays inFlight
          /\ UNCHANGED <<st, due, selfFail, cacheRev>>
     ELSE IF r = "ok"
     THEN /\ st' = IF live THEN [st EXCEPT ![o] = "succeeded"] ELSE st
          /\ cacheRev' = IF net.rev >= cacheRev THEN net.rev ELSE cacheRev
          /\ drain' = [drain EXCEPT !.wait = FALSE, !.list = Tail(drain.list)]
          /\ UNCHANGED <<due, selfFail>>
     ELSE IF r = "conflict"
     THEN /\ IF live THEN MarkFailed(o) ELSE UNCHANGED <<st, selfFail>>
          /\ cacheRev' = IF net.rev >= cacheRev THEN net.rev ELSE cacheRev
          /\ drain' = NoDrain
          /\ UNCHANGED due
     ELSE IF r = "offline"
     THEN /\ st' = IF live THEN [st EXCEPT ![o] = "retrying"] ELSE st
          /\ due' = [due EXCEPT ![o] = FALSE]       \* nextRetryAt = now + backoff
          /\ drain' = NoDrain
          /\ UNCHANGED <<selfFail, cacheRev>>
     ELSE \* unauthorized: retry(after: nil)
          /\ st' = IF live THEN [st EXCEPT ![o] = "retrying"] ELSE st
          /\ drain' = NoDrain
          /\ UNCHANGED <<due, selfFail, cacheRev>>
  /\ net' = NoNet
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, rd, exp, seen, token,
                 instActive, gen, epoch, losses, crashes, switched, crossSent,
                 lostUpdate>>

(* App killed / suspended for good while draining. An inFlight row stays   *)
(* inFlight; a request already on the wire may still reach the server.    *)
Crash ==
  /\ drain.on /\ crashes < MaxCrash
  /\ drain' = NoDrain
  /\ net' = IF net.phase = "req" THEN net ELSE NoNet
  /\ crashes' = crashes + 1
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, token, instActive, gen, epoch, losses,
                 switched, crossSent, lostUpdate, selfFail>>

(* An orphaned request (its drain is gone) is answered into the void. *)
DropOrphan ==
  /\ ~drain.on /\ net.phase = "resp"
  /\ net' = NoNet
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, token, instActive, gen, epoch, drain,
                 losses, crashes, switched, crossSent, lostUpdate, selfFail>>

(* 401 elsewhere: invalidateUnauthorizedSession clears the token, keeps   *)
(* the queue, marks sync unauthorized (any markReconnected undoes that).  *)
SessionLost ==
  /\ AllowSwitch /\ token = "A"
  /\ token' = "none"
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, instActive, gen, epoch, drain, net,
                 losses, crashes, switched, crossSent, lostUpdate, selfFail>>

(* authenticateWithApple: persistVerifiedSession writes B's token off the *)
(* main actor ...                                                         *)
SignInBToken ==
  /\ AllowSwitch /\ token = "none" /\ ~switched
  /\ token' = "B" /\ switched' = TRUE
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, cacheRev, rd, st,
                 exp, due, seen, instActive, gen, epoch, drain, net,
                 losses, crashes, crossSent, lostUpdate, selfFail>>

(* ... then MainActor.run { lifecycle.activate(B) }: store.clear(A), only *)
(* the lifecycle's ServerLedgerSync generation is bumped.                 *)
ActivateB ==
  /\ token = "B" /\ instActive["L"] = "A"
  /\ st' = [o \in Ops |-> IF st[o] = "none" THEN "none" ELSE "deleted"]
  /\ epoch' = epoch + 1
  /\ instActive' = [instActive EXCEPT !["L"] = "B"]
  /\ gen' = [gen EXCEPT !["L"] = @ + 1]
  /\ cacheRev' = 0
  /\ UNCHANGED <<srvRev, writer, applied, receipt, peerWrites, rd, exp, due, seen,
                 token, drain, net, losses, crashes, switched,
                 crossSent, lostUpdate, selfFail>>

Next ==
  \/ \E o \in Ops : Create(o) \/ Tick(o)
  \/ PeerWrite \/ ReadStart \/ ReadEnd
  \/ \E owner \in Owners : DrainStart(owner)
  \/ DrainSend \/ DrainEmpty \/ Server \/ Lose \/ Receive \/ Crash \/ DropOrphan
  \/ SessionLost \/ SignInBToken \/ ActivateB

Fairness ==
  /\ \A o \in Ops : WF_vars(Tick(o))
  /\ WF_vars(DrainStart("L"))
  /\ WF_vars(DrainSend) /\ WF_vars(DrainEmpty) /\ WF_vars(Server)
  /\ WF_vars(Receive) /\ WF_vars(DropOrphan)
  /\ WF_vars(ReadStart) /\ WF_vars(ReadEnd)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
TypeOK ==
  /\ st \in [Ops -> {"none"} \cup Waiting \cup Terminal]
  /\ srvRev \in 0..MaxRev /\ cacheRev \in 0..MaxRev

NoDoubleApply   == \A o \in Ops : applied[o] <= 1
NoCrossAccount  == ~crossSent
NoLostUpdate    == ~lostUpdate
NoSelfConflict  == ~selfFail      \* a row fails only because of a real peer change
SucceededApplied == \A o \in Ops : st[o] = "succeeded" => applied[o] = 1

CacheMonotonic == [][cacheRev' >= cacheRev \/ instActive'["L"] # "A"]_vars

\* Liveness (run with AllowSwitch = FALSE): every queued row ends applied
\* exactly once or failed; the cache reaches the server revision.
QueueDrains  == <>[](\A o \in Ops : st[o] \in {"none", "succeeded", "failed"})
Converges    == <>[](cacheRev = srvRev)
AppliedOrFailed == []((\A o \in Ops : st[o] \in {"none","succeeded","failed"}) =>
                      \A o \in Ops : st[o] = "succeeded" => applied[o] = 1)
=============================================================================
