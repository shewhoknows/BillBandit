# BillBandit — Agent Handoff

> **Living document.** Read this first when picking up the project.
> **Update it after every phase** (status, decisions, gotchas, next actions) — it is the
> shared memory for all agents working on this repo. Last updated: **2026-07-20, automatic connected-friend group sharing build 1.0 (8) signed, tested and published.**

---

## 1. What this is

**BillBandit** — an iOS expense-splitting app (Splitwise-style) with a hand-drawn
raccoon mascot, cobalt `#1F3FC3` + cream `#EFEFD7` palette, and an illustrated,
poster-like aesthetic ("Direction B — Cobalt Club").

| Thing | Location |
|---|---|
| iOS app + Xcode project | `BillBandit/` (project root of this folder) |
| Official mascot SVGs (source of truth) | `BillBandit-Raccoon-SVG/*.svg` (6 poses) |
| Contextual mascot scene SVGs | `BillBandit-Raccoon-Scene-Variations-SVG/*.svg` (4 scenes) |
| Throwaway mockup board | `mockups/index.html` (open in browser; `#shot1`–`#shot7` jump to a screen) |
| Product plan + approved roadmap | `mockups/PLAN.md` (§6b = the approved build decisions) |
| Design decision log | `mockups/NOTES.md` (Direction B, mascot asset lock) |

**Do not** port mockup code to the app — port decisions. Do not edit mascot PDFs/icons
directly; regenerate them from sources (see §5).

## 2. Locked decisions (don't relitigate)

- **Stack:** SwiftUI + SwiftData · iPhone portrait · **iOS 18+** · light-only v1.
- **Data:** SwiftData, local-first. **Balances are computed, never stored** — money
  math lives in a pure, unit-tested engine. CloudKit sync is a v2 option.
- **Mascot:** 6 official core poses — `greeting, thinking, confused, celebrating,
  neutral, grumpy` — plus 4 supplied contextual scenes (`bill-cross-legged`,
  `overdue-bell`, `searching-couch`, `sleepy-bed`). All use two flat colours
  (`#2942C9` ink / `#F7F1DD` cream) and stay **untouched**. On cobalt screens
  they read as cream silhouettes; that's intended.
- **Pose mapping:** onboarding → greeting · home/activity → confused · invoice/you-owe
  → grumpy · add expense → thinking · settle celebration → celebrating · friends →
  greeting · general/empty → neutral.
- **Group detail = a paper invoice** (dotted leaders, torn zigzag edge, `BILLBANDIT &
  CO.` header, `YOU OWE` stamp rotated −2.5°).
- **Type:** Fredoka display · Caveat handwritten accents · **Courier Prime for any
  money/ledger/activity text** · Nunito UI body.
- **Default currency:** Indian rupee (`₹`). The currency selector has been removed
  from Profile and the app currently forces INR. The underlying formatter still
  preserves future multi-currency scope, but no currency choice is exposed. Expense totals,
  splits, settlements and owed balances normalize to complete currency units
  (half-up total rounding + deterministic whole-unit remainder allocation).
- Form text auto-capitalizes its first letter (names use word capitalization).
- Group names carry **no emoji** (icons only).

## 3. Status — Phase 5 + pre-beta polish shipped ✅

Phases per approved roadmap (`mockups/PLAN.md` §6b). Each ends with a **gate**:
simulator build + screenshots → user sign-off before continuing.

- [x] **Phase 1 — Foundation & design system** ✅ 2026-07-18
  Xcode project, colour/font tokens, mascot PDFs, 19 template icons, tab shell +
  5 branded placeholders, app icon, screenshot tooling.
- [x] **Phase 2 — Data & split engine** ✅ 2026-07-18
  SwiftData models (Person, Group, Expense, Split, Settlement, ActivityItem);
  pure-Swift `SplitEngine` (equal/exact/%/shares, deterministic cent remainders)
  + `BalanceEngine` (nets, greedy simplify) + SwiftData adapters incl.
  **pairwise friend balances**; 17 XCTest cases green; CRUD UIs (Friends,
  Groups, GroupDetail w/ settle-up plan + record payment, AddExpenseSheet per
  B4 with all 4 split modes + validation); DEBUG seed matching mockup B2
  (owed ₹160.50 / owe ₹18.00 / net ₹142.50).
- [x] **Phase 3 — Money screens** ✅ 2026-07-18
  Live home totals, 2×2 group grid, activity card + confused raccoon; paper
  invoice with dotted leaders, torn edge, live stamp + perched mascot; expense
  split detail with edit/delete; settlement sheet and animated celebration with
  confetti/coins + success haptic; activity grouped by day in Courier Prime.
  Simulator build and 17 engine tests pass; home + Goa invoice were visually
  checked against B2/B3; user approved and advanced to Phase 4.
- [x] **Phase 4 — Onboarding & polish** ✅ 2026-07-18
  Three animated mascot slides + name entry; persistent first-run gate with
  screenshot bypass args; empty states for groups/friends/activity/invoices;
  tab, FAB, save and celebration haptics; micro-animations; rupee formatting
  centralized in `Money.currency`; form capitalization at keyboard + save time.
  Simulator build and all 19 tests passed; user approved and advanced to ship.
- [x] **Phase 5 — Ship** ✅ 2026-07-18
  Locked grumpy raccoon on cobalt as the v1 app icon; added a real
  `BillBanditUITests` target and shared-scheme smoke covering launch, ₹ balance,
  tab navigation, Goa invoice/stamp and Add Expense; 19 unit/default tests +
  1 XCUITest green; development-signed iPhone archive exported and uploaded.
  Original install: `https://build.sqim.dev/sqim/install/5t0c7pJOnEts`.
- [x] **Post-ship device feedback polish** ✅ 2026-07-18
  Enlarged the app-icon raccoon with a tighter face/arms crop; standardized and
  aligned group balance pills; made invoice expense rows share an exact leading
  edge; brought Add Expense into the cobalt/cream shell with outlined segmented
  Group and Paid By controls; and made the home overall caption resilient to
  clipping. Simulator screenshots were visually checked, all 19 unit/default
  tests + 1 XCUITest passed, and a refreshed signed build was published.
  Superseded install: `https://build.sqim.dev/sqim/install/NqQXN_QrEN9s`.
- [x] **Branded modal consistency pass** ✅ 2026-07-18
  Rebuilt Add Expense from the B4 index-board composition (thinking mascot hero,
  squiggle, receipt/camera line, category circles, outlined group/payer/split
  selectors and cobalt CTA). Replaced system-style Add Friend, New Group, Edit
  Expense and Record Payment screens with full-screen cobalt/cream compositions.
  These flows no longer use SwiftUI `Form`, `Section`, `Picker`, or `Toggle`.
  Settle Up now uses direct branded member chips and a large rupee ledger field;
  the existing B5 animated celebration remains the success state. All 19
  unit/default tests + 1 XCUITest passed and a signed device build was published.
  Superseded install: `https://build.sqim.dev/sqim/install/O4vkdZN1Sq9L`.
- [x] **Branded control polish** ✅ 2026-07-18
  Made all eight Add Expense category circles fully visible in one row with clean
  inset 2.5pt strokes matching the Group/Paid By/Split outlines. Compact person
  selectors now use `You`/first names so no partial trailing name is exposed.
  Protected the handwritten Record Payment heading from trailing-glyph clipping
  with single-line scaling, tightening, layout priority and extra trailing room.
  Simulator visuals checked, 19 unit/default tests + 1 XCUITest passed after the
  prescribed retry for one transient navigation timing miss, and a signed build
  was published. Superseded install: `https://build.sqim.dev/sqim/install/G0BDwHLbsQyU`.
- [x] **Live whole-rupee ledger & editing** ✅ 2026-07-18
  Explicitly updates and saves SwiftData group relationships before dismissing,
  so new/edited expenses appear on invoices immediately and newly created groups
  appear first on Home immediately. Home `see all` now switches to Groups. Group
  detail now has branded Add Expense and Record Payment tablets. Add Expense also
  serves as the complete editor (amount, title, category, group, payer and all four
  split modes) with no member-based permission restriction. Whole-rupee allocation
  rounds the total half-up and distributes remaining rupees deterministically;
  legacy decimal facts are normalized by the balance adapter. Split amounts use a
  fixed trailing column, friend chips use one fixed width, and Caveat headings have
  protected trailing glyph space. Validation: 20 unit/default tests + 2 XCUITests,
  including immediate add/edit invoice insertion, Home see-all, and immediate new
  group insertion. Superseded install: `https://build.sqim.dev/sqim/install/4u8Q-2sTgyL2`.
- [x] **Greeting-raccoon icon refresh** ✅ 2026-07-18
  Replaced the grumpy icon artwork with the official greeting pose. The crop is
  intentionally close to the supplied reference: both ears and the complete face
  remain visible, the raised hand and wave marks stay inside the icon, and the
  torso runs off the lower edge. Added a Core Graphics generator that renders the
  vector PDF directly to an opaque RGB 1024×1024 app-icon PNG. Xcode's asset
  catalog accepted the source without warnings; the 120×120 compiled rendition
  was visually checked and a signed device archive was published. Superseded install:
  `https://build.sqim.dev/sqim/install/yDPpahoqA5eb`.
- [x] **Legibility, input, invoice & profile polish** ✅ 2026-07-18
  Matched the icon background exactly to app cobalt `#1F3FC3` and tightened the
  greeting-raccoon crop around its face, ears and wave. Added grouping-aware money
  input parsing so `3,496` is ₹3,496 (while comma decimals remain supported), with
  direct parser coverage. Locked every invoice amount to one fixed trailing column,
  introduced a shared 1.15 typography scale across the design system and navigation,
  and connected the Home avatar to a branded editable Profile screen with rupee/INR
  defaults and live ledger stats. Clean validation: 21 unit/default tests + 2
  XCUITests, including Profile, Home see-all, and immediate add/edit invoice flows.
  Superseded install: `https://build.sqim.dev/sqim/install/fnQ-DF8gRqmV`.
- [x] **Characterful product motion** ✅ 2026-07-18
  Added a shared `BrandMotion` system and pose-specific mascot idle loops with
  restrained breathing, float and tilt. Home's overall balance now performs a true
  interpolated count-up; balance pills, group/friend chips, invoice amounts and the
  balance stamp use numeric transitions when their facts change. Tab changes use
  directional spring transitions, Groups/Friends/Home cards spring into place, the
  invoice unfolds from its top edge, and a newly saved expense is visibly revealed
  into the receipt after the Add Expense screen closes. Every continuous or spatial
  effect reads `accessibilityReduceMotion`; reduced mode uses immediate updates or a
  short fade and suppresses idle loops and moving confetti. Clean validation: 21
  unit/default tests + 2 XCUITests. Normal-mode screenshots differed across the idle
  cycle; Reduce Motion screenshots taken three seconds apart were pixel-identical.
  Superseded install: `https://build.sqim.dev/sqim/install/JJcL8N4LYyq-`.
- [x] **Account, currency, reminders & feedback motion** ✅ 2026-07-18
  Added Profile currency selection across eight display currencies while retaining
  INR as the default and whole-unit ledger math. Added Sign in with Apple using
  the official authorization control plus credential-state handling, and enabled
  the App ID/capability through refreshed automatic provisioning. Added branded
  local reminder preferences for Friday payments, Sunday settle-up, and first-of-
  month shared dues. Replaced the native destructive expense popover with a full
  cobalt/cream confirmation, made expense-detail names Courier Prime, and protected
  the complete Add Friend handwritten heading. Tab direction and receipt expense
  insertion now use deliberately slower springs; settlement confetti falls from
  above the viewport through the bottom, with Reduce Motion suppression intact.
  The next subtle progression phase is specified in `mockups/GAMIFICATION_PLAN.md`
  with healthy-action XP, raccoon-friend pins, idempotency and anti-compulsion
  guardrails. Visual checks passed and 22 unit/default tests + 2 XCUITests are green.
  Superseded install: `https://build.sqim.dev/sqim/install/2NGmUolsO7WZ`.
- [x] **Home balance & currency-outline alignment** ✅ 2026-07-18
  Centered the complete Home overall-balance composition—caption, animated total,
  squiggle and both balance pills—on one vertical axis. Currency choices now use
  true capsules and the same uniform 2.5pt cobalt outline as the app's other
  selectors. Simulator screenshots were visually checked, all 22 unit/default
  tests + 2 XCUITests passed, and a refreshed signed build was published.
  Superseded install: `https://build.sqim.dev/sqim/install/Yku0vVQkqtjd`.
- [x] **Mascot motion decision lab** ✅ 2026-07-18
  Added a Profile-accessible live comparison lab for ten mascot directions:
  blink/eye dart, hand wave, save hop, pose crossfade, card peek, balance look,
  shake/nod feedback, tap reaction, achievement-pin unlock and scroll parallax.
  Each prototype names its recommended placement and flags whether the finished
  result can use today's pose assets or needs layered eye/arm/tail artwork. The
  lab is replayable, honours Reduce Motion with a static preview, and is also
  available directly through the `-showMotionLab` launch hook. Simulator visuals
  were checked and all 22 unit/default tests + 2 XCUITests are green.
  Superseded install: `https://build.sqim.dev/sqim/install/4RQD3j4roO5P`.
- [x] **Contextual mascot scene motion** ✅ 2026-07-19
  Imported all four `BillBandit-Raccoon-Scene-Variations-SVG` files directly as
  transparent, vector-preserving asset-catalog images. Extended the Motion Lab
  from 10 to 14 prototypes with receipt fidget, overdue bell ring, couch search
  sweep and sleepy breathing/ascending Zs. The selector now follows the chosen
  prototype automatically. Scene 11/12 notes explicitly call out the separate
  receipt or bell/arm layers needed for final prop-only motion; scene 13/14 work
  with the current flattened SVGs. Every animation pauses to a static composition
  under Reduce Motion. All four were visually checked on iPhone 17; 22 unit/default
  tests + 2 XCUITests pass.
  Superseded install: `https://build.sqim.dev/sqim/install/DoYt1P1VwE6Z`.
- [x] **Contextual mascot placement & Profile hub** ✅ 2026-07-19
  Put the sleepy-bed scene into the empty-group invoice state with slow breathing
  and rising Zs, and put the thinking mascot's aligned blink/eye-dart animation on
  Add Expense. Reduce Motion keeps both scenes static. Add Expense now separates
  `PAID BY` and `SPLIT TYPE` using the same section-label typography, with the
  equal-split summary raised to 11.5pt after the approved parity audit. Renamed
  the Friends tab to Profile and embedded the complete friends ledger and Add
  Friend flow alongside account, currency, reminders and motion settings; tapping
  the Home avatar now opens this tab. Profile is reserved as the future home of
  levels, achievement pins and progression stats—those systems are not yet
  implemented. Visual checks passed; 22 unit/default tests + 2 XCUITests are green.
  Superseded install: `https://build.sqim.dev/sqim/install/rAzS0avtDtKL`.
- [x] **Selectable raccoon profile avatars** ✅ 2026-07-19
  Imported the eight supplied `profile-avatars-v1` PNGs as app assets and added a
  persistent, migration-safe avatar choice to `Person`. Profile now has a large
  identity preview and four-by-two picker; a selection saves immediately and is
  reused in the name field, friend ledger, bottom Profile tab and Home dashboard
  avatar. Existing people receive stable characterful defaults, while seeded Maya,
  Arjun, Riya and Sam use the intended distinct artwork. Simulator visual QA passed,
  all 22 engine tests pass, and the targeted avatar picker→dashboard XCUITest passes.
  The grid is contextual rather than permanently visible: tapping the large Profile
  avatar opens it, and entering Profile through the Home avatar opens it immediately.
  Choosing an avatar closes the grid. Shared avatar rendering now uses a 1.145× crop
  so the artwork fills and aligns precisely inside every circular container. The
  deliberately small first gamification scope lives in
  `mockups/GAMIFICATION_EARLY_PLAN.md`: three levels, three XP actions, three pins.
  This work is included in the early-gamification build below.
- [x] **Early gamification: levels, XP and starter pins** ✅ 2026-07-19
  Implemented the approved small progression loop: Level 1 Lookout (0 XP), Level
  2 Crew Scout (50 XP) and Level 3 Ledger Keeper (150 XP); +5 XP for a new
  expense, +8 XP for a new group and +10 XP for a recorded settlement. The three
  starter pins are Initiative Taker, Crew Founder and Settler Scion, using the
  supplied raccoon avatar art. Profile now contains the compact level card,
  progress bar, pin shelf and a private ON/OFF control. New expense/group actions
  show branded XP feedback; settlement rewards live inside the existing success
  celebration. SwiftData event keys make every award exactly-once in the same
  save transaction as its money action; edits, seed data and repeated events do
  not award XP. Opted-out actions are marked processed without retroactive replay.
  Reduce Motion uses static/fade feedback. Clean validation: 26 unit tests + 3
  end-to-end XCUITests; signed archive/export succeeded.
  Current install: `https://build.sqim.dev/sqim/install/tTDC2Q1tf4C6`.
- [x] **Profile, avatar, empty-state & activity notification polish** ✅ 2026-07-19 (local only)
  Removed the extra identity form row: the handwritten name beneath the large
  Profile avatar is now the inline editor. Avatar artwork uses a tighter crop,
  exact circular clipping and one app-owned solid cobalt outline in Profile,
  Home, the tab bar and people rows. Profile no longer exposes currency,
  reminders or the mascot motion lab; startup forces INR and retires previously
  scheduled BillBandit reminder requests. The early-progression switch now uses
  a single smooth sliding capsule with a short ease transition. Empty invoices
  show only the sleepy-bed scene (no perched invoice mascot), while Add Expense
  holds the thinking raccoon body still and animates only its eyes. Activity items
  now carry migration-safe actor/group context; other-actor items newer than the
  last Activity visit produce a numbered Home bell badge, the bell opens Activity,
  and eligible ledger summaries end with `in <group name>`. Old local ledger rows
  are enriched from their referenced group/expense/settlement where possible.
  Cross-device delivery still requires the future sync layer; the UI/data behavior
  is ready for remotely inserted ActivityItems. Validation: 28 unit tests + 4
  end-to-end XCUITests on iPhone 17. Visual QA:
  `/tmp/billbandit-profile-cleanup.png` and
  `/tmp/billbandit-home-activity-badge.png`. Per user instruction, this phase was
  initially remained local-only, then shipped as part of the invoice-interaction
  build below.
- [x] **Expandable invoice balances & delete-confirmation typography** ✅ 2026-07-19
  The group invoice balance stamp is now the disclosure control. Tapping `YOU OWE`
  or `OWED TO YOU` springs open the bottom of the receipt and shows only settlement
  transfers involving the current user, with explicit rows such as `You owe Maya
  Chen ₹18` or `<name> owes you <amount>`; tapping the stamp again collapses it.
  Reduce Motion uses a short fade. Protected the final Caveat flourish in `erase
  this receipt?` with a nonbreaking trailing glyph, fixed horizontal sizing and
  safe inset padding. Visual QA: `/tmp/billbandit-invoice-balance-breakdown.png`
  and `/tmp/billbandit-delete-confirmation-fixed.png`. Validation: 28 unit tests +
  4 end-to-end XCUITests, signed device archive/export, and Sqim upload succeeded.
  Current install: `https://build.sqim.dev/sqim/install/zhoTt_KxctNR`.
- [x] **Eight-pin illustrated achievement row** ✅ 2026-07-19
  Replaced the starter-avatar placeholders with dedicated circular achievement
  artwork. Six pins are cropped from the user-supplied board (Initiative Taker,
  Settler Scion, High on Details, Crew Founder, Split Personality and
  Peacekeeper); two matching additions were created for Big Spender and Partner
  in Crime. Profile now presents all eight in a clean horizontally scrolling row
  directly on the cream Profile surface: no shelf background, no enclosing outline
  and no individual card chrome. The artwork's circular pin border remains.
  Locked pins stay muted while unlocked pins retain full colour. Added real,
  idempotent milestones for first edit, three split
  methods, five settlements, top group payer and first friend alongside the
  existing first-expense/group/payment rewards. Validation: 30 unit tests and 5
  end-to-end UI flows pass on iPhone 17. Visual QA:
  `/tmp/billbandit-achievement-row-start.png` and
  `/tmp/billbandit-achievement-row-end.png`. The development-signed archive and
  export succeeded with the Apple Sign In entitlement intact.
  Current install: `https://build.sqim.dev/sqim/install/Wy39PsCZ0gDm`.
- [x] **Achievement density, progress motion & Activity subtitle** ✅ 2026-07-19
  Achievement artwork now scales beyond the circular crop so every pin fills its
  circle without an app-added ring or empty inset. Reduced the achievement-row
  height and grouped it tightly with Friends, removing the oversized vertical
  gap. Progress ON/OFF now uses a slower, heavily damped reveal spring with a
  top-origin transition; Reduce Motion still uses a short fade. Activity now
  shows the handwritten `this month` subtitle and its UI test asserts the label.
  The achievement-scroll, Activity and complete money-flow UI tests pass. Visual
  QA: `/tmp/billbandit-profile-achievement-density.png` and
  `/tmp/billbandit-activity-this-month.png`. A separate interactive comparison
  of Raised Action, Floating Dock and Receipt Notch bottom-navigation directions
  lives in the thread visualization `bottom-tab-directions.html`; no tab-bar
  direction has been implemented in the app pending user approval.
- [x] **Floating bottom navigation dock** ✅ 2026-07-19
  Replaced the edge-to-edge tab bar with the approved floating rounded dock.
  Home, Groups, Activity and the selected raccoon Profile avatar retain the exact
  shipped BillBandit iconography; Add Expense is now an integrated 48pt cream
  center action rather than a raised control outside the bar. The dock uses the
  approved deep cobalt at 90% opacity while its labels, icons and action remain
  crisp at full opacity. Content receives 76pt bottom clearance, and the dock has
  a restrained deep-cobalt shadow and 18pt screen inset. Simulator build and
  visual QA passed: `/tmp/billbandit-floating-dock-home.png`. Included in the
  pre-beta build below.
- [x] **Collapsible progression & avatar preview confirmation** ✅ 2026-07-19
  Replaced the insertion/removal reward animation shown in the user's recording
  with one animatable vertical layout: the level card and complete pin row remain
  one measured unit, clip from the top, and smoothly expand/collapse like a
  window. The OFF-state explanatory card was removed so the closed state is only
  the section header and toggle. Every achievement now receives the same clean
  inset 3pt cobalt circular ring while preserving the close artwork crop; locked
  rings use the same thickness at muted opacity. Avatar choices now remain open
  after every selection and update only the large preview. Tapping the large
  avatar confirms, persists and closes the chooser, so users can try several
  options first. Updated UI coverage verifies preview-before-save, explicit
  confirmation, collapse accessibility and all eight horizontally scrolling pins.
  Achievement, avatar and full money-flow UI tests pass. Visual QA:
  `/tmp/billbandit-achievement-rings.png`. Included in the pre-beta build below.
- [x] **Add Expense cleanup & unified badge keylines** ✅ 2026-07-19
  Removed the trailing camera accessory from the Add Expense name row. Increased
  the achievement artwork crop beneath its circular mask so each source badge's
  own keyline is hidden under the shared 3pt ring; this removes the inconsistent
  double-ring gaps while keeping one clean, uniform outline across all eight
  badges. Achievement shelf and complete money-flow UI tests pass (2 tests, 0
  failures). Visual QA: `/tmp/billbandit-achievement-rings-unified.png`. Included
  in the pre-beta build below.
- [x] **Shared outline contract & toast badge parity** ✅ 2026-07-19
  Added `BrandOutline.control` as the required inset `strokeBorder` width for
  capsule, pill and rounded-control surfaces; the Profile level card now follows
  it and presents the same clean visible weight as the app's other capsules.
  Extracted the achievement crop/ring treatment into `AchievementBadgeView` and
  use that exact component in both Profile pins and reward toasts, making the art
  flush with one 3pt outer ring at every size. The contract is recorded in
  `mockups/NOTES.md`. Achievement-shelf coverage and the complete money-flow UI
  flow pass; the latter explicitly captures the unlock toast. Visual QA:
  `/tmp/billbandit-level-outline.png` and `/tmp/billbandit-toast-badge.png`.
  Included in the pre-beta build below.
- [x] **Pre-beta cleanup, regression gate & Release build** ✅ 2026-07-19
  Fully removed the retired reminder preference/scheduling implementation while
  keeping one idempotent launch cleanup for legacy pending and delivered
  notifications. Bound the hand-maintained Info.plist to Xcode's marketing/build
  settings and advanced the app to version **1.0 (2)**. The complete iPhone 17 Pro
  gate passes with **31 engine/model tests + 5 UI flows**; the compact-device
  avatar/navigation path also passes on a warmed iPhone 17e. A Release archive was
  development-signed with the explicit `com.billbandit.app` provisioning profile,
  exported and uploaded. The published manifest was independently verified as
  bundle version `2`. Published install (superseded below):
  `https://build.sqim.dev/sqim/install/E063Sb9yuuYG`.

  This is the final internal direct-install beta gate, not an external beta. The
  current product remains local-only: Sign in with Apple stores identity locally,
  and groups, friends, expenses and activity do not sync between people/devices.
  External TestFlight beta requires a shared backend/sync and invite model,
  versioned data migration, App Store Connect/privacy metadata, distribution
  signing, crash/feedback telemetry and a defined tester cohort.
- [x] **Live settlement amount suggestions** ✅ 2026-07-19
  Record Payment now derives its amount from the group's current settle-up plan
  whenever `who paid` or `who received` changes. It opens on the current user's
  transfer when one exists, otherwise the first outstanding transfer. A matching
  direction fills the exact whole-rupee balance immediately; reversed or unrelated
  pairs clear the field rather than suggesting an incorrect payment. The amount
  remains editable so partial settlements are still possible. Pure-engine coverage
  verifies pair and direction matching, and the end-to-end flow verifies the seeded
  `You → Maya` suggestion changes from ₹18 to ₹8 when the payer becomes Arjun.
  Validation: **32 engine/model tests + 5 UI flows** pass on iPhone 17 Pro. Release
  version **1.0 (3)** was signed, exported and its uploaded manifest verified.
  Current install: `https://build.sqim.dev/sqim/install/VlffrF1iMn_N`.
- [x] **Empty-group ledger integrity & bounded settlements** ✅ 2026-07-19
  Empty groups now always resolve to `ALL SQUARE`: the settle action is disabled,
  and a one-way launch repair removes invalid settlements (plus their activity
  rows) that earlier builds allowed in groups with no expenses. Record Payment
  now exposes only payer/recipient pairs in the live settle-up plan. Suggested
  amounts remain editable for partial payments but cannot exceed the outstanding
  transfer; over-limit input shows the maximum and disables saving. Expense
  deletion detects when existing payments would cross into a refund balance and
  warns before confirmation. Deleting the final expense also clears the group's
  now-baseless payments. Validation: **34 engine/model tests** pass; focused UI
  coverage verifies empty-group All Square behavior, valid ₹18→₹8 suggestions and
  rejection of a ₹9 payment against an ₹8 debt. Release **1.0 (4)** was signed,
  exported and its uploaded manifest verified. Current install:
  `https://build.sqim.dev/sqim/install/r9VlqikAcTJ1`.
- [ ] **External beta collaboration & TestFlight** — in progress 2026-07-20
  The app now keeps SwiftData explicitly local and mirrors each group into its
  own shareable CloudKit record zone. Group owners can invite collaborators from
  the invoice; accepted shares sync members, expenses, splits, settlements and
  group-labelled activity through the private/shared CloudKit databases. Local
  saves remain immediate and foreground/push sync retries offline changes.
  Invitation identity is matched by profile name when unambiguous; otherwise a
  branded one-time member picker prevents an invitee from inheriting the wrong
  balance. Uploads are serialized to prevent rapid mutations racing each other.
  Existing stores migrate through optional CloudKit metadata only, and the app's
  SwiftData configuration deliberately disables automatic CloudKit mirroring.
  CloudKit, sharing, push, background notification and Sign in with Apple
  entitlements are present in the generated device profile. A privacy manifest
  declares the app-only UserDefaults reason required for distribution.

  Validation: **40/40 tests pass** (34 engine/model + 6 UI flows) on iPhone 17
  Pro; signed generic-device Debug and Release archive/export both pass. Sqim
  manifest verified version **1.0 (5)**. Collaboration smoke build:
  `https://build.sqim.dev/sqim/install/eCVMl4YDuWtQ`.

  On 2026-07-20, `CloudKit/CloudKitSchema.ckdb` passed CloudKit Console
  validation, was imported into Development and deployed to Production with the
  user's explicit approval. Production was independently checked after refresh:
  BBActivity (14 fields), BBExpense (15), BBGroup (15), BBPerson (10), and
  BBSettlement (12) are present. Before inviting external testers, verify one
  owner/invitee round trip on two Apple accounts and finish the App Privacy,
  privacy-policy and Beta App Review metadata. Do not claim the external
  TestFlight beta is live yet.

  The obsolete App Store Connect record using `com.esha.fareshare` was deleted by
  the user. On 2026-07-20 a new canonical **BillBandit** record was created with
  app ID `6792712181`, SKU `BILLBANDIT-IOS-2026`, and bundle ID
  `com.billbandit.app`. Production-signed version **1.0 (5)** was uploaded from
  `/tmp/BillBandit-1.0-5.xcarchive`; App Store Connect finished processing it and
  its export-compliance answer was completed as containing no custom/non-exempt
  encryption. The TestFlight beta description, feedback/review contact, review
  notes and build-specific testing instructions were completed. Internal group
  **BillBandit Internal QA** and external group **BillBandit Public Beta** were
  created; build 5 was added to both and submitted for Beta App Review. Its
  current external status is **Waiting for Review**. An open-to-anyone public
  link with no tester cap was created at
  `https://testflight.apple.com/join/JR7WttFq`. Apple will not allow testers to
  join through it until the first external build is approved.

  Build **1.0 (6)** replaces build 5 for the beta candidate. It adds the
  mandatory Sign in with Apple onboarding gate and a real CloudKit-backed friend
  invitation handshake with share sheet, QR/deep link and one-time code entry.
  The production CloudKit schema now also contains `BBFriendInvite` and
  `BBFriendAcceptance`. Validation is **44/44 tests passing** (36 engine/model +
  8 UI flows). Build 6 was uploaded to App Store Connect, export compliance was
  completed, build 5 was withdrawn from Beta App Review and removed from the
  public group, and build 6 was submitted in its place. On 2026-07-20 the user
  chose to continue product work, so build 6 was withdrawn from Beta App Review.
  App Store Connect now reports **Ready to Submit**. The public link remains
  `https://testflight.apple.com/join/JR7WttFq`. Internal QA already has build 6.

  Build **1.0 (7)** is the current device-test candidate. Onboarding now keeps
  `BillBandit` on one line and completes immediately after successful Sign in
  with Apple; the redundant `Enter BillBandit` control is removed. The friend
  invite heading is now `add a partner in crime`, with compact scaling that
  prevents the final word clipping. Raw CloudKit errors are replaced with
  concise branded retry messages. The schema grants authenticated iCloud users
  `CREATE` access for all seven public BillBandit record types; the corrected
  schema was imported into Development and CloudKit Console confirmed it was
  deployed to Production on 2026-07-20. Validation is **44/44 tests passing** and
  the onboarding/invite screens passed simulator visual QA. Build 7 is available
  through Sqim at `https://build.sqim.dev/sqim/install/2l9N6CzTMGfO`; its
  manifest reports bundle `com.billbandit.app`, build 7. It has not replaced
  TestFlight build 6 yet.

## 4. Build & run playbook

```bash
cd "BillBandit"
# build (uses default DerivedData on purpose — see §6 iCloud note)
xcodebuild -project BillBandit.xcodeproj -scheme BillBandit -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# test (34 engine/design-default tests + 6 UI flows = 40 total)
xcodebuild -project BillBandit.xcodeproj -scheme BillBandit -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# install + launch + screenshot (hooks: `-tab N`, `-showAdd`, `-showAddFriend`, `-showMotionLab`, `-openGroup <name>`,
# `-onboardingPage N`; `-onboardingDemo` auto-advances all three pages for recording)
D=<simulator-udid>
APP=$(find ~/Library/Developer/Xcode/DerivedData/BillBandit-*/Build/Products/Debug-iphonesimulator/BillBandit.app | head -1)
xcrun simctl install $D "$APP"
xcrun simctl launch $D com.billbandit.app -tab 1 -openGroup Goa Trip
xcrun simctl io $D screenshot /tmp/shot.png
```

- Bundle ID `com.billbandit.app` · team `4JRB53LG5C` · scheme `BillBandit`
  (shared; unit + UI test targets run via the same scheme's Test action).
- The project file was **hand-generated** (no XcodeGen/Tuist installed). If you add
  files, add them to `BillBandit.xcodeproj/project.pbxproj` (deterministic
  md5-based UUIDs — follow the existing pattern) or install a generator.
  ⚠️ **Quote any path containing `+`** (e.g. `BalanceMath+SwiftData.swift`) —
  unquoted `+` in a bare pbxproj string is a parse error.
- Sqim: already logged in (`sqim status`). Only used at Phase 5 (user-approved).

## 5. Asset pipelines (re-runnable, no installs needed)

**Mascot PDFs** — source `BillBandit-Raccoon-SVG/*.svg`; wrap in an HTML page
(`@page{size:1280px;margin:0}` + `<img>`), headless-Chrome `--print-to-pdf`,
drop into `Assets.xcassets/mascot-*.imageset` (single-scale,
`preserves-vector-representation`).

**Icon PDFs** — extract `i-*` `<symbol>`s from `mockups/index.html`, wrap with
`stroke:#000;fill:none;sw:2;round caps` on a 240px page, same Chrome step, into
`icon-*.imageset` with `template-rendering-intent: template`.
⚠️ Chrome gotcha hit once: the print URL **must be an absolute `file://` URI** —
a relative one silently renders Chrome's error page into the PDF (icons looked
like solid squares; diagnose by `sips -s format png file.pdf --out x.png`).

**Fonts** — 13 TTFs in `BillBandit/Fonts/` (Fredoka 400–700, Caveat 500–700,
CourierPrime 400/700, Nunito 400–800; all SIL OFL), registered via `UIAppFonts`
in `Info.plist`. PostScript names are hardcoded in `DesignSystem/BrandFonts.swift`
(verified via CoreText). If a font renders as system font, the PS name is wrong.

**App icon** — greeting pose on mascot-ink cobalt, tightly cropped around the face,
upper body and waving arm. Source PNG lives in
`Assets.xcassets/AppIcon.appiconset/AppIcon.png`; regenerate losslessly from the
vector source with:

```bash
swift Tools/generate_app_icon.swift \
  BillBandit/Assets.xcassets/mascot-greeting.imageset/greeting.pdf \
  BillBandit/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
  245 365 560 560
```

## 6. Environment gotchas (cost real time — read before building)

- **FinderInfo vs codesign:** the built `.app`/`.xctest` dirs get a
  `com.apple.FinderInfo` xattr → codesign fails with "resource fork… not allowed".
  Root cause: **the project lives in iCloud-synced `~/Documents`** — the file
  provider decorates new bundles. Mitigations in place: `Strip FinderInfo before
  codesign` script phases on BOTH targets (keep them;
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`). And **build with default DerivedData**
  (`~/Library/Developer/...`, not synced) — do NOT pass `-derivedDataPath` inside
  the repo, or test builds re-fail (PlugIns copy re-adds FinderInfo mid-build).
- `com.apple.provenance` xattrs are OS-managed and **cannot** be removed — harmless.
- **Model named `Group` shadows `SwiftUI.Group`** — always write `SwiftUI.Group`
  when you mean the layout container.
- Swift 6-era concurrency: `container.mainContext` is main-actor; don't touch it
  from static initializers. DEBUG seeding runs via `RootTabView.task` →
  `AppStore.seedIfNeeded`.
- Generic `catch {}` blocks bind an implicit `error` that shadows state vars —
  name state `errorMessage`, not `error`.
- SwiftData many-to-many needs an explicit inverse (`Person.groups`) or members
  get stolen between groups.
- Nav titles: styled globally via `UINavigationBarAppearance` in
  `BillBanditApp.init` (Fredoka, cream, transparent bg). SwiftUI
  `toolbarColorScheme`/`toolbarBackground` combos made titles vanish — don't
  re-add them.
- `xcodebuild` failures can be transient; retry once before debugging. Simulator
  shuts down after `xcodebuild test` (clone device) — `simctl boot` again.
- First-launch screenshot may catch the white launch screen — wait ~4s, retake.

## 7. Code map (current)

```
BillBandit/BillBandit/
├── BillBanditApp.swift        @main, light scheme, UINavigationBarAppearance (Fredoka cream titles)
├── Info.plist                 UIAppFonts, light status bar, portrait, CloudKit sharing
├── PrivacyInfo.xcprivacy      App-only UserDefaults required-reason declaration
├── Assets.xcassets/           AppIcon + mascot-* (6) + avatar-* (8) + icon-* (19) imagesets
├── Fonts/                     13 bundled TTFs
├── DesignSystem/
│   ├── BrandColors.swift      Color.Brand.{cobalt,cobaltDeep,cream,creamSoft,mascotInk,mascotCream}
│   ├── BrandFonts.swift       BrandFont.{display,hand,type,body}(size,weight)
│   └── BrandAssets.swift      Mascots/icons + shared RewardFeedbackCenter
├── Models/
│   └── Models.swift           ledger models + actor/group-aware ActivityItem + avatar/progression models
├── Engine/                    pure money cores + SwiftData adapters — unit-tested
│   ├── Money.swift            Decimal facts + whole-unit normalization + selectable formatting + input parsing
│   ├── SplitEngine.swift      equal/exact/%/shares → exact-sum splits, deterministic remainders
│   ├── BalanceEngine.swift    nets from snapshots, greedy min-transaction simplify
│   └── BalanceMath+SwiftData.swift  ledger adapters + idempotent RewardEngine
├── Store/
│   ├── AppStore.swift         local ModelContainer + seed/reset + activity enrichment/unread helpers
│   └── CloudCollaboration.swift automatic connected-friend shared-zone sync, invites, push, identity mapping
├── Shell/
│   ├── RootTabView.swift      first-run gate + cobalt tabs/FAB + haptics; screenshot args; .task seeds
│   └── PlaceholderScreens.swift  onboarding + live Home + Activity ledger + shared chips/rows
├── UI/
│   ├── FriendsScreen.swift    Profile friends ledger, add/delete friend, NetChip(style:)
│   ├── GroupsScreen.swift     groups list + nav (launch arg -openGroup), AddGroupSheet
│   ├── GroupDetailScreen.swift  paper invoice + expense detail/edit/delete + settle celebration
│   └── AddExpenseSheet.swift  B4 layout: amount/title/category/group/paidBy + 4 split modes
├── BillBanditTests/           engine/model/design-default coverage (34 tests)
└── BillBanditUITests/         money-flow + group + avatar + Activity + settlement XCUITests (6 flows)
```

Conventions: Swift 5 mode · 4-space indent · no emoji in code/assets · money is
`Decimal` via `Money.cents` · `Color.Brand`/`BrandFont`/`MascotView`/`BrandIconView`
everywhere — no ad-hoc values · record user actions as `ActivityItem`s (feed in Phase 3).

## 8. Suggested skills for the next session

- Building/running/testing the app → follow §4; ship at Phase 5 with **sqim**
  (`sqim upload --device --build`, already logged in).
- Major design changes → update `mockups/NOTES.md`; roadmap changes →
  `mockups/PLAN.md` §6b. **Any phase completion → update this file's §3/§7.**
- If context gets compacted mid-work → the `handoff` skill; write output into
  this file (this document replaces one-off handoffs).

## 9. Ship notes

- Phase 3 was approved by the user on 2026-07-18.
- Gate artifacts: `/tmp/billbandit-onboarding-1.png`,
  `/tmp/billbandit-onboarding-name.png`, and `/tmp/billbandit-home-rupee.png`.
- Build succeeded on iPhone 17 simulator; all 19 tests passed. The only
  build warning is the intentional FinderInfo stripping phase described in §6.
- Fresh installs show onboarding; `-tab`, `-showAdd`, `-openGroup`, or explicit
  `-skipOnboarding` bypass it for screenshots. `-onboardingPage 0...2` selects a
  page without bypassing; `-onboardingDemo` auto-advances pages 0→1→2.
- ₹ is presentation-only; amounts remain currency-agnostic `Decimal` facts in
  the engine. This avoids a data migration and keeps future multi-currency open.
- The device build needs development team `4JRB53LG5C`; it is now stored in both
  app target configurations. Sqim used automatic provisioning updates.
- Sign in with Apple uses `BillBandit.entitlements`. A plain archive can select an
  old wildcard profile and fail; use Sqim's `--allow-provisioning-updates` (or
  Xcode's equivalent) so the explicit `com.billbandit.app` profile is refreshed.
- Final validation: 19 unit/default tests + 1 UI smoke passed on iPhone 17.
- Post-ship device feedback validation: 19 unit/default tests + 1 UI smoke passed
  on iPhone 17; visual checks saved as `/tmp/billbandit-feedback-{home,groups,invoice,add}.png`.
- Branded modal previews: `/tmp/billbandit-custom-add-expense.png` and
  `/tmp/billbandit-custom-settle-up.png`.
- Outline/title previews: `/tmp/billbandit-clean-category-outlines.png` and
  `/tmp/billbandit-record-payment-title.png`.
- Live-ledger previews: `/tmp/billbandit-live-home.png`,
  `/tmp/billbandit-live-group-actions.png`, `/tmp/billbandit-live-settle-heading.png`,
  and `/tmp/billbandit-live-friend-chips.png`.
- Motion previews: `/tmp/billbandit-motion-home.mov`,
  `/tmp/billbandit-motion-home.png`, and `/tmp/billbandit-reduce-motion-{a,b}.png`.
- Account/preferences previews: `/tmp/billbandit-profile.png` and
  `/tmp/billbandit-add-friend.png`.
- Alignment previews: `/tmp/billbandit-home-centered.png` and
  `/tmp/billbandit-currency-capsules.png`.
- Previous validation: 22 unit/default tests + 2 UI flows passed on iPhone 17;
  development-signed archive/export succeeded with the Apple Sign In entitlement.
- Superseded install link: `https://build.sqim.dev/sqim/install/rAzS0avtDtKL`.
- Local avatar validation: simulator build + all 22 unit tests + targeted avatar
  propagation XCUITest passed; screenshots `/tmp/billbandit-avatar-profile.png`
  and `/tmp/billbandit-avatar-profile-collapsed.png`.
  This avatar state is included in the current build.
- Early-gamification preview: `/tmp/billbandit-gamification-profile.png`.
- Published-build validation: 26 unit/default tests + 3 UI flows passed on iPhone 17;
  device archive/export succeeded with Apple Sign In entitlement intact.
- Superseded install link: `https://build.sqim.dev/sqim/install/tTDC2Q1tf4C6`.
- Previous validation: 30 unit tests + 5 UI flows passed on iPhone 17. Achievement
  row previews: `/tmp/billbandit-achievement-row-start.png` and
  `/tmp/billbandit-achievement-row-end.png`. The signed device archive/export
  retained the Sign in with Apple entitlement.
- Superseded install link: `https://build.sqim.dev/sqim/install/Wy39PsCZ0gDm`.
- Pre-beta validation: 31 engine/model tests + 5 UI flows passed on iPhone 17 Pro;
  the targeted compact-device avatar/navigation flow passed on iPhone 17e. The
  final Release archive/export retained the Sign in with Apple entitlement and
  published as version 1.0, build 2.
- Superseded install link: `https://build.sqim.dev/sqim/install/E063Sb9yuuYG`.
- Settlement-autofill validation: 32 engine/model tests + 5 UI flows passed on
  iPhone 17 Pro. Release archive/export succeeded and the Sqim manifest reports
  version 1.0, build 3.
- Superseded install link: `https://build.sqim.dev/sqim/install/VlffrF1iMn_N`.
- Ledger-integrity validation: 34 engine/model tests pass; focused empty-group and
  bounded-settlement UI flows pass on iPhone 17 Pro. Release archive/export
  succeeded and the Sqim manifest reports version 1.0, build 4.
- Superseded install link: `https://build.sqim.dev/sqim/install/r9VlqikAcTJ1`.
- Collaboration beta validation: 40/40 tests pass on iPhone 17 Pro. The signed
  device profile contains CloudKit, push and Sign in with Apple entitlements;
  Release archive/export succeeded and Sqim reports version 1.0, build 5.
- CloudKit production validation: all seven BillBandit record types were imported,
  deployed and independently verified in the Production environment on 2026-07-20.
- App Store export validation: version 1.0 (6) exported with Store distribution
  signing, Production CloudKit/APNs, Sign in with Apple and the privacy manifest.
- Friend/auth beta validation: 44/44 tests pass on iPhone 17 Pro; App Store
  Connect accepted version 1.0, build 6. Its Beta App Review submission was
  withdrawn on 2026-07-20 while product work continues; its current external
  status is Ready to Submit.
- Friend-invite permission fix: the public schema now grants `CREATE` to
  authenticated iCloud users for all seven BillBandit record types. CloudKit
  Console validated the import and confirmed the Production deployment on
  2026-07-20.
- Build 7 validation: 44/44 tests pass on iPhone 17 Pro; onboarding and invite
  screens passed visual QA. The signed Sqim manifest reports bundle
  `com.billbandit.app`, build 7.
- Superseded install link: `https://build.sqim.dev/sqim/install/2l9N6CzTMGfO`.
- Automatic group-sharing build 8: selecting an already-connected friend during
  group creation immediately creates a private read/write CKShare and a public,
  recipient-specific `BBGroupInvitation` envelope. The recipient accepts it on
  launch/foreground or silent push; no second invite or Join action is shown.
  Shared person IDs are aliased to existing connected/current profiles, so group
  members, expenses, activities and notification actors stay consistent across
  devices. `BBGroupInvitation`, its recipient query index, `cloudkit.share`, and
  authenticated security grants were deployed to Production on 2026-07-20.
  Validation: 46/47 tests passed in the full run; the only miss was an XCUITest
  infrastructure snapshot-query timeout and that exact invite flow passed on an
  isolated retry. Device archive/export retained CloudKit, push and Sign in with
  Apple entitlements. Sqim manifest confirms `com.billbandit.app`, version 1.0,
  build 8.
- Build 9 friend-parity fix: connected CloudKit friends now replace a matching
  legacy name-only person throughout the local ledger (group members, expense
  payer/splits, settlements and activity actors). Group creation canonicalizes
  selected members to their connected identity, and rereading an accepted friend
  invite requeues affected groups so a previously missed automatic share retries.
  Onboarding now keeps identical mascot/title/body/form geometry across all three
  pages and preserves a fixed bottom control area, removing the page-three jump.
  Validation: the full iPhone 17 Pro suite passed 51/51 tests, including complete
  ledger migration, automatic-share routing and three-page onboarding alignment.
  The development-signed archive/export succeeded; its Sqim manifest confirms
  bundle `com.billbandit.app`, version 1.0, build 9.
- Superseded install link: `https://build.sqim.dev/sqim/install/B_vEM6LJnert`.
- Current install link: `https://build.sqim.dev/sqim/install/urGz0Jo5ZvLd`.
