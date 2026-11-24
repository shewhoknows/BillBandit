--------------------------- MODULE CloudKitIdentity ---------------------------
(* CloudKit identity links and legacy-person resolution
   (docs/state-machines/identity-friends-import.md section 6).

   Part 1, links: two accounts may ask to link one CloudKit subject at the
   same time (device link or the owner's import prepare).
   FIX = TRUE: check + create run under the account lock, then the subject
   lock, in one transaction (identity.ts linkCloudKitIdentity).
   FIX = FALSE: check and create are separate steps with no lock; the unique
   index refuses the second create inside its transaction -> HTTP 500.

   Part 2, resolution: Priya's import has one legacy friend Meera and two
   money records (Meera's splits). Meera is not Priya's friend at first; a
   friendship can appear at any moment (claim on another connection). Two
   runs of the import (client retry) may overlap and crash.
   FIX = TRUE: phase 1 commits every person row at once (first committer
   wins, later runs reuse it); phase 2 re-reads the frozen row before any
   money (service.ts processAllRecords).
   FIX = FALSE: each run writes money with the answer it computed at start. *)
EXTENDS Naturals, FiniteSets

CONSTANTS FIX, Workers, Accounts, MaxCrash

Subject == "s"
MoneyRecs == {"m1", "m2"}
NONE == "none"

VARIABLES
  link,        \* subject -> account or NONE (ExternalIdentity provider cloudkit)
  lpc, seen,   \* link requests: per account
  friends,     \* Priya <-> Meera accepted friendship
  personRow,   \* frozen person row target: NONE | "meera" | "placeholder"
  money,       \* money record -> set of accounts its split was written for
  pc, res, idx,
  errors, crashes

vars == <<link, lpc, seen, friends, personRow, money, pc, res, idx, errors, crashes>>

Answer == IF friends THEN "meera" ELSE "placeholder"

Init ==
  /\ link = NONE
  /\ lpc = [a \in Accounts |-> "idle"] /\ seen = [a \in Accounts |-> NONE]
  /\ friends = FALSE
  /\ personRow = NONE
  /\ money = [m \in MoneyRecs |-> {}]
  /\ pc = [w \in Workers |-> "idle"] /\ res = [w \in Workers |-> NONE] /\ idx = [w \in Workers |-> 0]
  /\ errors = 0 /\ crashes = 0

(* ── Part 1: links ─────────────────────────────────────────────────────── *)
LinkStart(a) ==
  /\ lpc[a] = "idle"
  /\ IF FIX
       THEN \* one critical section: refuse if taken, else create
            /\ link' = IF link = NONE THEN a ELSE link
            /\ lpc' = [lpc EXCEPT ![a] = "done"]
            /\ UNCHANGED seen
       ELSE /\ seen' = [seen EXCEPT ![a] = link]
            /\ lpc' = [lpc EXCEPT ![a] = "create"]
            /\ UNCHANGED link
  /\ UNCHANGED <<friends, personRow, money, pc, res, idx, errors, crashes>>

LinkCreate(a) ==
  /\ lpc[a] = "create"
  /\ IF seen[a] # NONE THEN UNCHANGED <<link, errors>>   \* refused (409)
     ELSE IF link # NONE
       THEN /\ errors' = IF errors < 2 THEN errors + 1 ELSE errors \* unique key -> 500
            /\ UNCHANGED link
       ELSE /\ link' = a /\ UNCHANGED errors
  /\ lpc' = [lpc EXCEPT ![a] = "done"]
  /\ UNCHANGED <<seen, friends, personRow, money, pc, res, idx, crashes>>

(* ── Part 2: resolution ────────────────────────────────────────────────── *)
Befriend ==
  /\ ~friends /\ friends' = TRUE
  /\ UNCHANGED <<link, lpc, seen, personRow, money, pc, res, idx, errors, crashes>>

\* runNormalizedImport: validateAndResolve before processing.
Resolve(w) ==
  /\ pc[w] = "idle"
  /\ res' = [res EXCEPT ![w] = IF personRow # NONE THEN personRow ELSE Answer]
  /\ pc' = [pc EXCEPT ![w] = "people"]
  /\ UNCHANGED <<link, lpc, seen, friends, personRow, money, idx, errors, crashes>>

\* Phase 1: the person row; IMPORTED rows are reused, never rewritten.
People(w) ==
  /\ pc[w] = "people"
  /\ personRow' = IF personRow = NONE THEN res[w] ELSE personRow
  /\ pc' = [pc EXCEPT ![w] = "reread"]
  /\ UNCHANGED <<link, lpc, seen, friends, money, res, idx, errors, crashes>>

\* Phase 2 start: FIX re-resolves from the frozen row.
Reread(w) ==
  /\ pc[w] = "reread"
  /\ res' = IF FIX THEN [res EXCEPT ![w] = personRow] ELSE res
  /\ pc' = [pc EXCEPT ![w] = "money"]
  /\ idx' = [idx EXCEPT ![w] = 0]
  /\ UNCHANGED <<link, lpc, seen, friends, personRow, money, errors, crashes>>

\* One money record per transaction; an imported record is reused.
Money(w) ==
  /\ pc[w] = "money"
  /\ \E m \in MoneyRecs :
       /\ money' = [money EXCEPT ![m] = IF @ = {} THEN {res[w]} ELSE @]
  /\ idx' = [idx EXCEPT ![w] = @ + 1]
  /\ pc' = [pc EXCEPT ![w] = IF idx[w] + 1 >= 2 THEN "done" ELSE "money"]
  /\ UNCHANGED <<link, lpc, seen, friends, personRow, res, errors, crashes>>

Crash(w) ==
  /\ pc[w] \in {"people", "reread", "money"} /\ crashes < MaxCrash
  /\ crashes' = crashes + 1
  /\ pc' = [pc EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<link, lpc, seen, friends, personRow, money, res, idx, errors>>

Done == /\ \A a \in Accounts : lpc[a] = "done"
        /\ \A w \in Workers : pc[w] = "done"
        /\ UNCHANGED vars

Next ==
  \/ \E a \in Accounts : LinkStart(a) \/ LinkCreate(a)
  \/ Befriend
  \/ \E w \in Workers : Resolve(w) \/ People(w) \/ Reread(w) \/ Money(w) \/ Crash(w)
  \/ Done

Spec == Init /\ [][Next]_vars

(* ── Properties ───────────────────────────────────────────────────────── *)
TypeOK ==
  /\ link \in Accounts \cup {NONE}
  /\ personRow \in {NONE, "meera", "placeholder"}
  /\ \A m \in MoneyRecs : money[m] \subseteq {"meera", "placeholder"}

\* A link never answers 500 and, once made, never changes owner.
NoServerError == errors = 0
LinkNeverMoves == [][link # NONE => link' = link]_link

\* All of Meera's money goes to the one account her frozen person row names.
MoneySingleOwner ==
  /\ Cardinality(UNION {money[m] : m \in MoneyRecs}) <= 1
  /\ \A m \in MoneyRecs : money[m] # {} => money[m] = {personRow}
=============================================================================
