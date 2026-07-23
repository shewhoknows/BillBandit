# BillBandit — Subtle Gamification Plan

## Product intent

Gamification should make good shared-ledger habits feel satisfying without making
debt, spending, or friendships competitive. BillBandit rewards clarity,
follow-through, and useful participation—not how much somebody spends.

Core rules:

- Private by default. A person's level and pin shelf belong to them unless they
  deliberately share a trip recap.
- Never rank people by debt, repayment speed, or total lifetime spend.
- No streak loss, shame states, countdown anxiety, or feature gates.
- Award XP from idempotent ledger events so reopening a screen or syncing a fact
  cannot create duplicate rewards.
- Cap repeatable actions, especially edits, to prevent farming.
- Keep celebration brief: a compact toast after routine actions and one richer
  pin card only when an achievement is first unlocked.
- Honour Reduce Motion with a fade and haptic in place of travel, bounce, or
  particles.

## Progression

Levels are cosmetic titles shown on Profile beside a small progress ring. They
unlock pin-shelf treatments and recap flourishes, never core app capability.

| Level | Title | Lifetime XP |
|---:|---|---:|
| 1 | Lookout | 0 |
| 2 | Crew Scout | 50 |
| 3 | Ledger Keeper | 150 |
| 4 | Balance Ranger | 350 |
| 5 | Crew Captain | 650 |
| 6 | Master Bandit | 1,000 |

Suggested event rewards:

| Healthy action | XP | Guardrail |
|---|---:|---|
| Log an expense | 5 | One reward per expense ID |
| First expense bonus | 15 | One lifetime bonus |
| Create a group | 8 | Group must contain another member |
| Add a friend | 3 | First connection to that person only |
| Record a payment | 12 | One reward per settlement ID |
| Fully settle a group | 20 | Award once per newly reached zero-balance state |
| Make a meaningful expense correction | 2 | Maximum three rewarded edits per week |
| Use a new split method | 6 | Once for each of equal/exact/%/shares |
| Attach a receipt (future) | 4 | One reward per expense |

There is deliberately no amount multiplier. A ₹50 contribution and a ₹5,000
contribution can be equally useful ledger behaviour.

## Achievement pins

Pins use a new raccoon-friends badge family rather than altering the six locked
in-app mascot poses. Each is a cream-and-cobalt circular enamel-style pin with a
distinct raccoon friend, prop, or expression and a Courier Prime label.

| Pin | Unlock | Raccoon-friend art direction |
|---|---|---|
| Initiative Taker | Log a first expense | Raccoon holding a tiny receipt flag |
| Settler Scion | Be first to settle a balance in a group | Raccoon with a polished coin shield |
| High on Details | Correct or enrich an expense | Raccoon with magnifying glass and pencil |
| Crew Founder | Create a first group with friends | Three raccoon heads in a clubhouse crest |
| Quick Draw | Pay within 24 hours of a balance appearing | Raccoon sliding a coin across a table |
| Split Personality | Use all four split methods | Four expressive raccoon faces in quadrants |
| Peacekeeper | Record five valid settlements | Raccoons shaking paws over a clean ledger |
| Ledger Legend | Log 25 expenses | Raccoon carrying a tall receipt scroll |
| Round Robin | Everyone in a group has paid at least once | Raccoon crew around a circular table |
| No Loose Ends | Close a group with every balance at zero | Raccoon tying a neat bow around a receipt |
| Clean Slate | Reach zero across every active group | Raccoon wiping a cobalt slate clean |
| Big Spender | Largest total payer in a completed group | Raccoon wearing a generous-host sash |
| Receipt Raccoon | Attach a first receipt (future) | Raccoon photographing a receipt |

“Big Spender” is a group-local, end-of-trip crew award based on the amount a
person fronted—not an always-on global leaderboard and not a prompt to consume
more. It appears only after a group is explicitly completed.

## Experience placement

- **Profile:** level title, XP-to-next-level ring, and a compact pin shelf. Locked
  pins show a line-art silhouette and their transparent unlock requirement.
- **After an action:** small bottom toast, for example `+12 XP · payment recorded`.
  It must not delay navigation or replace the existing success feedback.
- **First pin unlock:** a 1.5-second branded card with the pin, name, and one-line
  reason. Tap or time-out dismisses it.
- **Group completion:** optional “crew awards” receipt appended to the trip invoice
  with positive, non-ranking moments such as Initiative Taker and Round Robin.
- **Activity:** achievement unlocks may appear as low-priority ledger rows and can
  be hidden through a Profile preference.

## Data and reward engine

Add four small persistence concepts rather than embedding reward logic in views:

1. `UserProgress`: person ID, lifetime XP, current level, opt-in preference.
2. `AchievementDefinition`: static ID, title, description, scope, and artwork key.
3. `AchievementUnlock`: achievement ID, person ID, optional group ID, timestamp.
4. `ProcessedRewardEvent`: immutable activity/event ID and awarded rules, enforcing
   exactly-once processing across relaunches and future sync.

A central `RewardEngine` consumes domain events after successful SwiftData saves.
It calculates XP, evaluates achievements, writes unlocks transactionally, and
returns presentation-safe reward results to the UI. Views never calculate XP.
Edits compare a normalized before/after snapshot and only reward a material
change; create/delete loops cannot earn additional rewards.

## Rollout

### G1 — Progress engine

- Add the four persistence concepts and idempotent `RewardEngine`.
- Ship XP, level ring, opt-out, and six individual pins: Initiative Taker,
  Settler Scion, High on Details, Crew Founder, Split Personality, Peacekeeper.
- Unit-test duplicate events, undo/delete cycles, weekly edit caps, level
  boundaries, and Reduce Motion presentation paths.

### G2 — Pin collection and delight

- Produce pin artwork at 48, 96, and 256 points with light/dark contrast checks.
- Add Profile pin shelf, compact XP toast, and first-unlock card.
- Add Ledger Legend, Clean Slate, No Loose Ends, and Receipt Raccoon when receipt
  capture exists.

### G3 — End-of-trip crew recap

- Add an explicit Complete Group action, recap receipt, Round Robin, and the
  group-local Big Spender contribution award.
- Allow export/share only after every participant's private progress stays hidden.
- Tune frequency using healthy-ledger metrics rather than engagement time.

## Success and safety measures

Measure median settlement time, percentage of completed zero-balance groups,
expense-logging completeness, correction rate, reminder opt-outs, achievement
opt-outs, and reward-dismissal frequency. Do not optimize for increased spend,
increased debt, notification opens, or compulsive session count.

Acceptance criteria for the first release:

- An event can never grant XP twice, including after relaunch and future sync.
- Deleting and recreating the same logical action cannot farm XP.
- A user can disable all progress UI without affecting ledger functionality.
- No screen publicly ranks debt, speed, or lifetime spend.
- Every reward animation has a Reduce Motion alternative.
- All pin names and unlock requirements remain understandable without the art.
