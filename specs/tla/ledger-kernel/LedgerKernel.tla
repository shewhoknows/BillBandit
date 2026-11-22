---------------------------- MODULE LedgerKernel ----------------------------
(***************************************************************************)
(* The shared-ledger mutation kernel (apps/api/lib/ledger/mutation/        *)
(* kernel.ts) plus the HTTP routes in front of it.                         *)
(*                                                                         *)
(* Two phones ("o" = owner, "a" = member) send ledger operations. Each     *)
(* operation has a stable operationId; a phone may send it again (timeout, *)
(* offline queue replay) while an earlier attempt is still in flight, or   *)
(* after a REVISION_CONFLICT with a refreshed Expected-Revision.           *)
(*                                                                         *)
(* One server transaction is split into the steps that really interleave  *)
(* under Postgres READ COMMITTED:                                          *)
(*   Begin   route checks + LedgerOperation upsert + kernel guards         *)
(*           (prepareMutation reads)                                        *)
(*   Blocked a second attempt with the same key waits on the unique index   *)
(*           of LedgerOperation(accountId, operationKey)                    *)
(*   Commit  reserveRevision: UPDATE Group ... WHERE settlementVersion =    *)
(*           expected AND isArchived = false, then the domain write,        *)
(*           journal and LedgerOperation COMMITTED, all in one commit.      *)
(* A rollback leaves no LedgerOperation row, so PENDING is never visible   *)
(* to another transaction; the model keeps only "committed or absent".     *)
(*                                                                         *)
(* Fixes = {} models the code before this change; {"route","upsert"} after.*)
(*   "route"  : DELETE/PUT routes also find a deleted expense, so the      *)
(*              kernel can replay the operation instead of a route 404.    *)
(*   "upsert" : a unique-key race on LedgerOperation is retried (replay).  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS MaxAttempts,
          Fixes,      \* Fixes \subseteq {"route", "upsert"}
          OwnerOps,   \* operation ids sent by the owner's phone, e.g. {"o1", "o2"}
          MemberOps   \* operation ids sent by the member's phone, e.g. {"a1"}

Ops     == OwnerOps \cup MemberOps
Owner(op) == IF op \in OwnerOps THEN "o" ELSE "a"
Clients == {"o", "a"}
Exps    == {"e0"} \cup Ops          \* e0 exists at start; "create" by op X creates expense X
Kinds   == {"create", "edit", "delete", "finalize"}
ExpenseKinds == {"create", "edit", "delete"}

Ok(v)   == [ok |-> TRUE, rev |-> v, code |-> "ok"]
Err(c)  == [ok |-> FALSE, rev |-> 0, code |-> c]
NoReply == [ok |-> FALSE, rev |-> 0, code |-> "none"]

VARIABLES
  rev,          \* Group.settlementVersion
  finalized,    \* Group.finalizedAt # null
  archived,     \* Group.isArchived
  exp,          \* Expense lifecycle: "none" | "active" | "deleted"
  opRow,        \* LedgerOperation row per operationId (committed or absent)
  req,          \* the phone-side queue entry per operation
  crev,         \* the revision each phone last read
  txs,          \* in-flight server transactions
  nextTx,
  applied,      \* how many times each operation's domain write committed
  firstOk,      \* the first success the server returned for each operation
  badReplay,    \* a later answer for the same operationId differed from its success
  frozenBroken, \* an expense changed in a finalized or archived group
  everDeleted   \* expenses that were deleted at some point

vars == <<rev, finalized, archived, exp, opRow, req, crev, txs, nextTx,
          applied, firstOk, badReplay, frozenBroken, everDeleted>>

Init ==
  /\ rev = 0 /\ finalized = FALSE /\ archived = FALSE
  /\ exp = [e \in Exps |-> IF e = "e0" THEN "active" ELSE "none"]
  /\ opRow = [op \in Ops |-> [committed |-> FALSE, rev |-> 0]]
  /\ req = [op \in Ops |-> [st |-> "idle", kind |-> "create", target |-> op, tries |-> 0]]
  /\ crev = [c \in Clients |-> 0]
  /\ txs = {}
  /\ nextTx = 0
  /\ applied = [op \in Ops |-> 0]
  /\ firstOk = [op \in Ops |-> NoReply]
  /\ badReplay = FALSE
  /\ frozenBroken = FALSE
  /\ everDeleted = {}

-----------------------------------------------------------------------------
(* Phone actions *)

Issue(op, k, e) ==
  /\ req[op].st = "idle"
  /\ k = "create" => e = op
  /\ k \in {"edit", "delete"} => e # op
  /\ k = "finalize" => (Owner(op) = "o" /\ e = "e0")   \* only the owner finalizes
  /\ req' = [req EXCEPT ![op] = [st |-> "queued", kind |-> k, target |-> e, tries |-> 0]]
  /\ UNCHANGED <<rev, finalized, archived, exp, opRow, crev, txs, nextTx,
                 applied, firstOk, badReplay, frozenBroken, everDeleted>>

\* Send, or re-send after a timeout while an earlier attempt is still in flight.
Send(op) ==
  /\ req[op].st \in {"queued", "sent"}
  /\ req[op].tries < MaxAttempts
  /\ txs' = txs \cup {[id |-> nextTx, op |-> op, phase |-> "begin", exp |-> crev[Owner(op)]]}
  /\ nextTx' = nextTx + 1
  /\ req' = [req EXCEPT ![op].st = "sent", ![op].tries = @ + 1]
  /\ UNCHANGED <<rev, finalized, archived, exp, opRow, crev, applied, firstOk,
                 badReplay, frozenBroken, everDeleted>>

\* The phone polls the change token and re-reads the group.
Refresh(c) ==
  /\ crev[c] # rev
  /\ crev' = [crev EXCEPT ![c] = rev]
  /\ UNCHANGED <<rev, finalized, archived, exp, opRow, req, txs, nextTx,
                 applied, firstOk, badReplay, frozenBroken, everDeleted>>

-----------------------------------------------------------------------------
(* Server: the answer for one attempt. Records the server-side property    *)
(* "same operationId never returns a different result after success", and *)
(* updates the phone queue (4xx is terminal on the phone since round 4).   *)

ReplyVars(t, res) ==
  /\ txs' = txs \ {t}
  /\ badReplay' = (badReplay \/ (firstOk[t.op].ok /\ res # firstOk[t.op]))
  /\ firstOk' = IF res.ok /\ ~firstOk[t.op].ok
                  THEN [firstOk EXCEPT ![t.op] = res] ELSE firstOk
  /\ IF req[t.op].st = "sent"
       THEN CASE res.ok ->
                   /\ req' = [req EXCEPT ![t.op].st = "done"]
                   /\ crev' = [crev EXCEPT ![Owner(t.op)] = res.rev]
              [] res.code \in {"conflict", "err500"} ->
                   \* refresh and queue the same operation again
                   /\ req' = [req EXCEPT ![t.op].st = "queued"]
                   /\ crev' = [crev EXCEPT ![Owner(t.op)] = rev]
              [] OTHER ->
                   /\ req' = [req EXCEPT ![t.op].st = "failed"]
                   /\ UNCHANGED crev
       ELSE UNCHANGED <<req, crev>>

\* Kernel guards in executeInTransaction / prepareExpense / finalize route,
\* in code order: expectedRevision, archived, expense exists, finalized.
GuardResult(t) ==
  LET k == req[t.op].kind
      e == req[t.op].target
  IN  CASE rev # t.exp                                      -> "conflict"
        [] archived                                         -> "archived"
        [] k \in {"edit", "delete"} /\ exp[e] # "active"    -> "notfound"
        [] finalized                                        -> "finalized"
        [] OTHER                                            -> "prepared"

ToPhaseOrReply(t, g) ==
  IF g = "prepared"
    THEN /\ txs' = (txs \ {t}) \cup {[t EXCEPT !.phase = "prepared"]}
         /\ UNCHANGED <<req, crev, firstOk, badReplay>>
    ELSE ReplyVars(t, Err(g))

OtherHoldsKey(t) == \E u \in txs : u.id # t.id /\ u.op = t.op /\ u.phase = "prepared"

Begin(t) ==
  /\ t \in txs /\ t.phase = "begin"
  /\ LET k == req[t.op].kind
         e == req[t.op].target
     IN
     \* Route: DELETE/PUT /api/mobile/expenses/:id first looks the expense up
     \* among ACTIVE expenses of the caller's groups (findExpenseGroup).
     IF "route" \notin Fixes /\ k \in {"edit", "delete"} /\ exp[e] # "active"
       THEN ReplyVars(t, Err("notfound"))
     ELSE IF opRow[t.op].committed
       THEN ReplyVars(t, Ok(opRow[t.op].rev))               \* replay
     ELSE IF OtherHoldsKey(t)
       THEN /\ txs' = (txs \ {t}) \cup {[t EXCEPT !.phase = "blocked"]}
            /\ UNCHANGED <<req, crev, firstOk, badReplay>>
     ELSE ToPhaseOrReply(t, GuardResult(t))
  /\ UNCHANGED <<rev, finalized, archived, exp, opRow, nextTx, applied,
                 frozenBroken, everDeleted>>

\* The other attempt with the same key has committed or rolled back.
\* Before: Prisma's upsert is SELECT-then-INSERT, so the INSERT fails with
\* P2002 (unique constraint) and the route answers 500.
\* After: P2002 on the LedgerOperation key is retried; the retry replays.
Unblock(t) ==
  /\ t \in txs /\ t.phase = "blocked"
  /\ ~OtherHoldsKey(t)
  /\ IF opRow[t.op].committed
       THEN ReplyVars(t, IF "upsert" \in Fixes THEN Ok(opRow[t.op].rev) ELSE Err("err500"))
       ELSE ToPhaseOrReply(t, GuardResult(t))
  /\ UNCHANGED <<rev, finalized, archived, exp, opRow, nextTx, applied,
                 frozenBroken, everDeleted>>

Effect(k, e) ==
  CASE k = "create" -> [exp EXCEPT ![e] = "active"]
    [] k = "edit"   -> exp
    [] k = "delete" -> [exp EXCEPT ![e] = "deleted"]
    [] OTHER        -> exp

\* reserveRevision / finalize updateMany: the compare-and-set on the group row.
Commit(t) ==
  /\ t \in txs /\ t.phase = "prepared"
  /\ LET k == req[t.op].kind
         e == req[t.op].target
     IN
     IF rev = t.exp /\ ~archived /\ (k = "finalize" => ~finalized)
       THEN /\ rev' = rev + 1
            /\ exp' = Effect(k, e)
            /\ finalized' = (finalized \/ k = "finalize")
            /\ opRow' = [opRow EXCEPT ![t.op] = [committed |-> TRUE, rev |-> rev + 1]]
            /\ applied' = [applied EXCEPT ![t.op] = @ + 1]
            /\ frozenBroken' = (frozenBroken \/ ((finalized \/ archived) /\ k \in ExpenseKinds))
            /\ everDeleted' = IF k = "delete" THEN everDeleted \cup {e} ELSE everDeleted
            /\ ReplyVars(t, Ok(rev + 1))
       ELSE /\ ReplyVars(t, Err("conflict"))
            /\ UNCHANGED <<rev, exp, finalized, opRow, applied, frozenBroken, everDeleted>>
  /\ UNCHANGED <<archived, nextTx>>

\* DELETE /api/mobile/groups/:id: SERIALIZABLE, SELECT ... FOR UPDATE on the
\* group row, requires a settled group (approximated: no active expense),
\* CAS on settlementVersion without a bump. Atomic with respect to Commit.
Archive ==
  /\ ~archived
  /\ \A e \in Exps : exp[e] # "active"
  /\ archived' = TRUE
  /\ UNCHANGED <<rev, finalized, exp, opRow, req, crev, txs, nextTx, applied,
                 firstOk, badReplay, frozenBroken, everDeleted>>

ServerStep == \E t \in txs : Begin(t) \/ Unblock(t) \/ Commit(t)

Next ==
  \/ \E op \in Ops, k \in Kinds, e \in Exps : Issue(op, k, e)
  \/ \E op \in Ops : Send(op)
  \/ \E c \in Clients : Refresh(c)
  \/ ServerStep
  \/ Archive

Spec == Init /\ [][Next]_vars /\ WF_vars(ServerStep)
              /\ \A op \in Ops : WF_vars(Send(op))

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
  /\ rev \in Nat
  /\ exp \in [Exps -> {"none", "active", "deleted"}]
  /\ \A t \in txs : t.phase \in {"begin", "blocked", "prepared"}

\* The same operationId never applies its write twice.
NoDoubleApply == \A op \in Ops : applied[op] <= 1

\* Every revision step is exactly one applied operation (no lost update:
\* two writes based on the same read can never both commit).
RevisionIsApplyCount ==
  rev = Cardinality({op \in Ops : applied[op] > 0})

\* Once the server answered success for an operationId, every later answer
\* for it is the same success with the same revision.
ReplayStable == ~badReplay

\* No expense is added, edited or deleted after finalize or archive.
FinalizedAndArchivedAreFrozen == ~frozenBroken

\* A deleted expense never comes back (so it never counts in balances again).
DeletedStaysDeleted == \A e \in everDeleted : exp[e] = "deleted"

\* Liveness: no server transaction is stuck forever (lock waits end).
TransactionsFinish == <>[](txs = {})
=============================================================================
