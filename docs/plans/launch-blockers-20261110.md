# Launch blockers plan — 10 November 2026

Branch: `fix/launch-blockers` (cut from `cleanup/2026-11-10-audit`). Do not push, do not deploy, do not touch production settings.

Source of findings: a Tester Army (`e2e explore`) run and a hands-on GPT 6.1 Terra run on the iPhone 18 Pro simulator against the local API, plus code review. The server already supports everything below; almost all work is in the iOS app under `BillBandit/BillBandit/`.

## Ground rules

- Read `AGENTS.md` and the top of `HANDOFF.md` first. No unit tests. Never use Flowdeck.
- Keep the visual language: cobalt + cream only, existing `BrandFont`, `BrandSectionLabel`, `BrandCheckmark`, `BrandModalHeader`, capsule controls. No system-blue, no black text, no stock `Form`/`List` chrome.
- The server is the only source of truth. Shared (server) groups are the product; the old local SwiftData-only expense path may stay as is, but nothing new is built on it.
- Do not change ledger math, server validation rules, auth, or the Prisma schema. If a server change seems necessary, stop and write down why in the "Open questions" section at the bottom of this file instead of making it.
- Money stays exact: minor units, the group's currency exponent, remainders handed out one minor unit at a time (`SplitEngine.compute(total:inputs:exponent:)`).
- Keep `project.pbxproj` hand-edited and minimal. Prefer adding code to existing files over new files; if a new Swift file is needed, add it to the target correctly.
- Every interactive control gets an `accessibilityIdentifier` and a correct accessibility label/value/selected trait.
- Build must pass with zero new warnings:
  `cd BillBandit && xcodebuild -project BillBandit.xcodeproj -scheme BillBandit -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /private/tmp/claude-501/bb-dd build`
- Server checks must still pass: `npm run typecheck && npm run lint`.
- Commit each numbered item separately with a plain message. End each commit message with `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Items

### 1. Friend rows do not select (bug, high)

`UI/AddGroupSheet.swift` ~line 93: the row is a `.plain` button whose label is `HStack { Text; Spacer; BrandCheckmark }`. The spacer area is not hit-testable, so a tap in the middle of the row does nothing. Same pattern in `GroupAddMembersSheet` (`UI/GroupDetailScreen.swift` ~line 1546).

- Make the whole row tappable (`.contentShape(Rectangle())` on the label, full-width frame).
- Expose state to accessibility: the row is one element, label = friend name, `.isSelected` trait when chosen, identifier `groupFriendRow-<name>` / `addMemberRow-<name>`.
- Audit every other `.buttonStyle(.plain)` row with a `Spacer()` in the app (payer picker, group picker, currency rows, profile rows, activity rows) and apply the same fix where the hit area has a hole.

Done when: tapping the centre of a friend row toggles it; a group created with one friend selected shows 2 members.

### 2. Prefilled full settlement amount is rejected (bug, high)

`UI/SharedSettleUpScreen.swift`: opening "Record payment" prefills `confirmationAmount` from `transfer.minorUnits` (~line 309), yet `settlementAmountMinorUnits(for:)` (~line 548) returns nil, so the red hint shows and Confirm stays disabled. Seen twice with ₹88.85 owed after an earlier part payment in the same group.

- Reproduce first (local server + `npm run dev:data`, record one part payment, reopen Record payment). Find the real cause; candidates: `SettlementMoneyFormatting.minorUnits(from:exponent:)` / `paddingMinorUnits` producing a non-canonical string (leading zeros, missing padding for "8.3"-style values), `compare` being a string compare, or a stale `transfer` after the snapshot refreshes.
- Fix the cause, not the symptom. The round trip minor units → field text → minor units must be the identity for every exponent (0, 2, 3) and for values such as 5, 50, 830, 8885, 100000.
- The field must always show the full exponent ("8.30", never "8.3").
- The amount text must be cobalt, not black.
- Show the red hint only when the entered text is actually invalid, and say which rule failed (zero/empty vs more than owed).

Done when: full prefilled amount confirms; a part amount confirms and reduces the debt; an over-amount is refused with a clear message.

### 3. Choose who is in an expense (feature)

`UI/AddExpenseSheet.swift`: `participants` is always every group member.

- Add a "SPLIT BETWEEN" section: one chip/row per member with a checkmark, all on by default, at least one must stay on. Editing an existing expense preselects the members that have a split.
- Only included members appear in the equal/exact/percent/shares inputs, in the summary line ("3 of 4 people · ₹41.15 each"), and in the `splits` array sent to the server. Excluded members send no split.
- The payer does not have to be included (Splitwise allows "paid by A, split between B and C").
- Fix the count copy everywhere it is derived ("split 4 ways" on the group receipt, expense overview, Activity detail): count only members whose share is greater than zero.
- Verify against the local server that an expense whose splits omit a member is accepted and balances are right. If the server rejects it, record that under "Open questions" and send explicit zero is NOT an acceptable fallback without sign-off.

### 4. Expense date (feature)

- Add a date control to add and edit: defaults to today, allows past dates, no future dates. Brand-styled trigger (capsule showing "Today" / "8 Nov 2026") opening a graphical `DatePicker` tinted cobalt in a brand sheet.
- Send it as `date` on create and on edit. Today the edit path resends `canonicalEditingExpense.originalDate`; keep that value unless the person changes the date.
- Show the expense date on the group receipt row and the expense overview, and sort the receipt by expense date (newest first), then by creation time.

### 5. Expense note (feature)

- Add an optional multi-line "NOTE" field (max 500 characters, matches server `notes`) to add and edit.
- Send `notes` on create and edit (today edit sends nil; make sure an unchanged note survives an edit and a cleared note is cleared).
- Show the note on the expense overview. Also make sure `category` survives an edit (today edit sends `category: nil`); show the category row when editing.

### 6. Delete a shared expense (feature)

Server: `DELETE /api/mobile/expenses/{id}` needs a JSON body with `operationId` and `expectedRevision` (see `apps/api/app/api/mobile/expenses/[id]/route.ts` and `mobileExpenseDeleteV2Schema`).

- Add "Delete expense" to `SharedExpenseOverviewScreen` and to the edit sheet for server expenses, using the existing `DeleteExpenseConfirmationSheet` look.
- Go through the same client path as create/edit (operation id, expected revision, pending-operation queue if that is how edits work offline; if delete cannot be queued safely, require a connection and say so).
- On success: dismiss back to the group, refresh the read model, Activity shows the deletion. On a stale revision or a server refusal, show the server's plain-language message and leave the expense in place.

### 7. Edit expense shows the wrong payer (bug, to confirm)

Tester Army reported the edit sheet highlighting a different payer than the group receipt for the same expense. Reproduce with an expense paid by a friend (dev:data creates these). If real, fix the payer preselection for canonical expenses (`CanonicalExpenseEditDraft`, `isYou`, `paidBy` initial state). If not reproducible, write what you tried under "Open questions".

### 8. Legibility pass (design)

- Raise contrast of small secondary text on cobalt and cream: Home balance sub-lines and member counts, Activity timestamps, Profile help text, inactive tab bar icons/labels. Target WCAG AA (4.5:1) for text under 18pt. Use opacity steps of the two brand colours only.
- Long group names in the Add expense group picker must not clip mid-word: scrollable chips with a trailing fade, or truncate with an ellipsis.

### 9. Mascot backstory (design + copy)

Canon: **"He used to steal. Now he settles."** A reformed bank-robber raccoon who over-corrects into exact bill-settling. Deadpan, polite, slightly over-prepared. Vocabulary already in the app: crew, partner in crime, clean slate, the bandit.

- Onboarding page 1: lead with the line. Proposed copy: headline "he used to steal. now he settles." / body "Meet the Bandit. Reformed, exact, and very serious about who owes what."
- Keep pages 2–3 but pull them into the same voice (e.g. "every rupee accounted for. old habits." / "clean slate. no getaway needed.").
- Use the story where the product already has a moment: empty Home ("no jobs yet. start a crew."), settle celebration ("clean slate. the bandit approves."), delete confirmation ("destroy the evidence?"), over-payment refusal ("he only takes what's owed now."), Profile level titles as a rap-sheet-to-clean-record arc.
- Copy only, existing poses only (`greeting, thinking, confused, celebrating, neutral, grumpy` + 4 scenes). Do not edit mascot art. Keep every line short, lowercase handwritten style where `BrandFont.handText` is used, and never joke about a person's actual debt in a way that shames them.
- List every string changed in the commit body so the owner can veto lines.

### 10. Unused capabilities (App Review hygiene)

- Report (do not remove yet) whether CloudKit/iCloud entitlements and `aps-environment` are still needed: `CloudCollaborationService` still creates a `CKContainer` at launch; there is no push registration. Write the finding and the safe removal steps under "Open questions". Removing entitlements changes provisioning, so it needs the owner's go-ahead.

## Verification (after all items)

1. Build passes, no new warnings. `npm run typecheck && npm run lint` pass.
2. `npm run dev:server`, `npm run dev:data`, `npm run dev:data -- signin --launch` on the iPhone 18 Pro simulator; walk each "Done when" by hand or with `npx agent-device` and note the result per item.
3. Update the 2026-11-10 section of `HANDOFF.md` with what changed, what was verified and how, and what is still open.
4. Write a short report at the bottom of this file: per item — done / partly / not done, commit hash, how verified, anything you were unsure about.

## Open questions

- Item 4: The canonical ledger maps the expense date to `createdAt`. It does not expose a separate creation time for every expense. Some older records also lack creation activity. A server read-model change appears necessary to guarantee the requested date-then-creation-time order. The item was stopped pending direction; no server change was made.
- Item 7: The payer mismatch could not be reproduced while another app was using the requested simulator. The canonical editor maps the payer by server account ID, but that source inspection does not prove the on-screen selection.
- Item 10: CloudKit is still used. `CloudCollaborationService` creates the named container at launch, syncs public profile cards, and imports legacy records. SwiftData uses `cloudKitDatabase: .none`. The app declares `aps-environment`, the Push capability, and the `remote-notification` background mode. No remote-notification registration or CloudKit subscription was found in the app source. `UNUserNotificationCenter` only removes old local reminders. The iCloud key-value entitlement has no matching `NSUbiquitousKeyValueStore` use in the source. These findings do not prove that removal is safe on upgraded devices.
- Safe removal requires the owner's approval. First establish that legacy import and CloudKit profile data are no longer needed, and replace or retire those paths. Then remove container initialization and CloudKit calls, remove the unused entitlements and capabilities, review the background mode, and update signing and provisioning. Build a signed candidate and verify fresh install, upgrade, sign-in, friends, profile sync, and legacy migration before release. Keep Sign in with Apple. No entitlement or provisioning change was made here.

## Report

(fill in at the end)
