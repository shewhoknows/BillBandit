import Foundation
import SwiftData

struct RewardOutcome: Identifiable {
    let id = UUID()
    let action: RewardAction
    let xpAwarded: Int
    let previousXP: Int
    let totalXP: Int
    let unlockedAchievements: [StarterAchievement]

    var previousLevel: ProgressLevel { ProgressLevel.level(for: previousXP) }
    var currentLevel: ProgressLevel { ProgressLevel.level(for: totalXP) }
    var didLevelUp: Bool { previousLevel != currentLevel }
}

/// Exactly-once rewards backed by immutable domain event IDs. Call this before
/// the same ModelContext save as the expense/group/settlement it rewards.
enum RewardEngine {
    @MainActor
    static func award(action: RewardAction, eventID: UUID, personID: UUID,
                      context: ModelContext) throws -> RewardOutcome? {
        let eventKey = "\(personID.uuidString):\(action.rawValue):\(eventID.uuidString)"
        var eventFetch = FetchDescriptor<ProcessedRewardEvent>(
            predicate: #Predicate { $0.key == eventKey }
        )
        eventFetch.fetchLimit = 1
        guard try context.fetch(eventFetch).isEmpty else { return nil }

        var progressFetch = FetchDescriptor<UserProgress>(
            predicate: #Predicate { $0.personID == personID }
        )
        progressFetch.fetchLimit = 1
        let progress: UserProgress
        if let existing = try context.fetch(progressFetch).first {
            progress = existing
        } else {
            progress = UserProgress(personID: personID)
            context.insert(progress)
        }

        guard progress.isEnabled else {
            context.insert(ProcessedRewardEvent(eventID: eventID, personID: personID,
                                                action: action, awardedXP: 0))
            return nil
        }

        let previousXP = progress.lifetimeXP
        progress.lifetimeXP += action.xp
        context.insert(ProcessedRewardEvent(eventID: eventID, personID: personID,
                                            action: action, awardedXP: action.xp))

        let achievement = action.starterAchievement
        let unlockKey = "\(personID.uuidString):\(achievement.rawValue)"
        var unlockFetch = FetchDescriptor<AchievementUnlock>(
            predicate: #Predicate { $0.key == unlockKey }
        )
        unlockFetch.fetchLimit = 1
        var unlocked = [StarterAchievement]()
        if try context.fetch(unlockFetch).isEmpty {
            context.insert(AchievementUnlock(achievement: achievement, personID: personID))
            unlocked.append(achievement)
        }

        return RewardOutcome(action: action, xpAwarded: action.xp,
                             previousXP: previousXP, totalXP: progress.lifetimeXP,
                             unlockedAchievements: unlocked)
    }
}

/// Non-XP milestone pins. These stay idempotent through AchievementUnlock's
/// person + achievement key and can be evaluated after the related ledger fact
/// is inserted, in the same save transaction.
enum AchievementEngine {
    @MainActor
    @discardableResult
    static func unlock(_ achievement: StarterAchievement, personID: UUID,
                       context: ModelContext) throws -> Bool {
        let key = "\(personID.uuidString):\(achievement.rawValue)"
        var fetch = FetchDescriptor<AchievementUnlock>(predicate: #Predicate { $0.key == key })
        fetch.fetchLimit = 1
        guard try context.fetch(fetch).isEmpty else { return false }
        context.insert(AchievementUnlock(achievement: achievement, personID: personID))
        return true
    }

    @MainActor
    static func evaluateExpenseMilestones(personID: UUID, context: ModelContext) throws {
        let activities = try context.fetch(FetchDescriptor<ActivityItem>())
        let actedExpenseIDs = Set(activities.compactMap { item -> UUID? in
            guard item.actorID == personID,
                  item.kind == .expenseAdded || item.kind == .expenseEdited else { return nil }
            return item.refID
        })
        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let actedExpenses = expenses.filter { actedExpenseIDs.contains($0.id) }
        let modes = Set(actedExpenses.flatMap(\.splits).map(\.mode))
        if modes.count >= 3 {
            try unlock(.splitPersonality, personID: personID, context: context)
        }

        let groups = try context.fetch(FetchDescriptor<Group>())
        let isTopPayer = groups.contains { group in
            let paidByPerson = Dictionary(grouping: group.expenses.compactMap { expense -> (UUID, Decimal)? in
                guard let payerID = expense.paidBy?.id else { return nil }
                return (payerID, Money.whole(expense.amount))
            }, by: { $0.0 }).mapValues { entries in
                entries.reduce(Decimal.zero) { $0 + $1.1 }
            }
            guard let currentTotal = paidByPerson[personID], currentTotal > 0 else { return false }
            return paidByPerson.filter { $0.key != personID }.allSatisfy { currentTotal > $0.value }
        }
        if isTopPayer {
            try unlock(.bigSpender, personID: personID, context: context)
        }
    }

    @MainActor
    static func evaluateSettlementMilestone(personID: UUID, context: ModelContext) throws {
        let activities = try context.fetch(FetchDescriptor<ActivityItem>())
        let settlementCount = activities.filter {
            $0.actorID == personID && $0.kind == .settlementRecorded
        }.count
        if settlementCount >= 5 {
            try unlock(.peacekeeper, personID: personID, context: context)
        }
    }
}

/// Adapters: turn SwiftData facts into pure engine snapshots and compute balances.
enum BalanceMath {

    static func snapshot(_ expense: Expense) -> ExpenseSnapshot? {
        guard let payer = expense.paidBy?.id else { return nil }
        var rawShares = [UUID: Decimal]()
        var order = [UUID]()
        for s in expense.splits {
            guard let pid = s.person?.id else { continue }
            if rawShares[pid] == nil { order.append(pid) }
            rawShares[pid, default: 0] += s.computedAmount
        }
        let total = Money.whole(expense.amount)
        let inputs = order.map { SplitInput(personID: $0, mode: .shares, value: rawShares[$0] ?? 0) }
        let shares = (try? SplitEngine.compute(total: total, inputs: inputs)) ?? rawShares.mapValues(Money.whole)
        return ExpenseSnapshot(paidBy: payer, total: total, shares: shares)
    }

    static func snapshot(_ settlement: Settlement) -> SettlementSnapshot? {
        guard let from = settlement.from?.id, let to = settlement.to?.id else { return nil }
        return SettlementSnapshot(from: from, to: to, amount: Money.whole(settlement.amount))
    }

    /// Net balance per person within one group (positive = owed).
    static func nets(in group: Group) -> [UUID: Decimal] {
        BalanceEngine.nets(
            expenses: group.expenses.compactMap(snapshot),
            settlements: group.settlements.compactMap(snapshot)
        )
    }

    /// Net balance per person across everything (all groups + ungrouped facts).
    static func globalNets(groups: [Group], looseExpenses: [Expense], looseSettlements: [Settlement]) -> [UUID: Decimal] {
        let expenses = groups.flatMap(\.expenses) + looseExpenses
        let settlements = groups.flatMap(\.settlements) + looseSettlements
        return BalanceEngine.nets(
            expenses: expenses.compactMap(snapshot),
            settlements: settlements.compactMap(snapshot)
        )
    }

    /// Pairwise balance between the current user and each other person
    /// (positive = they owe you). Only direct facts count: expenses you paid
    /// (their share), expenses they paid (your share), settlements between you.
    static func pairwiseNets(you: Person, expenses: [Expense], settlements: [Settlement]) -> [UUID: Decimal] {
        var net = [UUID: Decimal]()
        for e in expenses {
            guard let snapshot = snapshot(e) else { continue }
            let payer = snapshot.paidBy
            if payer == you.id {
                for (person, share) in snapshot.shares where person != you.id {
                    net[person, default: 0] += share
                }
            } else if let yourShare = snapshot.shares[you.id] {
                net[payer, default: 0] -= yourShare
            }
        }
        for s in settlements {
            guard let from = s.from?.id, let to = s.to?.id else { continue }
            let amount = Money.whole(s.amount)
            if from == you.id { net[to, default: 0] += amount }
            else if to == you.id { net[from, default: 0] -= amount }
        }
        return net.mapValues(Money.whole)
    }

    /// Transfers that settle a group (respecting its simplifyDebts flag).
    static func settleUpPlan(for group: Group) -> [DebtTransfer] {
        let nets = nets(in: group)
        if group.simplifyDebts {
            return BalanceEngine.simplify(nets)
        }
        // No simplification: every debtor pays each creditor proportionally…
        // v1 keeps it simple: greedy is only applied when the flag is on;
        // otherwise return per-debtor payments against creditors in order.
        var transfers = [DebtTransfer]()
        let epsilon = Decimal(string: "0.5")!
        var creditors = nets.filter { $0.value > epsilon }.sorted { $0.key.uuidString < $1.key.uuidString }
        for (debtor, amount) in nets where amount < -epsilon {
            var remaining = -amount
            for i in creditors.indices where remaining > epsilon {
                let pay = Money.whole(min(remaining, creditors[i].value))
                guard pay > 0 else { continue }
                transfers.append(DebtTransfer(from: debtor, to: creditors[i].key, amount: pay))
                creditors[i].value -= pay
                remaining -= pay
            }
        }
        return transfers
    }

    static func deletingWouldCreateOverpayment(_ expense: Expense) -> Bool {
        guard let group = expense.group, !group.settlements.isEmpty else { return false }
        let remainingExpenses = group.expenses
            .filter { $0.id != expense.id }
            .compactMap(snapshot)
        return BalanceEngine.hasOverpayment(
            expenses: remainingExpenses,
            settlements: group.settlements.compactMap(snapshot)
        )
    }
}
