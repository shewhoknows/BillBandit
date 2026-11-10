# Any group member can delete a shared expense — 10 November 2026

Branch: `fix/launch-blockers`. Do not push, do not deploy, do not touch production.

Owner decision (10 Nov 2026): **any active group member may delete a shared expense**, the same as edit. The deletion must be recorded so every other member of the group can see who deleted what.

This is the one approved exception to "no server validation changes" in `docs/plans/launch-blockers-20261110.md`. Nothing else on the server changes: no ledger math, no auth, no Prisma schema.

## What exists today (checked in code)

- `apps/api/lib/ledger/mutation/kernel.ts` `prepareExpense`, delete branch (~line 553): refuses with 403 "Only the payer can delete an expense" when `existing.paidById !== request.actorUserId`.
- `prepareMutation` already calls `ensureActiveMember` for `expense.delete`, so non-members and removed members are refused.
- The same branch already returns an `activity` (`EXPENSE_DELETED`, description, expenseId, paidByAccountId, amount). `recordMutationActivity` writes it in the same transaction with `userId: request.actorUserId` and `groupId`. The read model (`apps/api/lib/ledger/read-model/loader.ts` ~line 591) loads activity by `groupId`, so it is group-wide.
- iOS (round 4, commit `1e18677`) hides Delete for non-payers and shows "Only <payer> can delete this expense."

## Ways this could fail (write the fix for each, or say why it cannot happen)

1. A removed or departed member, or a non-member, deletes an expense. Must stay refused (403).
2. Delete in an archived or finalized group. Must stay refused.
3. Two members delete the same expense at once. Exactly one succeeds; the other gets the existing "already deleted"/conflict answer and the app shows a calm message; one activity row, not two.
4. A member deletes while another member is editing the same expense. The edit must fail cleanly with a clear message; no resurrected expense, no orphan splits.
5. The activity row is missing, or attributed to the payer instead of the person who deleted. Actor must be the deleter; payer is shown separately.
6. Other members do not see the deletion until they restart the app. Their Activity, group receipt and balances must update on the normal sync path (sync token / realtime), without a relaunch.
7. The activity line for other members is vague ("Deleted expense") or shows "You" for someone else's action. It must name the actor from the viewer's point of view.
8. Tapping the deletion in Activity crashes or opens a blank or wrong screen because the expense is gone.
9. Balances after the delete differ between the deleter and the other members.
10. A member deletes an expense whose debts were already partly or fully settled by recorded payments. Decide and state the behaviour (see item 4 of Work); the result must be consistent and visible, never silent.
11. An offline queued delete by a non-payer is sent later, after the payer already deleted or edited it. Must end as a clear failed/obsolete operation, never retried forever (round 4 made 4xx terminal; keep that).
12. Old app builds (build 32 on TestFlight) that still assume payer-only. They only hide nothing and send DELETE as before; confirm nothing in the response shape changes.

## Work

### 1. Server: allow any active member
- In the delete branch of `prepareExpense`, remove the payer-only check. Keep NOT_FOUND, already-deleted, `ensureActiveMember`, archived and `assertNotFinalized` checks exactly as they are.
- Do not change the response shape.

### 2. Server: make the activity record complete
- Keep the atomic write. Make sure the `EXPENSE_DELETED` metadata carries everything a client needs to render the line without the expense: `expenseId`, `description`, `amount` (minor units, currency, exponent), `paidByAccountId`, the expense `date`, and the actor (already `userId`). Add `deletedByAccountId` to metadata if the client read model does not already expose the actor for activity rows.
- Confirm the canonical read model's change history for the expense also records the deletion with the actor.
- If any of this needs a Prisma schema change, stop and write why under "Open questions". (It should not: metadata is JSON.)

### 3. iOS: Delete for every member
- Remove the payer-only gating from round 4 on `SharedExpenseOverviewScreen` and the edit sheet: every active member sees the Delete control. Remove the "Only <payer> can delete" line and the now-unused copy mapping, unless the server can still send it (it cannot after item 1; delete dead code).
- The confirmation sheet, when the signed-in member is not the payer, adds one plain line: "<payer> paid for this. Everyone in the group will see that you deleted it."

### 4. iOS: Activity that other members can trust
- Activity tab and Home recent activity, for a deletion: "<actor> deleted “<title>” · <amount> · paid by <payer> · <group>". Use "You" only when the viewer is the actor or the payer respectively. Same care for added and edited lines if they have the same "You" bug; check and fix.
- The group detail must show the deletion too, where the group already shows history (or add a short "recent changes" entry if there is no such place; keep it within the receipt style).
- Tapping a deletion opens a read-only overview of the deleted expense (title, amount, payer, date, split, note if available, change history ending with "deleted by <actor> on <date>"), clearly stamped as deleted, with no Edit or Delete. If the read model does not keep deleted expenses, render the overview from the activity metadata.
- Settled debts (failure 10): deleting an expense never touches recorded payments. After the delete the balances are recomputed from the remaining expenses and all payments, which can leave someone owed money back. That is correct and must be shown: the confirmation sheet warns when the group has recorded payments ("Payments already recorded stay. Balances will be recalculated."), reusing the existing `showsSettlementWarning` path.

### 5. Second member in the simulator
- `npm run dev:data -- signin` only signs in as "You". Add an option to `apps/api/scripts/dev-data.ts` to print/launch a sign-in for another dev member (for example `signin --as dev_kabir`), local only, same guard rails as the existing command. No production effect.

## Verification (E2E only; no unit tests)

Environment: local server on http://127.0.0.1:3000, iPhone 18 Pro simulator `7AEFF457-CBA5-4485-A13D-896E75169E07`, driven with `npx agent-device`.

A. Server scenario script (extend `apps/api/scripts/polish-e2e.ts` or add a sibling scenario in the same style, run against the local server), covering with real HTTP calls and two real member tokens: non-payer delete succeeds; activity row exists, actor = deleter, payer preserved; both members' read models agree on balances; removed member refused; non-member refused; double delete yields one success and one clean refusal and one activity row; edit-after-delete refused; delete in a group with a recorded payment leaves the payment and recomputes balances; archived group refused. Print a pass/fail table.

B. App, two members, same group:
  1. As "You", create a group expense paid by You.
  2. Sign in as a second member (item 5). Open the expense from the group receipt, delete it. See the extra confirmation line. Land on the group with it gone.
  3. Still as the second member: Activity shows "You deleted … paid by <You's name>".
  4. Sign back in as "You": without reinstalling, Activity shows "<second member> deleted “…” · amount · paid by You"; the group receipt no longer lists it; balances match what the second member saw. Tap the activity row: read-only deleted overview with history.
  5. Repeat step 2 for an expense in a group with a recorded payment; check the warning and the recomputed balances on both sides.

C. `npm run typecheck`, `npm run lint`, iOS Debug build with no new warnings.

Artifact: `.scratch/launch-blockers/evidence/any-member-delete/` with the revision, environment, exact replay commands, the scenario output, screenshots for B1–B5, and the server log lines for each DELETE. Do not claim a step passed unless it was exercised.

## Commits

One commit per Work item, plain messages, each ending with `Co-Authored-By: Claude <noreply@anthropic.com>`. Then update the 2026-11-10 section of `HANDOFF.md` and fill in the sections below.

## Open questions

- The mobile DELETE route returns 404 for both a non-member and a departed member because it cannot find the expense in their account read model. Both were refused; the plan explicitly requires 403. Changing the route or authorization behavior needs owner direction because only the payer rule change was approved.
- A switched simulator account initially showed onboarding and an empty ledger for You. A second launch restored the ledger. Live propagation to another already-running app was not proved.
- A simultaneous edit/delete race, finalized-group refusal, queued offline deletion, and TestFlight build 32 compatibility were not exercised. The delete response code was not changed by this work.
- The deleted overview was checked with equal splits and no note. Other split methods and notes remain unverified.

## Report

| Work | Status | Commit | Verification and limits |
| --- | --- | --- | --- |
| 1 | Partly verified | `2ebfbd9` | Non-payer deletion succeeded over HTTP and in the simulator. Non-member and departed member requests were refused with 404, not the specified 403. Archived-group refusal passed. Finalized group was not exercised. |
| 2 | Verified for sampled deletion | `e766d75` | The HTTP scenario read the atomic activity metadata and verified date, exact amount, payer, deleter, and canonical activity actor. Deleted expense and history remain in the canonical read model. No schema change. |
| 3 | Partly verified | `5f3a189` | Kabir saw Delete, the payer line and payment warning, then deleted two expenses. The edit-sheet entry point and offline failure were not exercised. |
| 4 | Partly verified | `e65925e` plus final verification commit | Both viewer perspectives, deleted overview and history, receipt changes, and payment balances were seen. A follow-up removes Activity text truncation. Already-running other-member sync, note, and other split methods were not exercised. |
| 5 | Partly verified | `267068a` | `signin --as dev_kabir` supplied a local simulator session. Switching back to You required completing onboarding and one extra launch before the ledger appeared. |

Verification A: six checks passed and two failed the specified status code: non-member and departed member received 404, not 403. They could not delete. The local scenario uses real HTTP requests and two member tokens. The full table and DELETE request logs are in `.scratch/launch-blockers/evidence/any-member-delete/`.

Verification B: You created a ₹100 expense; Kabir saw the payer warning, deleted it, and saw the group at ₹0 and the correct Activity actor and payer. After switching to You and an extra launch, Activity named Kabir and the deleted overview showed the title, amount, payer, date, split and history, without edit/delete. For a second ₹100 expense with a ₹20 payment, Kabir saw the payment warning, then was owed ₹20; You saw a ₹20 amount owed and the payment retained. No already-running second device was available to prove sync without relaunch. Screenshots and steps are in the evidence directory.

Verification C: `npm run typecheck` and `npm run lint` passed. The Debug build passed with the existing script-phase and App Intents warnings. No new warning was found. The final source-only accessibility identifiers and Activity wrapping were built; the Activity wrapping was viewed on the simulator.

## Independent check (Tester Army, after the work above)

- Revision under test: `0aefe37` plus the follow-up commit that carries this note. Environment: local API on 127.0.0.1:3000, iPhone 18 Pro simulator, signed in as "You".
- Replay: `npx e2e explore '<goal>'` with the goals recorded at the top of `.scratch/launch-blockers/testerarmy-round5/explore6.log` and `explore7-edit-sheet-delete.log`.
- Result: 14 of 14 flows passed (friend-paid delete, cancel, activity line, read-only deleted view, another member's deletion, edit-sheet delete, note, totals, persistence). Two defects found and fixed in the follow-up commit: a delete from the edit sheet left the old overview open; a long title was cut off in the delete confirmation. A second run passed both (2 of 2, no findings).
- Server scenario `apps/api/scripts/any-member-delete-e2e.ts`: 8 of 8 pass. Outsiders and removed members get 404 by design and the expense stays. Output: `.scratch/launch-blockers/evidence/any-member-delete/server-scenario-final.txt`.
- Not exercised: live update on a second device that is already open, an offline queued delete, TestFlight build 32 against the new server rule.
