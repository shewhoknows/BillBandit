--------------------------- MODULE SettlementOutbox ---------------------------
(***************************************************************************)
(* One SettlementOutbox row and the workers that drain it                 *)
(* (apps/api/lib/settlement/outbox/dispatcher.ts, drainOutboxOnce).       *)
(*                                                                         *)
(* Real concurrency: every API process runs a 5 s interval drain AND a     *)
(* drain after every committed mutation (wakeOutboxDispatcher), so two     *)
(* drains can work on the same row at once. A lease lasts 30 s; a slow     *)
(* Pusher call can outlive it. A process can crash at any point.           *)
(*                                                                         *)
(* FENCED = FALSE models the code as it was: the final write after publish *)
(* is `update where { id }` with no lease check.                           *)
(* FENCED = TRUE models the fix: each lease gets a unique token and the    *)
(* final write is `updateMany where { id, state: LEASED, leaseOwner: tok }`.*)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Workers, FENCED, MaxFail, MaxCrash, MaxExpire

None == "none"

VARIABLES
  state,        \* row.state: "PENDING" | "LEASED" | "PUBLISHED"
  lease,        \* token of the current lease (0 = none)
  expired,      \* the current lease's leaseExpiresAt < now
  seq,          \* last lease token handed out
  pc,           \* per worker: "idle" | "publishing" | "ok" | "fail"
  mine,         \* per worker: lease token it took
  pubs,         \* how many times Pusher really received the event
  everPub,      \* history: row was PUBLISHED at some point
  fails, crashes, expires

vars == <<state, lease, expired, seq, pc, mine, pubs, everPub, fails, crashes, expires>>

TypeOK ==
  /\ state \in {"PENDING", "LEASED", "PUBLISHED"}
  /\ pc \in [Workers -> {"idle", "publishing", "ok", "fail"}]
  /\ lease \in 0..seq /\ mine \in [Workers -> 0..seq]
  /\ expired \in BOOLEAN /\ pubs \in Nat

Init ==
  /\ state = "PENDING" /\ lease = 0 /\ expired = FALSE /\ seq = 0
  /\ pc = [w \in Workers |-> "idle"] /\ mine = [w \in Workers |-> 0]
  /\ pubs = 0 /\ everPub = FALSE /\ fails = 0 /\ crashes = 0 /\ expires = 0

\* dispatcher.ts: updateMany LEASED & leaseExpiresAt < now -> PENDING
Reclaim(w) ==
  /\ pc[w] = "idle" /\ state = "LEASED" /\ expired
  /\ state' = "PENDING" /\ lease' = 0 /\ expired' = FALSE
  /\ UNCHANGED <<seq, pc, mine, pubs, everPub, fails, crashes, expires>>

\* dispatcher.ts: updateMany where { id, state: PENDING } -> LEASED
Lease(w) ==
  /\ pc[w] = "idle" /\ state = "PENDING"
  /\ seq' = seq + 1
  /\ state' = "LEASED" /\ lease' = seq + 1 /\ expired' = FALSE
  /\ mine' = [mine EXCEPT ![w] = seq + 1]
  /\ pc' = [pc EXCEPT ![w] = "publishing"]
  /\ UNCHANGED <<pubs, everPub, fails, crashes, expires>>

\* Wall clock passes leaseExpiresAt. While the holder is still working this
\* is a slow Pusher call (bounded by MaxExpire); an orphaned lease (holder
\* crashed or already gave up) always expires in the end.
HolderActive == \E w \in Workers : pc[w] # "idle" /\ mine[w] = lease
Expire ==
  /\ state = "LEASED" /\ ~expired
  /\ HolderActive => expires < MaxExpire
  /\ expired' = TRUE /\ expires' = IF HolderActive THEN expires + 1 ELSE expires
  /\ UNCHANGED <<state, lease, seq, pc, mine, pubs, everPub, fails, crashes>>

PublishOk(w) ==
  /\ pc[w] = "publishing"
  /\ pubs' = pubs + 1 /\ pc' = [pc EXCEPT ![w] = "ok"]
  /\ UNCHANGED <<state, lease, expired, seq, mine, everPub, fails, crashes, expires>>

PublishFail(w) ==
  /\ pc[w] = "publishing" /\ fails < MaxFail
  /\ fails' = fails + 1 /\ pc' = [pc EXCEPT ![w] = "fail"]
  /\ UNCHANGED <<state, lease, expired, seq, mine, pubs, everPub, crashes, expires>>

Holds(w) == state = "LEASED" /\ lease = mine[w]

\* After a successful publish: PUBLISHED, lease cleared.
CompleteOk(w) ==
  /\ pc[w] = "ok"
  /\ IF FENCED /\ ~Holds(w)
       THEN UNCHANGED <<state, lease, expired, everPub>>
       ELSE /\ state' = "PUBLISHED" /\ lease' = 0 /\ expired' = FALSE
            /\ everPub' = TRUE
  /\ pc' = [pc EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<seq, mine, pubs, fails, crashes, expires>>

\* After a failed publish: back to PENDING with backoff.
CompleteFail(w) ==
  /\ pc[w] = "fail"
  /\ IF FENCED /\ ~Holds(w)
       THEN UNCHANGED <<state, lease, expired>>
       ELSE /\ state' = "PENDING" /\ lease' = 0 /\ expired' = FALSE
  /\ pc' = [pc EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<seq, mine, pubs, everPub, fails, crashes, expires>>

\* Process dies between any two awaits; its lease stays until it expires.
Crash(w) ==
  /\ pc[w] # "idle" /\ crashes < MaxCrash
  /\ crashes' = crashes + 1 /\ pc' = [pc EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<state, lease, expired, seq, mine, pubs, everPub, fails, expires>>

Done == state = "PUBLISHED" /\ \A w \in Workers : pc[w] = "idle"

Next ==
  \/ Expire
  \/ \E w \in Workers :
       Reclaim(w) \/ Lease(w) \/ PublishOk(w) \/ PublishFail(w)
       \/ CompleteOk(w) \/ CompleteFail(w) \/ Crash(w)
  \/ (Done /\ UNCHANGED vars)

Fairness ==
  /\ WF_vars(Expire)
  /\ \A w \in Workers :
       /\ WF_vars(Reclaim(w)) /\ WF_vars(Lease(w)) /\ WF_vars(PublishOk(w))
       /\ WF_vars(CompleteOk(w)) /\ WF_vars(CompleteFail(w))

Spec == Init /\ [][Next]_vars /\ Fairness

(* Safety *)
NeverLost == state = "PUBLISHED" => pubs >= 1           \* marked only after a real publish
PublishedIsFinal == everPub => state = "PUBLISHED"     \* no PUBLISHED -> PENDING/LEASED
LeaseMatchesState == (state = "LEASED") <=> (lease # 0)

(* Liveness: the row is eventually published and every worker goes idle. *)
EventuallyPublished == <>[](Done)
=============================================================================
