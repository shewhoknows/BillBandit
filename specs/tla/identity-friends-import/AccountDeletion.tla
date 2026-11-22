---------------------------- MODULE AccountDeletion ----------------------------
(***************************************************************************)
(* Account deletion (lib/account-deletion.ts) racing a friend claim        *)
(* (lib/friends.ts claimFriendInvitation) for the same account, plus the   *)
(* effect of deletion on another member's balance.                         *)
(*                                                                         *)
(* World: Alice and Bob share a group. Alice paid 100.00, split 50/50.     *)
(* Bob paid Alice 50.00 and then reversed that payment, so Bob owes 50.00. *)
(* Carol claims Alice's friend code while Alice deletes her account.       *)
(* Two deletion requests (two of Alice's phones) can run at once.          *)
(*                                                                         *)
(* FIX = FALSE models the code as it was:                                  *)
(*   - deletion deleted SettlementReversal / allocation rows;              *)
(*   - deletion read the user row without a lock;                          *)
(*   - the claim checked deletedAt, then wrote the friendship, no lock.    *)
(* FIX = TRUE models the fix:                                              *)
(*   - deletion keeps reversal / allocation rows;                          *)
(*   - deletion takes FOR UPDATE on the user row first;                    *)
(*   - the claim takes FOR SHARE on both user rows before checking.        *)
(* READ COMMITTED: every statement sees the latest committed data.         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS FIX, Deleters

VARIABLES
  deleted,        \* Alice.deletedAt is set (committed)
  reversal,       \* the SettlementReversal row for Bob's payment exists
  friendship,     \* Carol-Alice Friendship row exists (committed)
  invitation,     \* Alice's FriendInvitation row exists
  dpc,            \* deletion request pc, per deleter
  cpc,            \* Carol's claim pc
  cSawDeleted,    \* what the claim read for Alice.deletedAt
  xlock,          \* deleter holding FOR UPDATE on Alice's row, or "none"
  slock,          \* claim holds FOR SHARE on Alice's row
  deletions       \* number of deletion transactions that committed "deleted"

vars == <<deleted, reversal, friendship, invitation, dpc, cpc, cSawDeleted, xlock, slock, deletions>>

\* Bob's debt to Alice in minor units, derived like the read model:
\* 100.00 split 50/50 -> Bob owes 50.00; an un-reversed 50.00 payment clears it.
BobOwes == IF reversal THEN 5000 ELSE 0

Init ==
  /\ deleted = FALSE
  /\ reversal = TRUE
  /\ friendship = FALSE
  /\ invitation = TRUE
  /\ dpc = [d \in Deleters |-> "start"]
  /\ cpc = "start"
  /\ cSawDeleted = FALSE
  /\ xlock = "none"
  /\ slock = FALSE
  /\ deletions = 0

(* ── Deletion: one Prisma interactive transaction ─────────────────────── *)
\* Old: findUnique (no lock). Fixed: SELECT ... FOR UPDATE, waits for share locks.
DelRead(d) ==
  /\ dpc[d] = "start"
  /\ IF FIX
       THEN /\ xlock = "none" /\ ~slock
            \* Already deleted: the transaction returns and releases the lock.
            /\ xlock' = IF deleted THEN "none" ELSE d
       ELSE UNCHANGED xlock
  /\ dpc' = [dpc EXCEPT ![d] = IF deleted THEN "done" ELSE "clean"]
  /\ UNCHANGED <<deleted, reversal, friendship, invitation, cpc, cSawDeleted, slock, deletions>>

\* The cleanup statements (each sees the latest committed rows).
DelClean(d) ==
  /\ dpc[d] = "clean"
  /\ reversal' = IF FIX THEN reversal ELSE FALSE   \* old: settlementReversal.deleteMany
  /\ friendship' = FALSE                           \* friendship.deleteMany
  /\ invitation' = FALSE                           \* friendInvitation.deleteMany
  /\ dpc' = [dpc EXCEPT ![d] = "commit"]
  /\ UNCHANGED <<deleted, cpc, cSawDeleted, xlock, slock, deletions>>

DelCommit(d) ==
  /\ dpc[d] = "commit"
  /\ deleted' = TRUE
  /\ deletions' = deletions + 1
  /\ xlock' = IF xlock = d THEN "none" ELSE xlock
  /\ dpc' = [dpc EXCEPT ![d] = "done"]
  /\ UNCHANGED <<reversal, friendship, invitation, cpc, cSawDeleted, slock>>

(* ── Carol claims Alice's code ────────────────────────────────────────── *)
\* Read the inviter (old: plain read; fixed: FOR SHARE, waits for FOR UPDATE).
ClaimRead ==
  /\ cpc = "start"
  /\ IF FIX THEN /\ xlock = "none" /\ slock' = TRUE ELSE UNCHANGED slock
  /\ cSawDeleted' = (deleted \/ ~invitation)
  /\ cpc' = "checked"
  /\ UNCHANGED <<deleted, reversal, friendship, invitation, dpc, xlock, deletions>>

ClaimWrite ==
  /\ cpc = "checked"
  /\ friendship' = IF cSawDeleted THEN friendship ELSE TRUE   \* upsert ACCEPTED
  /\ slock' = FALSE                                           \* commit
  /\ cpc' = "done"
  /\ UNCHANGED <<deleted, reversal, invitation, dpc, cSawDeleted, xlock, deletions>>

AllDone == cpc = "done" /\ \A d \in Deleters : dpc[d] = "done"

\* Finished: stutter, so a real lock deadlock is still reported as one.
Finished == AllDone /\ UNCHANGED vars

Next ==
  \/ \E d \in Deleters : DelRead(d) \/ DelClean(d) \/ DelCommit(d)
  \/ ClaimRead \/ ClaimWrite
  \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(* ── Properties ───────────────────────────────────────────────────────── *)
TypeOK ==
  /\ deleted \in BOOLEAN /\ reversal \in BOOLEAN /\ friendship \in BOOLEAN
  /\ dpc \in [Deleters -> {"start", "clean", "commit", "done"}]
  /\ cpc \in {"start", "checked", "done"}

\* Money: deleting Alice must not change what Bob owes.
BalanceUnchanged == BobOwes = 5000

\* No live friendship with a deleted account once everything has finished.
NoFriendshipWithDeleted ==
  (deleted /\ cpc = "done" /\ \A d \in Deleters : dpc[d] = "done") => ~friendship

\* Deletion runs its cleanup once (the second phone sees "already deleted").
DeleteOnce == deletions <= 1

\* Account state machine: active -> deleted only.
AccountMonotonic == [][deleted => deleted']_vars

Terminates == <>AllDone
=============================================================================
