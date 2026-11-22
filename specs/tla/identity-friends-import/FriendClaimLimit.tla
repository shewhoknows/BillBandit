--------------------------- MODULE FriendClaimLimit ---------------------------
(***************************************************************************)
(* Friend-code failure limit (FriendClaimRateLimit) for ONE claiming       *)
(* account, inside one 15-minute window (window expiry is not modelled).   *)
(* Each process is one HTTP claim request: a wrong code ("bad") or the     *)
(* account's known-good code ("good", e.g. a friend it already has).       *)
(*                                                                         *)
(* Old code (FIX = FALSE):                                                 *)
(*   1. read the row; if blockedUntil > now -> 429                         *)
(*   2. look the code up; wrong -> failureCount += 1 (atomic upsert),      *)
(*      block when it reaches LIMIT; right -> DELETE the row (reset).      *)
(*   Steps 1 and 2 are separate statements, no lock.                       *)
(* Fixed code (FIX = TRUE): steps 1-2 run in one transaction under a       *)
(* per-account advisory lock, and a right code does not reset the row.     *)
(* SERIAL = TRUE forces one request at a time even in the old code, to     *)
(* show the reset bug on its own.                                          *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS FIX, SERIAL, LIMIT, Procs

VARIABLES failures, blocked, looked, pc, kind, holder

vars == <<failures, blocked, looked, pc, kind, holder>>
UseLock == FIX \/ SERIAL

Init ==
  /\ failures = 0 /\ blocked = FALSE /\ looked = 0
  /\ pc = [p \in Procs |-> "start"]
  /\ kind = [p \in Procs |-> "bad"]
  /\ holder = "none"

\* Step 1: (lock), read the row, maybe refuse with 429.
Check(p) ==
  /\ pc[p] = "start"
  /\ \E k \in {"bad", "good"} : kind' = [kind EXCEPT ![p] = k]
  /\ IF UseLock THEN /\ holder = "none" /\ holder' = p ELSE UNCHANGED holder
  /\ pc' = [pc EXCEPT ![p] = IF blocked THEN "refused" ELSE "checked"]
  /\ UNCHANGED <<failures, blocked, looked>>

\* A refused request ends its transaction.
Refused(p) ==
  /\ pc[p] = "refused"
  /\ holder' = IF holder = p THEN "none" ELSE holder
  /\ pc' = [pc EXCEPT ![p] = "done"]
  /\ UNCHANGED <<failures, blocked, looked, kind>>

\* Step 2: look the code up and record the outcome; commit.
Lookup(p) ==
  /\ pc[p] = "checked"
  /\ IF kind[p] = "bad"
       THEN /\ looked' = looked + 1
            /\ failures' = failures + 1
            /\ blocked' = (blocked \/ failures + 1 >= LIMIT)
       ELSE /\ UNCHANGED looked
            /\ IF FIX
                 THEN UNCHANGED <<failures, blocked>>
                 ELSE /\ failures' = 0 /\ blocked' = FALSE   \* old: deleteMany on success
  /\ holder' = IF holder = p THEN "none" ELSE holder
  /\ pc' = [pc EXCEPT ![p] = "done"]
  /\ UNCHANGED kind

AllDone == \A p \in Procs : pc[p] = "done"
Finished == AllDone /\ UNCHANGED vars

Next == \/ \E p \in Procs : Check(p) \/ Refused(p) \/ Lookup(p)
        \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
  /\ failures \in Nat /\ blocked \in BOOLEAN /\ looked \in Nat
  /\ pc \in [Procs -> {"start", "checked", "refused", "done"}]

\* Security: in one window at most LIMIT wrong codes are ever looked up
\* (the LIMIT-th is looked up and answers 429).
LookedBound == looked <= LIMIT

\* Once blocked, the account stays blocked for the rest of the window.
BlockSticks == [][blocked => blocked']_vars

\* The lock is always released.
Terminates == <>(AllDone /\ holder = "none")
=============================================================================
