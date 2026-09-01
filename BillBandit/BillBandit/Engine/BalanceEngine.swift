import Foundation

/// Pure snapshots of the ledger facts the balance engine works on —
/// adapters from SwiftData models live in `BalanceMath+SwiftData.swift`.
struct ExpenseSnapshot {
    let paidBy: UUID
    let total: Decimal
    let shares: [UUID: Decimal] // personID -> computed share
}

struct SettlementSnapshot {
    let from: UUID
    let to: UUID
    let amount: Decimal
}

/// A single transfer that settles part of the debt graph.
struct DebtTransfer: Equatable {
    let from: UUID
    let to: UUID
    let amount: Decimal
}

/// Balance math. Positive net = the person is owed money; negative = they owe.
enum BalanceEngine {

    /// Net balance per person across the given expenses and settlements.
    /// Payer gets +total; each participant gets −their share; a settlement
    /// moves `amount` from `from`'s debt to `to`'s credit (from += , to −=).
    static func nets(expenses: [ExpenseSnapshot], settlements: [SettlementSnapshot]) -> [UUID: Decimal] {
        var net = [UUID: Decimal]()
        for e in expenses {
            net[e.paidBy] = (net[e.paidBy] ?? 0) + e.total
            for (person, share) in e.shares {
                net[person] = (net[person] ?? 0) - share
            }
        }
        for s in settlements {
            net[s.from] = (net[s.from] ?? 0) + s.amount
            net[s.to] = (net[s.to] ?? 0) - s.amount
        }
        return net.mapValues(Money.whole)
    }

    /// Net for one person within the given fact set.
    static func net(of person: UUID, expenses: [ExpenseSnapshot], settlements: [SettlementSnapshot]) -> Decimal {
        nets(expenses: expenses, settlements: settlements)[person] ?? 0
    }

    /// Outstanding amount for a selected payment direction in a settlement plan.
    /// Returns nil when the pair has no payment to make in that direction.
    static func suggestedPayment(from: UUID, to: UUID, in transfers: [DebtTransfer]) -> Decimal? {
        let amount = transfers
            .filter { $0.from == from && $0.to == to }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let rounded = Money.whole(amount)
        return rounded > 0 ? rounded : nil
    }

    /// True when recorded payments have pushed at least one participant past
    /// their expense-only obligation, creating a reverse/refund balance.
    static func hasOverpayment(expenses: [ExpenseSnapshot], settlements: [SettlementSnapshot]) -> Bool {
        let obligations = nets(expenses: expenses, settlements: [])
        let afterPayments = nets(expenses: expenses, settlements: settlements)
        let people = Set(obligations.keys).union(afterPayments.keys)
        return people.contains { person in
            let before = obligations[person] ?? 0
            let after = afterPayments[person] ?? 0
            if before == 0 { return after != 0 }
            return (before > 0 && after < 0) || (before < 0 && after > 0)
        }
    }

    /// Min-transaction simplification: greedily match the largest debtor with the
    /// largest creditor until everyone is within half a cent of zero.
    static func simplify(_ nets: [UUID: Decimal]) -> [DebtTransfer] {
        var creditors = nets.filter { $0.value > 0 }.map { (id: $0.key, amt: $0.value) }
        var debtors   = nets.filter { $0.value < 0 }.map { (id: $0.key, amt: -$0.value) }
        var transfers = [DebtTransfer]()
        let epsilon = Decimal(string: "0.5")!

        while let cMax = creditors.max(by: { $0.amt < $1.amt }),
              let dMax = debtors.max(by: { $0.amt < $1.amt }),
              cMax.amt > epsilon, dMax.amt > epsilon {
            let pay = Money.whole(min(cMax.amt, dMax.amt))
            transfers.append(DebtTransfer(from: dMax.id, to: cMax.id, amount: pay))
            creditors = creditors.map { $0.id == cMax.id ? ($0.id, Money.whole($0.amt - pay)) : $0 }.filter { $0.1 > epsilon }
            debtors   = debtors.map   { $0.id == dMax.id ? ($0.id, Money.whole($0.amt - pay)) : $0 }.filter { $0.1 > epsilon }
        }
        return transfers
    }
}
