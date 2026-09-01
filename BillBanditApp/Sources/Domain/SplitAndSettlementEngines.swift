import Foundation

enum ExpenseValidationError: Error, Equatable {
    case negativeAmount
    case noIncludedParticipants
    case duplicateParticipants
    case exactAmountsDoNotMatchTotal(expected: Money, actual: Money)
    case percentagesDoNotSumTo100(actual: Decimal)
    case invalidShares
    case splitDefinitionsDoNotMatchParticipants
}

enum ExpenseValidation {
    static func validate(_ expense: Expense) throws {
        if expense.amount.minorUnits < 0 {
            throw ExpenseValidationError.negativeAmount
        }
        if expense.includedParticipants.isEmpty {
            throw ExpenseValidationError.noIncludedParticipants
        }
        if Set(expense.includedParticipants).count != expense.includedParticipants.count {
            throw ExpenseValidationError.duplicateParticipants
        }

        let included = Set(expense.includedParticipants)
        switch expense.splitMethod {
        case .equal, .payerOnly:
            return
        case .exactAmounts(let amounts):
            guard Set(amounts.keys) == included else {
                throw ExpenseValidationError.splitDefinitionsDoNotMatchParticipants
            }
            guard amounts.values.allSatisfy({ $0.minorUnits >= 0 }) else {
                throw ExpenseValidationError.negativeAmount
            }
            let actual = amounts.values.reduce(.zero(currency: expense.amount.currency), +)
            guard actual == expense.amount else {
                throw ExpenseValidationError.exactAmountsDoNotMatchTotal(expected: expense.amount, actual: actual)
            }
        case .percentages(let percentages):
            guard Set(percentages.keys) == included else {
                throw ExpenseValidationError.splitDefinitionsDoNotMatchParticipants
            }
            guard percentages.values.allSatisfy({ $0 >= 0 }) else {
                throw ExpenseValidationError.negativeAmount
            }
            let actual = percentages.values.reduce(Decimal(0), +)
            guard actual == Decimal(100) else {
                throw ExpenseValidationError.percentagesDoNotSumTo100(actual: actual)
            }
        case .shares(let shares):
            guard Set(shares.keys) == included else {
                throw ExpenseValidationError.splitDefinitionsDoNotMatchParticipants
            }
            guard shares.values.allSatisfy({ $0 > 0 }) else {
                throw ExpenseValidationError.invalidShares
            }
        }
    }
}

enum SplitEngine {
    static func splits(for expense: Expense) throws -> [ExpenseSplit] {
        try ExpenseValidation.validate(expense)

        switch expense.splitMethod {
        case .equal:
            return allocate(
                total: expense.amount,
                weights: expense.includedParticipants.map { ($0, Decimal(1)) }
            )
        case .exactAmounts(let amounts):
            return amounts
                .map { ExpenseSplit(participantId: $0.key, amount: $0.value) }
                .sorted { $0.participantId < $1.participantId }
        case .percentages(let percentages):
            return allocate(
                total: expense.amount,
                weights: percentages.map { ($0.key, $0.value) }
            )
        case .shares(let shares):
            return allocate(
                total: expense.amount,
                weights: shares.map { ($0.key, Decimal($0.value)) }
            )
        case .payerOnly:
            return [ExpenseSplit(participantId: expense.paidBy, amount: expense.amount)]
        }
    }

    private static func allocate(total: Money, weights: [(ParticipantID, Decimal)]) -> [ExpenseSplit] {
        let orderedWeights = weights.sorted { lhs, rhs in
            lhs.0 < rhs.0
        }
        let totalWeight = orderedWeights.reduce(Decimal(0)) { $0 + $1.1 }

        struct Claim {
            var participantId: ParticipantID
            var floorMinorUnits: Int
            var remainder: Decimal
        }

        var claims = orderedWeights.map { participantId, weight in
            let exact = Decimal(total.minorUnits) * weight / totalWeight
            let floor = floorDecimalToInt(exact)
            return Claim(participantId: participantId, floorMinorUnits: floor, remainder: exact - Decimal(floor))
        }

        var remaining = total.minorUnits - claims.reduce(0) { $0 + $1.floorMinorUnits }
        let remainderOrder = claims.indices.sorted { lhs, rhs in
            let left = claims[lhs]
            let right = claims[rhs]
            if left.remainder == right.remainder {
                return left.participantId < right.participantId
            }
            return left.remainder > right.remainder
        }

        for index in remainderOrder where remaining > 0 {
            claims[index].floorMinorUnits += 1
            remaining -= 1
        }

        return claims
            .map {
                ExpenseSplit(
                    participantId: $0.participantId,
                    amount: Money(minorUnits: $0.floorMinorUnits, currency: total.currency)
                )
            }
            .sorted { $0.participantId < $1.participantId }
    }

    private static func floorDecimalToInt(_ decimal: Decimal) -> Int {
        NSDecimalNumber(decimal: decimal)
            .rounding(
                accordingToBehavior: NSDecimalNumberHandler(
                    roundingMode: .down,
                    scale: 0,
                    raiseOnExactness: false,
                    raiseOnOverflow: false,
                    raiseOnUnderflow: false,
                    raiseOnDivideByZero: true
                )
            )
            .intValue
    }
}

enum SettlementEngine {
    static func summary(expenses: [Expense], settlements: [Settlement] = []) throws -> SettlementSummary {
        var paid: [ParticipantID: Money] = [:]
        var owed: [ParticipantID: Money] = [:]
        var netMinorUnits: [ParticipantID: Int] = [:]
        let currency = expenses.first?.amount.currency ?? settlements.first?.amount.currency ?? .inr

        func ensure(_ participantId: ParticipantID) {
            paid[participantId, default: .zero(currency: currency)] = paid[participantId, default: .zero(currency: currency)]
            owed[participantId, default: .zero(currency: currency)] = owed[participantId, default: .zero(currency: currency)]
            netMinorUnits[participantId, default: 0] = netMinorUnits[participantId, default: 0]
        }

        for expense in expenses {
            ensure(expense.paidBy)
            paid[expense.paidBy, default: .zero(currency: expense.amount.currency)] =
                paid[expense.paidBy, default: .zero(currency: expense.amount.currency)] + expense.amount
            netMinorUnits[expense.paidBy, default: 0] += expense.amount.minorUnits

            for split in try SplitEngine.splits(for: expense) {
                ensure(split.participantId)
                owed[split.participantId, default: .zero(currency: split.amount.currency)] =
                    owed[split.participantId, default: .zero(currency: split.amount.currency)] + split.amount
                netMinorUnits[split.participantId, default: 0] -= split.amount.minorUnits
            }
        }

        for settlement in settlements {
            ensure(settlement.from)
            ensure(settlement.to)
            netMinorUnits[settlement.from, default: 0] += settlement.amount.minorUnits
            netMinorUnits[settlement.to, default: 0] -= settlement.amount.minorUnits
        }

        let balances = netMinorUnits.keys.sorted().map { participantId in
            ParticipantBalance(
                participantId: participantId,
                paid: paid[participantId, default: .zero(currency: currency)],
                owed: owed[participantId, default: .zero(currency: currency)],
                net: Money(minorUnits: netMinorUnits[participantId, default: 0], currency: currency)
            )
        }

        return SettlementSummary(
            balances: balances,
            simplifiedInstructions: simplifiedInstructions(from: netMinorUnits, currency: currency)
        )
    }

    private static func simplifiedInstructions(
        from netMinorUnits: [ParticipantID: Int],
        currency: Currency
    ) -> [SettlementInstruction] {
        var debtors = netMinorUnits
            .filter { $0.value < 0 }
            .map { (participantId: $0.key, amount: -$0.value) }
            .sorted { lhs, rhs in
                if lhs.amount == rhs.amount { return lhs.participantId < rhs.participantId }
                return lhs.amount > rhs.amount
            }

        var creditors = netMinorUnits
            .filter { $0.value > 0 }
            .map { (participantId: $0.key, amount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.amount == rhs.amount { return lhs.participantId < rhs.participantId }
                return lhs.amount > rhs.amount
            }

        var debtorIndex = 0
        var creditorIndex = 0
        var instructions: [SettlementInstruction] = []

        while debtorIndex < debtors.count, creditorIndex < creditors.count {
            let amount = min(debtors[debtorIndex].amount, creditors[creditorIndex].amount)
            if amount > 0 {
                instructions.append(
                    SettlementInstruction(
                        from: debtors[debtorIndex].participantId,
                        to: creditors[creditorIndex].participantId,
                        amount: Money(minorUnits: amount, currency: currency)
                    )
                )
            }
            debtors[debtorIndex].amount -= amount
            creditors[creditorIndex].amount -= amount
            if debtors[debtorIndex].amount == 0 { debtorIndex += 1 }
            if creditors[creditorIndex].amount == 0 { creditorIndex += 1 }
        }

        return instructions
    }
}
