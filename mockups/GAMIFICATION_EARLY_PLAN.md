# BillBandit — Early Gamification Plan

## Goal

Add a small sense of progress to useful ledger actions without turning money,
debt, or friendship into a competition. This first inclusion should fit inside
Profile and reuse the app's existing success moments.

## First-release scope

### Three levels

| Level | Title | Lifetime XP |
|---:|---|---:|
| 1 | Lookout | 0 |
| 2 | Crew Scout | 50 |
| 3 | Ledger Keeper | 150 |

Profile shows one compact progress card: current title, total XP, and a simple
bar reading `32 / 50 XP`. Levels are cosmetic and never gate app features.

### Three rewarded actions

| Action | XP | Rule |
|---|---:|---|
| Add an expense | +5 | Once per expense ID |
| Create a group | +8 | Once per group ID |
| Record a payment | +10 | Once per settlement ID |

There are no spend multipliers, daily streaks, speed bonuses, or debt-based XP.

### Three starter pins

| Pin | Unlock |
|---|---|
| Initiative Taker | Add the first expense |
| Crew Founder | Create the first group |
| Settler Scion | Record the first payment |

Profile shows these as a three-pin shelf directly below the level card. Locked
pins remain visible as line-art silhouettes with a plain-language requirement.

## Feedback

- Routine action: a small non-blocking `+5 XP` toast above the tab bar.
- First pin: one branded cream card with the raccoon pin, title, and reason.
- Level up: the Profile progress bar fills and the title crossfades once.
- Reduce Motion: use fades and one success haptic; no particles or bouncing.

## Minimal implementation

Persist only:

1. `UserProgress`: person ID and lifetime XP.
2. `ProcessedRewardEvent`: unique domain-event ID and reward type, preventing
   the same expense, group, or payment from awarding XP twice.
3. `AchievementUnlock`: pin ID, person ID, and unlock date.

A small `RewardEngine` receives successful ledger events. Views display its
results but never calculate or write XP directly.

## Delivery order

1. Add persistence, reward rules, duplicate protection, and unit tests.
2. Add the compact Profile progress card and three-pin shelf.
3. Add the XP toast and first-pin card with Reduce Motion behaviour.

## Explicitly deferred

- Leaderboards, public profiles, streaks, quests, challenges, group awards.
- Big Spender and other comparative awards.
- More than three levels or three pins.
- Push notifications about XP or achievements.

## Acceptance checks

- Reopening, editing, deleting, or recreating a view cannot duplicate XP.
- The same domain event cannot reward twice after relaunch.
- Turning progression off hides it without affecting any ledger function.
- Nothing rewards spending more, carrying debt, or paying faster than friends.
- The feature adds no extra step to expense creation or settlement.
