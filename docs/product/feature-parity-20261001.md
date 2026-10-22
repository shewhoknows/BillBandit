# BillBandit feature parity audit — 1 October 2026

**Recommendation:** complete reliable everyday expense sharing first, then add travel and advanced Splitwise features. BillBandit has a useful server ledger and offline queue. It does not yet have full Splitwise or travel-app parity.

This is a source audit and product research report. It is a proposed work sequence, not approval to change ledger semantics, authentication, production settings or payment services.

## Scope and evidence

- Working repository: `shewhoknows/BillBandit`. The old fairshare repository was not used as a working checkout.
- Audited source: `codex/profile-currency-expense-review-20260930`, commit `dd0a9f3ac39cc0920c6b3b589110057b03e58bb8`.
- Live GitHub ref check on 1 October: the UI branch still points to that commit; `main` points to `8b1bb6c861d56139f50f7e08d24f5b136f0e3caa`.
- The active app is the nested `BillBandit/BillBandit.xcodeproj`. Root `BillBanditApp` is retained scaffold. Marketing HTML, Prisma fields and old screens are not proof of an available product flow.
- BillBandit findings come from current code and existing QA artifacts. Competitor findings come from their owned pages and developer listings. Competitor usability, exact performance and reliability were not tested hands-on.
- “Implemented” means a connected active UI/backend path exists; it does not imply that real Apple sign-in and physical two-account operation were retested today.
- “Partial” includes local-only, limited, backend-only and disconnected features. “Not established” in competitor columns means the selected sources did not establish support; it does not mean absent.
- No test suite or build was run for this research. No application behavior, production configuration, deployment or TestFlight build was changed.

## Current BillBandit baseline

The active code supports authenticated friends, shared group creation, four split modes, canonical group balances, debt simplification, recorded partial/full settlements, settlement reversal, account-scoped cache/queue, offline entry after verified sign-in, and change activity. The latest UI branch adds Profile currency controls and a direct read-only shared expense overview.

Historical local proof remains useful: the release candidate had 33 backend checks, 10 real HTTP scenarios, 23 selected iOS unit cases and 6 UI scenarios; the UI branch added two focused passing UI cases. Those are prior artifacts, not new results from this audit. Physical two-account verification remains a separate release gate.

## Code findings that change the priorities

### Whole-unit rounding blocks normal money precision

The active editor accepts decimal INR/USD text but rounds the amount and split inputs to whole currency units before saving. The same path can round an existing fractional canonical expense on edit. This is deliberate existing behavior, also locked by a half-rupee unit test; it is a parity gap and a preservation risk for decimal records. VND must stay at exponent 0. Future changes must preserve historic recorded amounts and never relabel or convert them silently.

Evidence: [AddExpenseSheet.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/AddExpenseSheet.swift:853), [SplitEngine.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/Engine/SplitEngine.swift:26), [SplitEngineTests.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBanditTests/SplitEngineTests.swift:98).

### Currency menus and server support disagree

New groups offer INR and VND. The client currency enum has nine codes; the server registry has fourteen. AED and SGD appear in the display enum but are not accepted transaction currencies in the server registry. Several server currencies are absent from the display conversion enum. Display-only preferences and transaction capability must be explicit and consistent.

Evidence: [AddGroupSheet.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/AddGroupSheet.swift:62), [Money.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/Engine/Money.swift:3), [registry.ts](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/lib/settlement/money/registry.ts:1).

### Expense participation needs a real selector

The active composer includes every group member. Equal/percentage/share entry does not provide a clear way to exclude someone who did not share a meal or excursion. Exact zero allocations can be a workaround, not feature parity. Add a participant selector before advanced splitting.

Evidence: [AddExpenseSheet.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/AddExpenseSheet.swift:141), [AddExpenseSheet.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/AddExpenseSheet.swift:409).

### Stored metadata is not available metadata

Category, notes, receipt URL and recurrence fields exist in persistence/write validation. The canonical read projection omits them, and the mobile adapter hardcodes a generic category. The active composer has no date picker or notes field. Existing expense date is preserved on canonical edit; there is no complete metadata edit flow.

Evidence: [loader.ts](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/lib/ledger/read-model/loader.ts:57), [mobile-groups.ts](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/lib/mobile-groups.ts:52), [AddExpenseSheet.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/AddExpenseSheet.swift:195), [AddExpenseSheet.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/AddExpenseSheet.swift:899).

### Shared expense actions are incomplete in the app

Shared expenses can be edited through a group row. The server supports soft deletion with payer permissions, but the active app has no shared delete action. Local receipts have Edit/Delete. Shared receipts are read-only. Server history is an event log, not complete field-by-field expense versions; restore/reopen commands are missing.

Evidence: [GroupDetailScreen.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/GroupDetailScreen.swift:401), [GroupDetailScreen.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/GroupDetailScreen.swift:1736), [kernel.ts](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/lib/ledger/mutation/kernel.ts:1231).

### A bell and an outbox are not push notifications

The bell opens unread activity. Legacy reminders are retired. Pusher events invalidate foreground state; there is no device registration, APNs delivery or reminder scheduler in this project. A Comment table and recurrence flags also have no active delivery/read/write workflows.

Evidence: [AppStore.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/Store/AppStore.swift:5), [PlaceholderScreens.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/Shell/PlaceholderScreens.swift:706), [dispatcher.ts](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/lib/settlement/outbox/dispatcher.ts:17), [schema.prisma](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/prisma/schema.prisma:614).

### Recorded settlement is not bank transfer

Partial/full settlement and reversal are ledger facts. There is no payment provider, callback, webhook or verified money-received state. A UPI profile field does not implement UPI payment. Keep a request, an external payment attempt, and a recorded/verified settlement separate.

Evidence: [schema.prisma](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/apps/api/prisma/schema.prisma:252), [SharedSettleUpScreen.swift](/Users/prateekranka/Cowork/BillBandit-expense-review-20260930/BillBandit/BillBandit/UI/SharedSettleUpScreen.swift:408).

## Competitor scope

- Splitwise defines the broad baseline: groups and direct friend expenses, multiple payers, activity/comments/history, recurring bills and exports. Its Pro scope includes search, default splits, scanning/itemization, charts and conversion. Sources: [core features](https://www.splitwise.com/), [Pro](https://www.splitwise.com/pro), [developer iOS listing](https://apps.apple.com/us/app/splitwise/id458023433).
- Tricount is the travel benchmark: mixed-currency expenses, offline entry, custom shares, receipt photos, payment requests and Splitwise import. It advertises no ads or daily expense cap. Sources: [features](https://www.tricount.com/features), [currencies](https://www.tricount.com/features/multi-currency-support), [offline entry](https://www.tricount.com/features/offline-expense-tracking).
- Settle Up adds useful parity targets: several payers, default weights, browser sharing, notifications/reminders and CSV. Its iOS listing puts receipt photos, recurrence, categories, Excel and charts in Premium. Sources: [iOS listing](https://apps.apple.com/us/app/settle-up-group-expenses/id737534985), [Android listing](https://play.google.com/store/apps/details?id=cz.destil.settleup). Platform packaging differs; do not treat CSV and Excel as the same tier.
- Splid is the simple-trip benchmark: offline groups, optional sync without signup, multiple contributions, currency conversion, concise settlement and PDF summaries. Excel is an in-app purchase. Sources: [site](https://splid.app/english), [iOS listing](https://apps.apple.com/us/app/splid-split-group-bills/id991473495).

These are direct comparisons for shared expenses. Bank products, cards and travel services are adjacent features. They are not required to make BillBandit's ledger useful.

## Feature matrix

The CSV contains full code evidence, source links and an acceptance condition for all 34 rows. “Core” and “Pro/Premium” describe the named product's documentation, not a recommended BillBandit paywall.

| Capability | BillBandit now | Splitwise | Tricount | Settle Up | Splid | Phase |
|---|---|---|---|---|---|---|
| Shared groups and friends | Implemented; Apple-account flow | Core | Documented | Documented | Documented | 0 |
| Equal, exact, percentage and shares | Implemented; whole-unit policy | Core | Custom shares documented | Unequal/weights documented | Unequal documented | 0 |
| Choose expense participants | Missing explicit selection; all group members included | Core | Documented | Not established | Not established | 1 |
| Decimal and zero-decimal accuracy | Partial; non-VND editor rounds whole units | Decimal expense amounts | Not separately audited | Not separately audited | Not separately audited | 0 |
| Supported currency consistency | Partial: new groups INR/VND; enum 9; registry 14 | 100+ advertised | Multiple currencies | All currencies advertised | 150+ advertised | 0 |
| Offline expense entry and sync | Implemented with verified cached account; initial group creation needs server | Core | Documented | Documented | Offline groups and optional sync | 0 |
| Partial/full settlements and reversal | Implemented ledger recording; reversal is whole payment | Payment recording | Transfers/repayments | Documented settlement plan | Documented settlement plan | 0 |
| Simplify debts | Implemented; settings endpoint present | Core | Repayment suggestions | Documented | Documented | 1 |
| Expense date and notes | Partial: date preserved/read; no active date/notes inputs; notes absent from canonical read | Core metadata | Not separately audited | Not separately audited | Not separately audited | 1 |
| Categories and category reporting | Partial: create picker; canonical read loses category | Core categories; Pro charts | Insights advertised | Premium custom categories/charts | Group total documented | 1 |
| Shared edit/delete and recovery | Partial: group-row edit; shared delete endpoint has no app action; no restore command | Edit; restore advertised | Not separately audited | Not separately audited | Not separately audited | 1 |
| Expense history | Partial: actor/action/time and event amounts; no field-level old/new versions | Edit history | Not separately audited | Change history documented | Not established | 1 |
| Search and transaction filters | Missing app search; API has groupId/limit only | Pro full-history search | Not established | Filters documented | Not established | 1 |
| CSV/PDF/Excel export and backup | Missing user export; CloudKit migration is not export | CSV; Pro JSON backup | Not established | CSV; premium Excel on iOS | PDF; paid Excel | 1 |
| Default splits and duplicate expense | Missing; manual split entry each time | Pro defaults | Not established | Default weights documented | Not established | 2 |
| Several currencies in one group | Missing active writes; base estimates only | Separate currency balances; Pro conversion | Documented conversion | Documented conversion | Documented conversion | 2 |
| Several people pay one expense | Missing; one payer per record | Core advertised | Not established | Documented | Documented example | 2 |
| Non-group expenses and IOUs | Missing shared direct expense; friend balances aggregate shared groups | Core | Not applicable to group-first flow | Not established | Not established | 2 |
| Guest participants and browser sharing | Partial backend invitation foundation; no server guest UI/browser client | Account-based sharing | Link sharing | Browser balance view | No signup; sync groups | 2 |
| Refunds/reimbursements/income | Missing user workflow; settlement reversal is not expense refund | Web reimbursement split | Income/transfers documented | Income documented | Not established | 2 |
| Receipt photo/PDF attachments | Missing; receiptUrl storage only | Pro receipt storage | Photo attachment | Premium receipts/PDF preview | Not established | 3 |
| Itemized bills with tax/tip/discount | Missing | Itemized; mobile Pro scan | Not established | Items documented on Android listing | Not established | 3 |
| Receipt OCR | Missing; no scanner or parsing workflow | Pro | Not established; photo support is not OCR | Not established; photo support is not OCR | Not established | 3 |
| Comments and discussion on expense | Schema only; no API or UI | Core advertised | Not established | Not established | Not established | 3 |
| Push notifications and reminders | Missing; bell is activity; Pusher is foreground invalidation; reminders retired | Push/activity advertised | Not established in selected source | Notifications/reminders documented | Not established | 3 |
| Recurring expenses | Stored flags only; no generation worker/UI | Core | Not established | Premium recurring/future | Not established | 3 |
| Spending insights and trends | Missing; totals and balances exist | Pro charts | Spending insights advertised | Premium iOS statistics | Total group spend | 3 |
| Splitwise import | Missing; existing import is CloudKit recovery | Source/API/export available | Importer documented | Not established in reviewed owned source | Not established | 3 |
| Payment request/share/deep link | Missing active app; UPI profile field only | Regional integrations | Requests with regional availability | Not established | Not established | 4 |
| Bank/card import and automatic tracking | Missing | Pro US transaction import | bunq Card tracking | Not established | Not established | 4 |
| Android and full web client | Missing; API-only server; iPhone client | Android/web | Browser link flow; mobile apps | Cross-platform | iPhone/iOS audited here | 4 |
| Localization and native iPad | Missing localizations; iPhone compatibility only | Multiple languages/iPad | Not audited here | iPad and languages | Five languages; iPhone listing | 4 |
| Archive/reopen/restore controls | Partial: shared archive only when settled; no reopen/restore | Restoration advertised | Not established | Not established | Not established | 3 |
| Unlimited daily expense entry | No product daily cap found in source | Pro unlimited advertised | No daily cap advertised | Not established from selected owned description | Not established from selected owned description | 0 |

Competitor support in the matrix is documented support only. The source URLs for each row are in the adjacent CSV. Features not established were left unknown rather than marked missing.

## Recommended delivery order

### Phase 0 — accuracy and compatibility

Treat this as a release gate before broader parity claims.

- Preserve exact currency precision on new entry and unrelated edits. Retain VND's zero decimals and all historic recorded amounts.
- Align supported transaction currencies, display currencies, exponents and selectors. Additive capability data should come from one maintained currency registry.
- Keep account isolation, expected revisions, durable operation IDs, queued entry and cached reads intact.
- Repeat meaningful synthetic two-account tests for decimal create/edit, three-person rounding, offline restart, reconnect, stale edit and same-account reauthentication. Then verify real Apple/invite/device behavior separately.

The current whole-unit policy is documented and tested. Changing it requires an explicit new behavior contract and migration decision; do not rewrite past records to make them match new math.

### Phase 1 — complete everyday expense sharing

This is the recommended first feature release.

- Select participants per expense. Show individual allocations before saving.
- Finish date, notes and category inputs, canonical metadata readback and receipt actions. Preserve original expense date separately from added time.
- Expose authorized shared delete, and keep stale-write/settlement effects explicit.
- Add text search and filters for date, payer/participant, group, category and currency, with stable pagination and cached offline search.
- Add CSV export plus a compact shareable trip summary. Show total group spend, each person's consumed share and outstanding debt as separate values.
- Expose existing debt-planning settings where permissions allow.

Acceptance: a three-person trip can exclude one diner, retain cents/date/notes across edit and reconnect, find an old receipt, delete an allowed expense safely, and export a report matching the canonical ledger. No feature is complete until both accounts see the same result.

### Phase 2 — travel and relationship ledger parity

These features alter model or identity boundaries. Keep them separate from Phase 1 UI work.

- Allow original INR and VND expenses in one group, then other supported currencies.
- Retain each original amount/currency. Keep live cached INR estimates for display. When actual settlement converts currency, store the explicitly agreed rate, source/time and resulting amount. Do not make debts change when an estimate refreshes.
- Add payer contributions so several people can fund one receipt. Require total contributions and total shares to equal the expense total.
- Add direct friend expenses/IOUs, saved split presets, duplicate-entry action and explicit refund/reimbursement semantics.
- Add guest participants and invitation claim that preserves existing participant debts. Start browser access as scoped, revocable read-only sharing. Guest convenience must not weaken the authenticated ledger.

Acceptance: an INR booking and VND dinner retain original values; two people paying for one meal produce the same balance as the equivalent exact records; claiming a guest does not create or lose debt; a partial refund is an explicit linked event.

### Phase 3 — capture, collaboration and household parity

- Add protected receipt photos/PDFs and durable offline upload before OCR.
- Add manual itemization, tax/tip/discount allocations and user review. Add receipt OCR afterward as an editable draft, never as an automatic financial write.
- Add comments and real device notifications with opt-out, correct account/group scope and deduplication. Add reminders that point to a current balance.
- Add recurring bills with a server scheduler. The server must generate one occurrence when every phone is closed; define timezone, month end, cancellation and which edits affect future occurrences.
- Add per-member/category/date spending reports and Splitwise import with preview, duplicate prevention and reconciliation.
- Add complete version history and authorized restore/reopen controls without discarding previous payments.

Acceptance: closed-phone recurrence creates one bill; receipts/comments appear on both accounts; duplicate delivery does not duplicate alerts or expenses; scanned allocations reconcile after correction; imports can be repeated safely.

### Phase 4 — wider reach and payment integrations

- Add a full web client and Android when the canonical API supports the same complete flows. Expand authentication deliberately; do not add a second financial authority.
- Add localization and native larger-screen layouts; verify screen reader and text-size behavior.
- Add shareable payment requests and payment-app links first. Treat any bank/provider integration as a separate project with explicit confirmation/reversal states.
- Add bank/card transaction import only after partner availability and duplicate-provider handling are established.

Regional services are not universal parity requirements. Splitwise's Pro card import is currently US-only, and Tricount's request-link help lists specific European countries. Do not promise those services for India/Vietnam without provider support. Sources: [Splitwise Pro](https://www.splitwise.com/pro), [Tricount regional request links](https://help.tricount.com/en/articles/tricount-request-links).

## Product and architecture recommendation

Aim for exact, quick expense entry; readable receipts; reliable offline operation; clear settlement; easy exports; and easy group participation. Keep those core workflows available without an artificial daily expense limit. That is a proposed product policy, not a claim about operating cost or future pricing.

Use the existing ledger kernel, version checks, idempotency, Prisma/PostgreSQL and account cache/queue. Extend one canonical read/write contract; do not rebuild calculations in separate UI models. Backend fields for metadata are a useful starting point, but recurrence needs a real scheduler, receipts need protected storage, and push needs a delivery workflow. Do not infer those systems from existing fields.

Preserve the earlier requirement: original INR data and VND entry must never be silently relabeled or converted. Splitwise's own conversion help says conversion can change past, already-settled expenses. BillBandit should offer the useful outcome while preserving original records and explicit settlement decisions. Sources: [Splitwise currency behavior](https://kb.splitwise.com/balances-and-expenses/how-can-i-manage-a-friendship-or-group-with-multiple-currencies), [Tricount currency workflow](https://www.tricount.com/features/multi-currency-support).

No calendar estimate is supplied. Phase 1 mainly adds complete product flows; Phases 2–4 include ledger/identity changes and new services. Each phase needs a reviewed implementation plan and focused end-to-end proof before release.

## Verification boundary

Confirmed today: local and remote code revision, active target, source paths, connected APIs, missing routes, current metadata/precision behavior, documented competitor capabilities, and clean source checkout before this report. Historical QA results are referenced separately.

Not run today: simulator/build/test suite, physical phones, real Apple sign-in, live invite acceptance, cross-device balances, any competitor account sessions, payment-provider flows or production mutations. No implementation changed, so repeating expensive tests would not improve this source/research proof.

Artifacts: `feature-parity-20261001.csv` has the complete prioritized work list; the durable evidence folder holds the backend audit, source ledger and report copy. The current UI branch was already pushed separately; this research did not push, deploy or upload a build.
