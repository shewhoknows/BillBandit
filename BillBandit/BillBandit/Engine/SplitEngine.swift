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
    case negativeComponent
}

/// Computes per-person amounts in the currency's minor units (paise for INR,
/// whole dong for VND) that sum exactly to the rounded expense total.
enum SplitEngine {

    static func compute(total: Decimal, inputs: [SplitInput], exponent: Int = 2) throws -> [UUID: Decimal] {
        guard !inputs.isEmpty else { throw SplitError.empty }
        guard total > 0 else { throw SplitError.nonPositiveTotal }
        guard let mode = inputs.first?.mode else { throw SplitError.empty }
        let total = Money.rounded(total, exponent: exponent)
        guard total > 0 else { throw SplitError.nonPositiveTotal }
        // Equal mode ignores input values; all other modes must never create a
        // negative person share, even when signed inputs sum to a valid total.
        if mode != .equal && inputs.contains(where: { $0.value < 0 }) {
            throw SplitError.negativeComponent
        }

        switch mode {
        case .equal:   return equal(total: total, ids: inputs.map(\.personID), exponent: exponent)
        case .exact:   return try exact(total: total, inputs: inputs, exponent: exponent)
        case .percent: return try percent(total: total, inputs: inputs, exponent: exponent)
        case .shares:  return try shares(total: total, inputs: inputs, exponent: exponent)
        }
    }

    /// Equal split; leftover minor units go one-by-one to the first members (deterministic).
    private static func equal(total: Decimal, ids: [UUID], exponent: Int) -> [UUID: Decimal] {
        let n = Decimal(ids.count)
        let base = Money.floored(total / n, exponent: exponent)
        var result = [UUID: Decimal]()
        for id in ids { result[id] = base }
        distributeRemainder(total: total, into: &result, order: ids, exponent: exponent)
        return result
    }

    /// Exact amounts; must already sum to the total.
    private static func exact(total: Decimal, inputs: [SplitInput], exponent: Int) throws -> [UUID: Decimal] {
        var result = [UUID: Decimal]()
        for i in inputs { result[i.personID] = Money.rounded(i.value, exponent: exponent) }
        let sum = result.values.reduce(0, +)
        guard sum == total else { throw SplitError.exactMismatch(expected: total, got: sum) }
        return result
    }

    /// Percent of total; percents must sum to 100. Rounding drift goes to the first member.
    private static func percent(total: Decimal, inputs: [SplitInput], exponent: Int) throws -> [UUID: Decimal] {
        let pctSum = inputs.reduce(0 as Decimal) { $0 + $1.value }
        guard pctSum == 100 else { throw SplitError.percentNot100(pctSum) }
        var result = [UUID: Decimal]()
        for i in inputs { result[i.personID] = Money.rounded(total * i.value / 100, exponent: exponent) }
        distributeRemainder(total: total, into: &result, order: inputs.map(\.personID), exponent: exponent)
        return result
    }

    /// Proportional by share counts. Rounding drift goes to the first member.
    private static func shares(total: Decimal, inputs: [SplitInput], exponent: Int) throws -> [UUID: Decimal] {
        let shareSum = inputs.reduce(0 as Decimal) { $0 + $1.value }
        guard shareSum > 0 else { throw SplitError.nonPositiveShares }
        var result = [UUID: Decimal]()
        for i in inputs { result[i.personID] = Money.rounded(total * i.value / shareSum, exponent: exponent) }
        distributeRemainder(total: total, into: &result, order: inputs.map(\.personID), exponent: exponent)
        return result
    }

    /// Nudge people by one minor unit at a time until the split sums exactly to the rounded total.
    private static func distributeRemainder(total: Decimal, into result: inout [UUID: Decimal], order: [UUID], exponent: Int) {
        let drift = total - result.values.reduce(0, +)
        guard drift != 0 else { return }
        let unit = Money.minorUnit(exponent: exponent)
        let step: Decimal = drift > 0 ? unit : -unit
        var unitsDrift = abs(Int(truncating: NSDecimalNumber(decimal: Money.whole(drift / unit))))
        var idx = 0
        while unitsDrift > 0 {
            let id = order[idx % order.count]
            result[id] = Money.rounded((result[id] ?? 0) + step, exponent: exponent)
            unitsDrift -= 1
            idx += 1
        }
    }
}
