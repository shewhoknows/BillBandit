---------------------------- MODULE CloudKitImport ----------------------------
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS FIX, ALLOW_CHANGE, Workers, MaxCrash

Records == <<"r1", "r2">>
RecSet == {Records[i] : i \in 1..Len(Records)}

VARIABLES
  imp,        \* LedgerImport.state, "none" before the row exists
  impSum,     \* LedgerImport.sourceChecksum (export version)
  rec,        \* LedgerImportRecord.state per record ("none" = no row)
  recSum,     \* LedgerImportRecord.payloadChecksum (version of that record)
  money,      \* number of target rows (expense/split/payment) per record
  exportVer,  \* version of the export the client currently holds
  pc, ver, idx, sawRow,
  errors,     \* HTTP 500 answers
  crashes

vars == <<imp, impSum, rec, recSum, money, exportVer, pc, ver, idx, sawRow, errors, crashes>>

\* Version of record r in export version v: only r1 changes in version 2.
RecVer(r, v) == IF r = "r1" THEN v ELSE 1

Init ==
  /\ imp = "none" /\ impSum = 0
  /\ rec = [r \in RecSet |-> "none"] /\ recSum = [r \in RecSet |-> 0]
  /\ money = [r \in RecSet |-> 0]
  /\ exportVer = 1
  /\ pc = [w \in Workers |-> "idle"]
  /\ ver = [w \in Workers |-> 0]
  /\ idx = [w \in Workers |-> 1]
  /\ sawRow = [w \in Workers |-> FALSE]
  /\ errors = 0 /\ crashes = 0

Start(w) ==
  /\ pc[w] = "idle"
  /\ ver' = [ver EXCEPT ![w] = exportVer]
  /\ pc' = [pc EXCEPT ![w] = IF FIX THEN "prepare" ELSE "find"]
  /\ UNCHANGED <<imp, impSum, rec, recSum, money, exportVer, idx, sawRow, errors, crashes>>

\* Old code only: the first statement of the prepare transaction.
Find(w) ==
  /\ pc[w] = "find"
  /\ sawRow' = [sawRow EXCEPT ![w] = (imp # "none")]
  /\ pc' = [pc EXCEPT ![w] = "prepare"]
  /\ UNCHANGED <<imp, impSum, rec, recSum, money, exportVer, ver, idx, errors, crashes>>

\* The rest of prepareImport, committed at once. With FIX the lock makes
\* find + create one critical section, so sawRow is read here.
Prepare(w) ==
  /\ pc[w] = "prepare"
  /\ LET seen == IF FIX THEN imp # "none" ELSE sawRow[w]
         v == ver[w]
     IN
     IF ~seen /\ imp # "none"
       THEN \* create hit the unique key; transaction aborted
            /\ errors' = IF errors < 2 THEN errors + 1 ELSE errors
            /\ pc' = [pc EXCEPT ![w] = "done"]
            /\ UNCHANGED <<imp, impSum, rec, recSum>>
       ELSE IF imp = "COMPLETED"
       THEN /\ pc' = [pc EXCEPT ![w] = "done"]   \* 200 completed (or 409 frozen)
            /\ UNCHANGED <<imp, impSum, rec, recSum, errors>>
       ELSE IF ~FIX /\ imp # "none" /\ impSum # v
       THEN /\ imp' = "FAILED"                   \* checksum changed while incomplete
            /\ pc' = [pc EXCEPT ![w] = "done"]
            /\ UNCHANGED <<impSum, rec, recSum, errors>>
       ELSE IF \E r \in RecSet : rec[r] # "none" /\ recSum[r] # RecVer(r, v) /\ (~FIX \/ rec[r] = "IMPORTED")
       THEN /\ imp' = "FAILED"                   \* record changed after it was recorded
            /\ impSum' = IF FIX THEN impSum ELSE v
            /\ pc' = [pc EXCEPT ![w] = "done"]
            /\ UNCHANGED <<rec, recSum, errors>>
       ELSE /\ imp' = "RUNNING"
            /\ impSum' = v
            /\ rec' = [r \in RecSet |-> IF rec[r] = "IMPORTED" THEN "IMPORTED" ELSE "PENDING"]
            /\ recSum' = [r \in RecSet |-> RecVer(r, v)]
            /\ pc' = [pc EXCEPT ![w] = "process"]
            /\ UNCHANGED errors
  /\ UNCHANGED <<money, exportVer, ver, idx, sawRow, crashes>>

\* One record transaction: upsert by deterministic id, mark IMPORTED.
\* Prisma's upsert on a unique id is INSERT ... ON CONFLICT, so even the old
\* code (no lock) cannot make a second target row.
Process(w) ==
  /\ pc[w] = "process"
  /\ (~FIX \/ (imp = "RUNNING" /\ impSum = ver[w]))
  /\ idx[w] <= Len(Records)
  /\ LET r == Records[idx[w]] IN
       /\ money' = [money EXCEPT ![r] = 1]
       /\ rec' = [rec EXCEPT ![r] = "IMPORTED"]
  /\ idx' = [idx EXCEPT ![w] = @ + 1]
  /\ UNCHANGED <<imp, impSum, recSum, exportVer, pc, ver, sawRow, errors, crashes>>

Complete(w) ==
  /\ pc[w] = "process"
  /\ (~FIX \/ (imp = "RUNNING" /\ impSum = ver[w]))
  /\ idx[w] > Len(Records)
  /\ IF (\A r \in RecSet : rec[r] = "IMPORTED") /\ (FIX => imp = "RUNNING")
       THEN imp' = "COMPLETED"
       ELSE UNCHANGED imp
  /\ pc' = [pc EXCEPT ![w] = "done"]
  /\ UNCHANGED <<impSum, rec, recSum, money, exportVer, ver, idx, sawRow, errors, crashes>>

Superseded(w) ==
  /\ FIX /\ pc[w] = "process" /\ (imp # "RUNNING" \/ impSum # ver[w])
  /\ pc' = [pc EXCEPT ![w] = "done"]
  /\ UNCHANGED <<imp, impSum, rec, recSum, money, exportVer, ver, idx, sawRow, errors, crashes>>

\* A run dies between transactions (process killed, deploy, timeout).
Crash(w) ==
  /\ pc[w] \in {"find", "prepare", "process"}
  /\ crashes < MaxCrash
  /\ crashes' = crashes + 1
  /\ pc' = [pc EXCEPT ![w] = "done"]
  /\ UNCHANGED <<imp, impSum, rec, recSum, money, exportVer, ver, idx, sawRow, errors>>

\* The client keeps retrying while the import is not complete (a new request
\* from the same worker slot).
Restart(w) ==
  /\ pc[w] = "done" /\ imp # "COMPLETED"
  /\ pc' = [pc EXCEPT ![w] = "idle"]
  /\ idx' = [idx EXCEPT ![w] = 1]
  /\ sawRow' = [sawRow EXCEPT ![w] = FALSE]
  /\ UNCHANGED <<imp, impSum, rec, recSum, money, exportVer, ver, errors, crashes>>

\* The client re-reads CloudKit (it had no importId yet) and one record changed.
SourceChange ==
  /\ ALLOW_CHANGE /\ exportVer = 1 /\ imp # "COMPLETED"
  /\ exportVer' = 2
  /\ UNCHANGED <<imp, impSum, rec, recSum, money, pc, ver, idx, sawRow, errors, crashes>>

AllDone == (\A w \in Workers : pc[w] = "done") /\ imp = "COMPLETED"
Finished == AllDone /\ UNCHANGED vars

Next ==
  \/ \E w \in Workers : Start(w) \/ Find(w) \/ Prepare(w) \/ Process(w) \/ Complete(w) \/ Superseded(w) \/ Crash(w) \/ Restart(w)
  \/ SourceChange
  \/ Finished

Fair == \A w \in Workers : WF_vars(Start(w) \/ Find(w) \/ Prepare(w) \/ Process(w) \/ Complete(w) \/ Superseded(w) \/ Restart(w))
Spec == Init /\ [][Next]_vars /\ Fair

(* ── Properties ───────────────────────────────────────────────────────── *)
TypeOK ==
  /\ imp \in {"none", "PENDING", "RUNNING", "COMPLETED", "FAILED"}
  /\ rec \in [RecSet -> {"none", "PENDING", "IMPORTED"}]
  /\ money \in [RecSet -> 0..2]
  /\ errors \in 0..2

\* Money is never imported twice.
MoneyOnce == \A r \in RecSet : money[r] <= 1

\* A completed import holds every record exactly once.
CompletedIsWhole == imp = "COMPLETED" => \A r \in RecSet : rec[r] = "IMPORTED" /\ money[r] = 1

\* Two runs at once never answer 500.
NoServerError == errors = 0

\* Only the transitions in lib/identity-friends-state.ts IMPORT_TRANSITIONS.
Allowed == {<<"none", "RUNNING">>, <<"none", "FAILED">>, <<"RUNNING", "RUNNING">>,
            <<"RUNNING", "COMPLETED">>, <<"RUNNING", "FAILED">>,
            <<"FAILED", "RUNNING">>, <<"FAILED", "FAILED">>}
LegalTransitions == [][imp # imp' => <<imp, imp'>> \in Allowed]_imp

EventuallyCompleted == <>(imp = "COMPLETED" \/ (imp = "FAILED" /\ \E r \in RecSet : rec[r] = "IMPORTED" /\ recSum[r] # RecVer(r, exportVer)))
=============================================================================
