# BillBandit — Plan (PROTOTYPE PHASE — review before implementation)

> An expense-splitting app (Splitwise-style) with a hand-drawn raccoon mascot,
> in cobalt blue + light cream. This document is the plan to approve before
> any iOS code is written.

## 1. Concept

Splitwise does the job but looks like accounting software. BillBandit makes
splitting money feel like a game: a mischievous-but-friendly raccoon "bandit"
(who wears the mask so you don't have to feel like one) guards your group
kitties, chases IOUs, and celebrates every settled bill.

**Design language** (from your references):
- Two colours only: **Cobalt `#1F3FC3`** + **Light Cream `#EFEFD7`** (+ white as breathing room).
- Hand-drawn but finished line illustrations — confident single-weight strokes, rounded caps, slightly wobbly on purpose.
- Type mix: chunky rounded display (wordmarks, big numbers) + handwritten script accents (Caveat-style) + clean rounded sans for body.
- Raccoon mascot recurs across screens with different expressions/poses.
- Animation moments: onboarding intro, settle-up celebration.

## 2. Feature set (Splitwise parity, scoped)

**MVP (v1)**
1. Onboarding — animated intro (raccoon slides), name setup, optional avatar doodle.
2. Friends — add by name, per-friend running balance, friend detail (shared expenses, groups in common, settle).
3. Groups — create group (home / trip / couple / custom), members, group icon doodle, per-group balances.
4. Expenses — title, amount, date, category (hand-drawn icon set), payer, notes, optional receipt photo.
5. Split methods — equally · exact amounts · percentages · shares.
6. Balances engine — per friend, per group, global "you owe / you're owed"; optional **simplify debts** (min-transaction graph).
7. Settle up — record a payment; full-screen raccoon celebration animation.
8. Activity feed — chronological log: expenses added/edited/deleted, settlements, new members.
9. Edit / delete expenses; balances recompute.

**v1.1 (after MVP ships)**
- Recurring expenses, reminders (local push), comments on expenses, search, multi-currency, export.

**v2**
- iCloud sync (CloudKit), Sign in with Apple, shared groups across devices.

## 3. Screens (v1)

| # | Screen | Raccoon moment |
|---|--------|----------------|
| 1 | Onboarding (3 slides + name entry) | waving, peeking, juggling coins; subtle looping bounce |
| 2 | Home / dashboard | peeks over the total-balance card |
| 3 | Groups list + create group | holds the "+" |
| 4 | Group detail (expenses, balances, members) | napping when group is settled, alert when money's due |
| 5 | Add / edit expense (sheet) | holding a receipt & pencil |
| 6 | Expense detail (splits, comments later) | small, in corner of receipt card |
| 7 | Settle up flow + **celebration** | happy-jump with coin burst + confetti (animated) |
| 8 | Friends list + add friend | offering a heart / paw |
| 9 | Activity feed | tiny spot illustrations between date headers |
| 10 | Profile / settings | sleepy raccoon on the log-out row |

## 4. Data model (SwiftData)

```
Person      id, name, avatarDoodleID, isCurrentUser
Group       id, name, iconID, members [Person], createdAt, simplifyDebts
Expense     id, group?, title, amount, currency, date, category, notes,
            paidBy Person, splits [Split], receiptImageID?
Split       person, mode (equal/exact/percent/share), value, computedAmount
Settlement  id, from Person, to Person, amount, date, group?
ActivityItem id, kind, refID, timestamp, summary
```

Balance math: per-person net within each group (and globally for non-group
expenses); optional min-flow simplification. Covered by unit tests.

## 5. Tech stack

- **SwiftUI + SwiftData**, iOS 17+, iPhone-only portrait (iPad later).
- Illustrations: hand-tuned vector raccoon set, single-colour template assets
  (recolour cobalt/cream automatically, dark-mode ready).
- Animations: native SwiftUI (`withAnimation`, matched geometry, keyframes) —
  no Lottie dependency.
- Icons: custom hand-drawn-style SF-Symbol-scale set, not stock SF Symbols.
- Persistence local-first (SwiftData); CloudKit in v2.
- Tests: XCTest for balance engine + split math; XCUIT smoke test of core flows.

## 6. Build phases

- **Phase 0 (done)** — plan + 3 visual directions as clickable mockups → Direction B approved; v2 feedback applied; v3 official mascot SVG set inlined.
- **Phase 1** — Xcode project, design system (colours, type, icon set, raccoon assets), app shell + tab navigation.
- **Phase 2** — data model + friends/groups/expenses CRUD + split engine (with tests).
- **Phase 3** — balances dashboard, settle-up flow + celebration animation, activity feed.
- **Phase 4** — onboarding animation, empty states, illustration polish, haptics.
- **Phase 5** — full build, tests, then an installable build on your iPhone via Sqim (HTTPS install link).

## 6b. Implementation roadmap (approved 2026-07-18)

User-approved decisions for the iOS build:
- **Stack:** SwiftUI + SwiftData, iPhone portrait, **iOS 18+ minimum**, light-mode only v1.
- **Database:** SwiftData (local-first). Balances are always *computed* from expenses/splits/settlements by a unit-tested engine — never stored. CloudKit sync stays a v2 option without model rewrites.
- **Mascot assets:** the 6 official SVGs in `../BillBandit-Raccoon-SVG/` are the source of truth. iOS cannot render SVG at runtime, so a scripted headless-Chrome step converts them to vector PDFs for the asset catalog (re-runnable if art changes). Icons likewise become single-colour template vectors.
- **Fonts:** Fredoka / Caveat / Courier Prime / Nunito bundled as TTFs (all SIL OFL).
- **Phase gates:** each phase ends with a simulator build + screenshots for user sign-off before the next begins. Sqim device install at Phase 5.

## 7. The 3 mockup directions (see `index.html` — arrow keys / bottom bar to switch)

- **A — Cream Canvas**: light, airy, cream paper everywhere, cobalt ink drawings. Calm, notebook-like.
- **B — Cobalt Club**: full-bleed cobalt, huge cream display type, inverted cards. Bold, poster-like.
- **C — Split Personality**: cream app with cobalt "hero" panels; full-cobalt takeover for celebration moments.

Mixing is allowed — "A's home with B's settle screen" is valid feedback.
