import Foundation

/// One person's split input for an expense.
struct SplitInput: Equatable {
    let personID: UUID
    let mode: SplitMode
    /// Ignored for `.equal`; otherwise exact amount / percent / share count.
    let value: Decimal

    init(personID: UUID, mode: SplitMode = .equal, value: Decimal = 0) {
        self.personID = personID
        self.mode = mode
        self.value = value
    }
}

enum SplitError: Error, Equatable {
    case empty
    case nonPositiveTotal
    case exactMismatch(expected: Decimal, got: Decimal)
    case percentNot100(Decimal)
    case nonPositiveShares
}

/// Computes whole-rupee per-person amounts that sum exactly to the rounded expense total.
enum SplitEngine {

    static func compute(total: Decimal, inputs: [SplitInput]) throws -> [UUID: Decimal] {
        guard !inputs.isEmpty else { throw SplitError.empty }
        guard total > 0 else { throw SplitError.nonPositiveTotal }
        guard let mode = inputs.first?.mode else { throw SplitError.empty }
        let total = Money.whole(total)
        guard total > 0 else { throw SplitError.nonPositiveTotal }

        switch mode {
        case .equal:   return equal(total: total, ids: inputs.map(\.personID))
        case .exact:   return try exact(total: total, inputs: inputs)
        case .percent: return try percent(total: total, inputs: inputs)
        case .shares:  return try shares(total: total, inputs: inputs)
        }
    }

    /// Equal split; leftover rupees go one-by-one to the first members (deterministic).
    private static func equal(total: Decimal, ids: [UUID]) -> [UUID: Decimal] {
        let n = Decimal(ids.count)
        let base = Money.floorWhole(total / n)
        var result = [UUID: Decimal]()
        for id in ids { result[id] = base }
        distributeRemainder(total: total, into: &result, order: ids)
        return result
    }

    /// Exact amounts; must already sum to the total.
    private static func exact(total: Decimal, inputs: [SplitInput]) throws -> [UUID: Decimal] {
        var result = [UUID: Decimal]()
        for i in inputs { result[i.personID] = Money.whole(i.value) }
        let sum = result.values.reduce(0, +)
        guard sum == total else { throw SplitError.exactMismatch(expected: total, got: sum) }
        return result
    }

    /// Percent of total; percents must sum to 100. Rounding drift goes to the first member.
    private static func percent(total: Decimal, inputs: [SplitInput]) throws -> [UUID: Decimal] {
        let pctSum = inputs.reduce(0 as Decimal) { $0 + $1.value }
        guard pctSum == 100 else { throw SplitError.percentNot100(pctSum) }
        var result = [UUID: Decimal]()
        for i in inputs { result[i.personID] = Money.whole(total * i.value / 100) }
        distributeRemainder(total: total, into: &result, order: inputs.map(\.personID))
        return result
    }

    /// Proportional by share counts. Rounding drift goes to the first member.
    private static func shares(total: Decimal, inputs: [SplitInput]) throws -> [UUID: Decimal] {
        let shareSum = inputs.reduce(0 as Decimal) { $0 + $1.value }
        guard shareSum > 0 else { throw SplitError.nonPositiveShares }
        var result = [UUID: Decimal]()
        for i in inputs { result[i.personID] = Money.whole(total * i.value / shareSum) }
        distributeRemainder(total: total, into: &result, order: inputs.map(\.personID))
        return result
    }

    /// Nudge people by complete rupees until the split sums exactly to the rounded total.
    private static func distributeRemainder(total: Decimal, into result: inout [UUID: Decimal], order: [UUID]) {
        let drift = total - result.values.reduce(0, +)
        guard drift != 0 else { return }
        let step: Decimal = drift > 0 ? Decimal(1) : Decimal(-1)
        var rupeesDrift = Int(truncating: NSDecimalNumber(decimal: drift))
        var idx = 0
        while rupeesDrift != 0 {
            let id = order[idx % order.count]
            result[id] = Money.whole((result[id] ?? 0) + step)
            rupeesDrift -= Int(truncating: NSDecimalNumber(decimal: step))
            idx += 1
        }
    }
}
