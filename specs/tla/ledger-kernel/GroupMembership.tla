--------------------------- MODULE GroupMembership ---------------------------
(***************************************************************************)
(* Group membership and balances in one shared group.                     *)
(*                                                                         *)
(* People: o (owner, ADMIN) and a (MEMBER). GroupMember rows say who is in *)
(* the group now; GroupParticipant rows stay forever with status ACTIVE or *)
(* DEPARTED, so a departed person keeps their old expenses and payments.   *)
(*                                                                         *)
(* Each step is one committed ledger mutation. LedgerKernel.tla shows the  *)
(* kernel serializes mutations through the revision compare-and-set, and   *)
(* the leave route uses the revision of the read it checked the balance    *)
(* on, so every mutation here is atomic with respect to the others.        *)
(*                                                                         *)
(* Money (minor units): E1 paid by o, E2 paid by a, each 2 units. Content  *)
(* "shared" = 1 + 1, "solo" = the payer's own 2. S1 = a pays o 1,          *)
(* S2 = o pays a 1.                                                        *)
(*                                                                         *)
(* Fixes \subseteq {"balance", "admin", "departedSettle"}:                 *)
(*   balance : membership.remove needs the target's balance to be zero     *)
(*   admin   : membership.remove / membership.update may not remove or     *)
(*             demote the last administrator                               *)
(*   departedSettle: a departed person who owes or is owed money may       *)
(*             record or reverse a payment they are part of                *)
(*             (kernel ensureSettlementActor; access matrix)               *)
(*                                                                         *)
(* Product rule (Bobby, 2026-11-21): after a person leaves, old expenses   *)
(* that include them may still be edited or deleted, so a departed person  *)
(* can owe money again. That debt must stay settleable.                    *)
(***************************************************************************)
EXTENDS Integers

CONSTANT Fixes

People == {"o", "a"}
Exps   == {"E1", "E2"}
Pays   == {"S1", "S2"}
Payer(e)  == IF e = "E1" THEN "o" ELSE "a"
PFrom(s)  == IF s = "S1" THEN "a" ELSE "o"
PTo(s)    == IF s = "S1" THEN "o" ELSE "a"

VARIABLES member,   \* GroupMember: "admin" | "member" | "none"
          part,     \* GroupParticipant.status: "active" | "departed"
          exp,      \* Expense: "none" | "active" | "deleted"
          content,  \* split of each expense: "shared" | "solo"
          pay       \* Transaction: "none" | "active" | "reversed"

vars == <<member, part, exp, content, pay>>

Share(e, x) == IF content[e] = "solo"
                 THEN (IF x = Payer(e) THEN 2 ELSE 0)
                 ELSE 1
ExpPart(e, x) == IF exp[e] = "active"
                   THEN (IF x = Payer(e) THEN 2 ELSE 0) - Share(e, x)
                   ELSE 0
PayPart(s, x) == IF pay[s] = "active"
                   THEN (IF x = PFrom(s) THEN 1 ELSE 0) - (IF x = PTo(s) THEN 1 ELSE 0)
                   ELSE 0
\* Positive: the group owes x. Same formula as read-model buildBalances.
Bal(x) == ExpPart("E1", x) + ExpPart("E2", x) + PayPart("S1", x) + PayPart("S2", x)

IsMember(x) == member[x] # "none"
Admins == {x \in People : member[x] = "admin"}

Init ==
  /\ member = [x \in People |-> IF x = "o" THEN "admin" ELSE "member"]
  /\ part = [x \in People |-> "active"]
  /\ exp = [e \in Exps |-> IF e = "E1" THEN "active" ELSE "none"]
  /\ content = [e \in Exps |-> "shared"]
  /\ pay = [s \in Pays |-> "none"]

\* Who may record or reverse a payment (before the actor must also be one
\* of the two ends).
SettleActor(x) ==
  \/ IsMember(x)
  \/ ("departedSettle" \in Fixes /\ part[x] = "departed" /\ Bal(x) # 0)

-----------------------------------------------------------------------------
(* expense.create / expense.edit / expense.delete (any active member)      *)

Create(x, e) ==
  /\ IsMember(x) /\ exp[e] = "none"
  /\ IsMember("o") /\ IsMember("a")            \* every split user is a member
  /\ exp' = [exp EXCEPT ![e] = "active"]
  /\ content' = [content EXCEPT ![e] = "shared"]
  /\ UNCHANGED <<member, part, pay>>

Edit(x, e, c) ==
  /\ IsMember(x) /\ exp[e] = "active" /\ content[e] # c
  /\ IsMember(Payer(e))
  /\ c = "shared" => (IsMember("o") /\ IsMember("a"))
  /\ content' = [content EXCEPT ![e] = c]
  /\ UNCHANGED <<member, part, exp, pay>>

Delete(x, e) ==
  /\ IsMember(x) /\ exp[e] = "active"
  /\ exp' = [exp EXCEPT ![e] = "deleted"]
  /\ UNCHANGED <<member, part, content, pay>>

(* settlement.create: actor is SettleActor and one of the two ends;        *)
(* the plan must hold the transfer (payer owes recipient). The ends may be *)
(* departed participants.                                                  *)
Pay(x, s) ==
  /\ SettleActor(x) /\ x \in {PFrom(s), PTo(s)} /\ pay[s] = "none"
  /\ Bal(PFrom(s)) <= -1 /\ Bal(PTo(s)) >= 1
  /\ pay' = [pay EXCEPT ![s] = "active"]
  /\ UNCHANGED <<member, part, exp, content>>

Reverse(x, s) ==
  /\ SettleActor(x) /\ x \in {PFrom(s), PTo(s)} /\ pay[s] = "active"
  /\ pay' = [pay EXCEPT ![s] = "reversed"]
  /\ UNCHANGED <<member, part, exp, content>>

-----------------------------------------------------------------------------
(* membership                                                              *)

RemoveGuard(y) ==
  /\ "balance" \in Fixes => Bal(y) = 0
  /\ "admin" \in Fixes => ~(member[y] = "admin" /\ Admins = {y})

DoRemove(y) ==
  /\ member' = [member EXCEPT ![y] = "none"]
  /\ part' = [part EXCEPT ![y] = "departed"]
  /\ UNCHANGED <<exp, content, pay>>

\* POST /groups/:id/leave: not the owner, own balance zero.
LeaveRoute(x) ==
  /\ member[x] = "member" /\ Bal(x) = 0
  /\ RemoveGuard(x)
  /\ DoRemove(x)

\* DELETE /groups/:id/members with your own userId: the kernel lets any
\* member remove themself (leavingSelf), with no route checks.
RemoveSelf(x) ==
  /\ IsMember(x)
  /\ RemoveGuard(x)
  /\ DoRemove(x)

\* DELETE /groups/:id/members by an administrator for someone else.
AdminRemove(x, y) ==
  /\ member[x] = "admin" /\ y # x /\ IsMember(y)
  /\ RemoveGuard(y)
  /\ DoRemove(y)

\* POST /groups/:id/members: any member adds someone back; the departed
\* participant row becomes ACTIVE again.
ReAdd(x, y) ==
  /\ IsMember(x) /\ ~IsMember(y)
  /\ member' = [member EXCEPT ![y] = "member"]
  /\ part' = [part EXCEPT ![y] = "active"]
  /\ UNCHANGED <<exp, content, pay>>

\* PATCH /groups/:id/members (membership.update): an administrator sets a role.
SetRole(x, y, r) ==
  /\ member[x] = "admin" /\ IsMember(y) /\ member[y] # r
  /\ "admin" \in Fixes => ~(r = "member" /\ Admins = {y})
  /\ member' = [member EXCEPT ![y] = r]
  /\ UNCHANGED <<part, exp, content, pay>>

Next ==
  \E x \in People :
    \/ \E e \in Exps : Create(x, e) \/ Delete(x, e)
    \/ \E e \in Exps, c \in {"shared", "solo"} : Edit(x, e, c)
    \/ \E s \in Pays : Pay(x, s) \/ Reverse(x, s)
    \/ LeaveRoute(x) \/ RemoveSelf(x)
    \/ \E y \in People : AdminRemove(x, y) \/ ReAdd(x, y)
    \/ \E y \in People, r \in {"admin", "member"} : SetRole(x, y, r)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* Money is conserved: balances sum to zero (one currency here).
BalancesSumToZero == Bal("o") + Bal("a") = 0

\* GroupMember and GroupParticipant agree.
MemberRowsAgree == \A x \in People : IsMember(x) <=> part[x] = "active"

\* A person is settled up at the moment they leave or are removed.
LeaverSettled ==
  [][\A x \in People : (part[x] = "active" /\ part'[x] = "departed") => Bal(x)' = 0]_vars

\* A departed person who owes money can pay it themself, whenever the plan
\* holds that transfer (Pay's own money guard).
DepartedCanSettle ==
  \A x \in People, s \in Pays :
    (/\ part[x] = "departed" /\ x = PFrom(s) /\ pay[s] = "none"
     /\ Bal(PFrom(s)) <= -1 /\ Bal(PTo(s)) >= 1)
      => ENABLED Pay(x, s)

\* Bobby (2026-11-21): a departed person does not see the group, but when
\* they are added back, their debt (which may have changed while they were
\* away) is theirs again, unchanged by the re-add.
ReAddKeepsDebt ==
  [][\A y \in People : (part[y] = "departed" /\ part'[y] = "active") => Bal(y)' = Bal(y)]_vars

\* Old intent, no longer wanted (kept to show the new rule allows it):
\* a departed person's balance is always zero.
DepartedAreSettled == \A x \in People : part[x] = "departed" => Bal(x) = 0

\* The group always keeps an owner who can finalize, delete and add admins.
HasAdmin == Admins # {}
=============================================================================
