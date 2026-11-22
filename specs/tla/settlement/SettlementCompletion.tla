------------------------- MODULE SettlementCompletion -------------------------
(***************************************************************************)
(* Group.hadOpenTransfers / Group.settlementCompletedAt                    *)
(* (apps/api/lib/settlement/version/sources.ts, onSettlementCommandCommitted)*)
(*                                                                         *)
(* A settle or reverse request commits in the kernel (one atomic step,     *)
(* serialized by the settlementVersion CAS), and THEN, in a second         *)
(* transaction, the route recomputes the two group flags. Expense writes   *)
(* go through other routes and never touch the flags.                      *)
(*                                                                         *)
(* One debt direction is enough: `owed` = expenses - active payments.      *)
(* Time is the group version (each commit is one tick).                    *)
(*                                                                         *)
(* FIX = FALSE: old rule, read flags+ledger, write later (no lock),        *)
(*   completedAt kept as `existing ?? now`.                                *)
(* FIX = TRUE: group row locked (SELECT ... FOR UPDATE) for read+write, and *)
(*   completedAt = time of the latest settle/reverse journal entry when    *)
(*   the plan is empty, else null.                                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Clients, MaxExp, MaxCmds, MaxCrash, FIX

Null == 0

VARIABLES
  exp, pays, version,            \* ledger: expense units, payments, group version
  hadOpen, completedAt,          \* the derived flags on Group
  lastSettleEvt,                 \* version of the latest settle/reverse journal row
  lastKind,                      \* kind of the latest commit: "none"|"expense"|"settle"
  pc, snap, cmds, crashes

vars == <<exp, pays, version, hadOpen, completedAt, lastSettleEvt, lastKind,
          pc, snap, cmds, crashes>>

Sum(S) == LET F[T \in SUBSET S] ==
              IF T = {} THEN 0 ELSE LET p == CHOOSE p \in T : TRUE IN p.amt + F[T \ {p}]
          IN F[S]
Active == {p \in pays : ~p.rev}
Owed == exp - Sum(Active)
Empty == Owed = 0

Init ==
  /\ exp = 0 /\ pays = {} /\ version = 0
  /\ hadOpen = FALSE /\ completedAt = Null /\ lastSettleEvt = Null /\ lastKind = "none"
  /\ pc = [c \in Clients |-> "idle"]
  /\ snap = [c \in Clients |-> [had |-> FALSE, at |-> Null, empty |-> TRUE, evt |-> Null, kind |-> "none"]]
  /\ cmds = [c \in Clients |-> 0] /\ crashes = 0

\* ---- ledger commits (kernel transaction, atomic) ----
AddExpense ==
  /\ exp < MaxExp
  /\ exp' = exp + 1 /\ version' = version + 1 /\ lastKind' = "expense"
  /\ UNCHANGED <<pays, hadOpen, completedAt, lastSettleEvt, pc, snap, cmds, crashes>>

Settle(c, amt) ==
  /\ pc[c] = "idle" /\ cmds[c] < MaxCmds
  /\ amt \in 1..Owed                      \* kernel: 0 < amount <= owed
  /\ pays' = pays \cup {[id |-> version + 1, amt |-> amt, rev |-> FALSE]}
  /\ version' = version + 1 /\ lastSettleEvt' = version + 1 /\ lastKind' = "settle"
  /\ pc' = [pc EXCEPT ![c] = "post"] /\ cmds' = [cmds EXCEPT ![c] = @ + 1]
  /\ snap' = [snap EXCEPT ![c].kind = "created"]
  /\ UNCHANGED <<exp, hadOpen, completedAt, crashes>>

Reverse(c, p) ==
  /\ pc[c] = "idle" /\ cmds[c] < MaxCmds
  /\ p \in Active
  /\ pays' = (pays \ {p}) \cup {[p EXCEPT !.rev = TRUE]}
  /\ version' = version + 1 /\ lastSettleEvt' = version + 1 /\ lastKind' = "settle"
  /\ pc' = [pc EXCEPT ![c] = "post"] /\ cmds' = [cmds EXCEPT ![c] = @ + 1]
  /\ snap' = [snap EXCEPT ![c].kind = "reversed"]
  /\ UNCHANGED <<exp, hadOpen, completedAt, crashes>>

\* ---- post-commit flag update (route, second transaction) ----
OldValue(s, now) ==
  LET settledAll == s.had \/ (s.kind = "created" /\ s.empty)
  IN IF settledAll /\ s.empty THEN (IF s.at # Null THEN s.at ELSE now)
     ELSE IF s.empty THEN s.at ELSE Null

\* old: read group flags and ledger ...
PostRead(c) ==
  /\ ~FIX /\ pc[c] = "post"
  /\ snap' = [snap EXCEPT ![c] = [had |-> hadOpen, at |-> completedAt, empty |-> Empty,
                                  evt |-> lastSettleEvt, kind |-> snap[c].kind]]
  /\ pc' = [pc EXCEPT ![c] = "write"]
  /\ UNCHANGED <<exp, pays, version, hadOpen, completedAt, lastSettleEvt, lastKind, cmds, crashes>>

\* ... and write later; `now` is the wall clock at write time.
PostWrite(c) ==
  /\ ~FIX /\ pc[c] = "write"
  /\ hadOpen' = ~snap[c].empty
  /\ completedAt' = OldValue(snap[c], version)
  /\ pc' = [pc EXCEPT ![c] = "idle"]
  /\ UNCHANGED <<exp, pays, version, lastSettleEvt, lastKind, snap, cmds, crashes>>

\* fix: one locked step; kernel commits need the same row lock.
PostLocked(c) ==
  /\ FIX /\ pc[c] = "post"
  /\ hadOpen' = ~Empty
  /\ completedAt' = IF Empty THEN lastSettleEvt ELSE Null
  /\ pc' = [pc EXCEPT ![c] = "idle"]
  /\ UNCHANGED <<exp, pays, version, lastSettleEvt, lastKind, snap, cmds, crashes>>

\* The process dies after the kernel commit, before the flag update.
Crash(c) ==
  /\ pc[c] \in {"post", "write"} /\ crashes < MaxCrash
  /\ pc' = [pc EXCEPT ![c] = "idle"] /\ crashes' = crashes + 1
  /\ UNCHANGED <<exp, pays, version, hadOpen, completedAt, lastSettleEvt, lastKind, snap, cmds>>

Next ==
  \/ AddExpense
  \/ \E c \in Clients :
       \/ \E amt \in 1..MaxExp : Settle(c, amt)
       \/ \E p \in pays : Reverse(c, p)
       \/ PostRead(c) \/ PostWrite(c) \/ PostLocked(c) \/ Crash(c)

Spec == Init /\ [][Next]_vars

Quiescent == \A c \in Clients : pc[c] = "idle"

(* Safety *)
MoneyConserved == Owed >= 0 /\ Sum(Active) <= exp      \* never pay more than owed

\* What the settle-up screen shows after the last settle/reverse request
\* returned: "everyone is settled" + the moment the last payment action made
\* it so; no date while debts are open.
CompletionDateCorrect ==
  (Quiescent /\ lastKind = "settle") =>
     completedAt = (IF Empty THEN lastSettleEvt ELSE Null)

HadOpenCorrect ==
  (Quiescent /\ lastKind = "settle") => (hadOpen = ~Empty)
=============================================================================
