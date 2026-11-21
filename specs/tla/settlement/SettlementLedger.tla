--------------------------- MODULE SettlementLedger ---------------------------
(***************************************************************************)
(* Settle-up payments and reversals through the shared mutation kernel     *)
(* (lib/settlement/commands/{settle,reverse}.ts -> lib/ledger/mutation/    *)
(*  kernel.ts executeMutation).                                            *)
(*                                                                         *)
(* Each HTTP attempt is one Postgres transaction:                          *)
(*   1. ledgerOperation.upsert(accountId, operationKey)  -- unique index   *)
(*   2. COMMITTED row  -> replay stored result                             *)
(*   3. readGroup + expectedRevision check (own statement), then prepare  *)
(*      (plan, amount <= owed, not already reversed), CAS settlementVersion,*)
(*      write rows, journal, outbox, op COMMITTED.                         *)
(* Prisma's upsert here is find-then-insert. A second attempt with the     *)
(* same key that runs while the first is still open blocks on the unique   *)
(* index and, once the first commits, fails with P2002.                    *)
(*                                                                         *)
(* RETRY = FALSE: code as it was (P2002 is not transient -> HTTP 500).     *)
(* RETRY = TRUE : settle/reverse commands retry once on that P2002, which  *)
(*                then finds the COMMITTED row and replays it.             *)
(*                                                                         *)
(* Offline queue replay = the same key sent again later, possibly with a   *)
(* stale expectedRevision. Two phones = attempts with different keys.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Keys, Attempts, Debt, RETRY

\* A key is bound to one command the first time a client builds it.
Cmds == {[k |-> "settle", amt |-> a] : a \in 1..Debt} \cup {[k |-> "reverse", p |-> k2] : k2 \in Keys}
NoCmd == [k |-> "none"]

VARIABLES
  version, journal,   \* group.settlementVersion; set of versions journaled
  pays,               \* key -> [amt, rev] for applied payments (key = payment id)
  revOf,              \* payment key -> set of reversal keys that reversed it
  op,                 \* key -> "none" | "open" (uncommitted insert) | "committed"
  opHolder,           \* key -> attempt holding the uncommitted insert (0 = none)
  bound,              \* key -> command the client bound to it
  at,                 \* attempt -> [pc, key, exp]
  resp,               \* attempt -> "" | "applied" | "replayed" | "conflict" | "refused" | "500"
  nApplied            \* key -> how many times its command was applied

vars == <<version, journal, pays, revOf, op, opHolder, bound, at, resp, nApplied>>

Active == {k \in DOMAIN pays : ~pays[k].rev}
SumAmt(S) == LET F[T \in SUBSET S] == IF T = {} THEN 0
                 ELSE LET x == CHOOSE x \in T : TRUE IN pays[x].amt + F[T \ {x}]
             IN F[S]
Owed == Debt - SumAmt(Active)

Init ==
  /\ version = 0 /\ journal = {} /\ pays = <<>> /\ revOf = [k \in Keys |-> {}]
  /\ op = [k \in Keys |-> "none"] /\ opHolder = [k \in Keys |-> 0]
  /\ bound = [k \in Keys |-> NoCmd]
  /\ at = [a \in Attempts |-> [pc |-> "new", key |-> CHOOSE k \in Keys : TRUE, exp |-> 0]]
  /\ resp = [a \in Attempts |-> ""]
  /\ nApplied = [k \in Keys |-> 0]

\* Client sends (or re-sends from its offline queue) key k with the
\* revision it last saw. A new key gets a new command.
Send(a, k, c, e) ==
  /\ at[a].pc = "new"
  /\ IF bound[k] = NoCmd THEN bound' = [bound EXCEPT ![k] = c] ELSE (c = bound[k] /\ UNCHANGED bound)
  /\ e \in 0..version
  /\ at' = [at EXCEPT ![a] = [pc |-> "upsert", key |-> k, exp |-> e]]
  /\ UNCHANGED <<nApplied, version, journal, pays, revOf, op, opHolder, resp>>

\* ledgerOperation.upsert: find, then insert.
Upsert(a) ==
  LET k == at[a].key IN
  /\ at[a].pc = "upsert"
  /\ CASE op[k] = "committed" ->
            /\ resp' = [resp EXCEPT ![a] = "replayed"]
            /\ at' = [at EXCEPT ![a].pc = "done"]
            /\ UNCHANGED <<op, opHolder>>
       [] op[k] = "open" ->                        \* blocks on the unique index
            /\ at' = [at EXCEPT ![a].pc = "blocked"]
            /\ UNCHANGED <<op, opHolder, resp>>
       [] OTHER ->
            /\ op' = [op EXCEPT ![k] = "open"] /\ opHolder' = [opHolder EXCEPT ![k] = a]
            /\ at' = [at EXCEPT ![a].pc = "body"]
            /\ UNCHANGED resp
  /\ UNCHANGED <<nApplied, version, journal, pays, revOf, bound>>

\* The insert holder finished: P2002 if it committed, else our insert goes on.
Unblock(a) ==
  LET k == at[a].key IN
  /\ at[a].pc = "blocked" /\ op[k] # "open"
  /\ IF op[k] = "committed"
       THEN IF RETRY
              THEN /\ at' = [at EXCEPT ![a].pc = "upsert"] /\ UNCHANGED resp
              ELSE /\ resp' = [resp EXCEPT ![a] = "500"] /\ at' = [at EXCEPT ![a].pc = "done"]
       ELSE /\ at' = [at EXCEPT ![a].pc = "upsert"] /\ UNCHANGED resp
  /\ UNCHANGED <<nApplied, version, journal, pays, revOf, op, opHolder, bound>>

Finish(a, r) ==
  /\ resp' = [resp EXCEPT ![a] = r]
  /\ at' = [at EXCEPT ![a].pc = "done"]

Rollback(a, r) ==
  /\ op' = [op EXCEPT ![at[a].key] = "none"] /\ opHolder' = [opHolder EXCEPT ![at[a].key] = 0]
  /\ Finish(a, r)
  /\ UNCHANGED <<nApplied, version, journal, pays, revOf, bound>>

Apply(a) ==
  /\ nApplied' = [nApplied EXCEPT ![at[a].key] = @ + 1]
  /\ version' = version + 1 /\ journal' = journal \cup {version + 1}
  /\ op' = [op EXCEPT ![at[a].key] = "committed"] /\ opHolder' = [opHolder EXCEPT ![at[a].key] = 0]
  /\ Finish(a, "applied")

\* Kernel body, READ COMMITTED: readGroup + assertExpectedRevision is one
\* statement; prepare* reads and the CAS come later, so another commit can
\* land in between. Prepare reads see it (guard refuses, e.g.
\* ALREADY_REVERSED); if it lands after the reads, the CAS fails (conflict).
Check(a) ==
  /\ at[a].pc = "body"
  /\ IF at[a].exp # version THEN Rollback(a, "conflict")
     ELSE /\ at' = [at EXCEPT ![a].pc = "prepare"]
          /\ UNCHANGED <<nApplied, version, journal, pays, revOf, op, opHolder, bound, resp>>

\* prepare reads + guards + reserveRevision CAS + writes. Any commit after
\* the prepare reads also fails the CAS, so reads..CAS act as one step.
Prepare(a) ==
  LET k == at[a].key
      c == bound[k]
  IN
  /\ at[a].pc = "prepare"
  /\ IF c.k = "settle"
       THEN IF c.amt > Owed THEN Rollback(a, "refused")        \* INVALID_SETTLEMENT_AMOUNT
            ELSE IF at[a].exp # version THEN Rollback(a, "conflict") \* CAS failed
            ELSE /\ pays' = [x \in DOMAIN pays \cup {k} |-> IF x = k THEN [amt |-> c.amt, rev |-> FALSE] ELSE pays[x]]
                 /\ Apply(a) /\ UNCHANGED <<revOf, bound>>
       ELSE IF c.p \notin DOMAIN pays THEN Rollback(a, "refused")  \* SETTLEMENT_NOT_FOUND
            ELSE IF pays[c.p].rev THEN Rollback(a, "refused")        \* ALREADY_REVERSED
            ELSE IF at[a].exp # version THEN Rollback(a, "conflict") \* CAS failed
            ELSE /\ pays' = [pays EXCEPT ![c.p].rev = TRUE]
                 /\ revOf' = [revOf EXCEPT ![c.p] = @ \cup {k}]
                 /\ Apply(a) /\ UNCHANGED bound

\* The process dies inside the transaction: Postgres rolls it back.
CrashInTx(a) ==
  /\ at[a].pc \in {"body", "prepare"}
  /\ op' = [op EXCEPT ![at[a].key] = "none"] /\ opHolder' = [opHolder EXCEPT ![at[a].key] = 0]
  /\ at' = [at EXCEPT ![a].pc = "done"] /\ resp' = [resp EXCEPT ![a] = "lost"]
  /\ UNCHANGED <<nApplied, version, journal, pays, revOf, bound>>

Next ==
  \E a \in Attempts :
    \/ \E k \in Keys, c \in Cmds, e \in 0..version : Send(a, k, c, e)
    \/ Upsert(a) \/ Unblock(a) \/ Check(a) \/ Prepare(a) \/ CrashInTx(a)

Spec == Init /\ [][Next]_vars

(* Safety *)
TypeOK == /\ op \in [Keys -> {"none", "open", "committed"}] /\ version \in Nat
MoneyConserved == Owed >= 0 /\ Owed <= Debt                 \* no overpay, no money from nowhere
AppliedAtMostOnce == \A k \in Keys : nApplied[k] <= 1 /\ (nApplied[k] = 1 <=> op[k] = "committed")
ReversedAtMostOnce == \A p \in Keys : Cardinality(revOf[p]) <= 1 /\ (revOf[p] # {} <=> (p \in DOMAIN pays /\ pays[p].rev))
VersionsJournaled == journal = 1..version                   \* one journal+outbox row per version, no gaps
\* A client is never told its own operation failed with a server error
\* when that operation is in fact committed (it would show "payment failed").
VersionMonotonic == [][version' >= version]_version

NoFalseServerError == \A a \in Attempts : resp[a] = "500" => op[at[a].key] # "committed"
=============================================================================
