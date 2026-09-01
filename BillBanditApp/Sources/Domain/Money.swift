import Foundation

struct Currency: Hashable, Codable, Sendable {
    var code: String
    var minorUnitExponent: Int

    init(code: String = "INR", minorUnitExponent: Int = 2) {
        self.code = code.uppercased()
        self.minorUnitExponent = minorUnitExponent
    }

    static let inr = Currency()

    var minorUnitsPerMajorUnit: Int {
        var scale = 1
        for _ in 0..<minorUnitExponent {
            scale *= 10
        }
        return scale
    }
}

struct Money: Hashable, Codable, Comparable, Sendable {
    var minorUnits: Int
    var currency: Currency

    init(minorUnits: Int, currency: Currency = .inr) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    init(apiMajorUnitNumber number: Double, currency: Currency = .inr) {
        self.init(majorUnits: Decimal(number), currency: currency)
    }

    init(majorUnits: Decimal, currency: Currency = .inr) {
        let scaled = majorUnits * Decimal(currency.minorUnitsPerMajorUnit)
        let rounded = NSDecimalNumber(decimal: scaled).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: true
            )
        )
        self.init(minorUnits: rounded.intValue, currency: currency)
    }

    static func zero(currency: Currency = .inr) -> Money {
        Money(minorUnits: 0, currency: currency)
    }

    var majorUnits: Decimal {
        Decimal(minorUnits) / Decimal(currency.minorUnitsPerMajorUnit)
    }

    var apiMajorUnitNumber: Double {
        NSDecimalNumber(decimal: majorUnits).doubleValue
    }

    func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        formatter.minimumFractionDigits = currency.minorUnitExponent
        formatter.maximumFractionDigits = currency.minorUnitExponent
        formatter.locale = locale
        return formatter.string(from: NSDecimalNumber(decimal: majorUnits)) ?? "\(currency.code) \(majorUnits)"
    }

    static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.assertSameCurrency(as: rhs)
        return lhs.minorUnits < rhs.minorUnits
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        lhs.assertSameCurrency(as: rhs)
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        lhs.assertSameCurrency(as: rhs)
        return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currency: lhs.currency)
    }

    private func assertSameCurrency(as other: Money) {
        precondition(currency == other.currency, "Cannot combine money in different currencies")
    }
}

