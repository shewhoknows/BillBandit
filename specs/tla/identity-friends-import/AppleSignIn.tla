----------------------------- MODULE AppleSignIn -----------------------------
(***************************************************************************)
(* POST /api/mobile/auth/apple for ONE Apple subject from several devices. *)
(* The route runs prisma.account.upsert with a nested connectOrCreate on   *)
(* User. With a nested write Prisma cannot use INSERT ... ON CONFLICT, so  *)
(* it reads, then inserts: two first sign-ins can both miss the Account    *)
(* row; the slower insert hits the unique key (P2002).                     *)
(*                                                                         *)
(* Start: the subject's earlier account u0 was deleted (its Account row    *)
(* was removed, the User row anonymised), so this is a first sign-in.      *)
(* Old (FIX = FALSE): P2002 -> 401 "Apple sign-in failed".                 *)
(* Fixed (FIX = TRUE): P2002 -> retry (up to 3 attempts) -> finds the row. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS FIX, Devices, Users

VARIABLES
  account,     \* the user the Apple Account row points to, or "none"
  live,        \* set of users that exist and are not deleted
  dead,        \* set of deleted users
  pc, saw, attempts, signedIn

vars == <<account, live, dead, pc, saw, attempts, signedIn>>

Init ==
  /\ account = "none"
  /\ live = {}
  /\ dead = {"u0"}
  /\ pc = [d \in Devices |-> "start"]
  /\ saw = [d \in Devices |-> "none"]
  /\ attempts = [d \in Devices |-> 0]
  /\ signedIn = [d \in Devices |-> "none"]

\* upsert step 1: find the Account by (provider, subject).
Find(d) ==
  /\ pc[d] = "start"
  /\ saw' = [saw EXCEPT ![d] = account]
  /\ attempts' = [attempts EXCEPT ![d] = @ + 1]
  /\ pc' = [pc EXCEPT ![d] = IF account = "none" THEN "create" ELSE "ok"]
  /\ signedIn' = [signedIn EXCEPT ![d] = IF account = "none" THEN "none" ELSE account]
  /\ UNCHANGED <<account, live, dead>>

\* upsert step 2: create Account + User (one INSERT transaction).
Create(d) ==
  /\ pc[d] = "create"
  /\ IF account = "none"
       THEN \E u \in Users \ (live \cup dead) :
              /\ account' = u
              /\ live' = live \cup {u}
              /\ signedIn' = [signedIn EXCEPT ![d] = u]
              /\ pc' = [pc EXCEPT ![d] = "ok"]
       ELSE \* unique key on (provider, providerAccountId) / User.email
            /\ UNCHANGED <<account, live, signedIn>>
            /\ pc' = [pc EXCEPT ![d] =
                 IF FIX /\ attempts[d] < 3 THEN "start" ELSE "failed"]
  /\ UNCHANGED <<dead, saw, attempts>>

AllDone == \A d \in Devices : pc[d] \in {"ok", "failed"}
Finished == AllDone /\ UNCHANGED vars
Next == (\E d \in Devices : Find(d) \/ Create(d)) \/ Finished
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK == pc \in [Devices -> {"start", "create", "ok", "failed"}]

\* No device gets "Apple sign-in failed" for a valid identity token.
NoSpuriousFailure == \A d \in Devices : pc[d] # "failed"

\* At most one live account per Apple subject.
OneLiveAccount == Cardinality(live) <= 1

\* Every signed-in device got the same, live (not the deleted) account.
SameFreshAccount ==
  \A d, e \in Devices :
    (pc[d] = "ok" /\ pc[e] = "ok") => (signedIn[d] = signedIn[e] /\ signedIn[d] \in live)

Terminates == <>AllDone
=============================================================================
