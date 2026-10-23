import Foundation

enum AppCurrency: String, CaseIterable, Identifiable {
    case inr = "INR"
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case aed = "AED"
    case sgd = "SGD"
    case aud = "AUD"
    case cad = "CAD"
    case vnd = "VND"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .inr: return "₹"
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        // Left-to-right marks keep the Arabic sign in front of the number.
        case .aed: return "\u{200E}د.إ\u{200E}"
        case .sgd: return "S$"
        case .aud: return "A$"
        case .cad: return "C$"
        case .vnd: return "₫"
        }
    }

    var name: String {
        switch self {
        case .inr: return "Indian rupee"
        case .usd: return "US dollar"
        case .eur: return "Euro"
        case .gbp: return "British pound"
        case .aed: return "UAE dirham"
        case .sgd: return "Singapore dollar"
        case .aud: return "Australian dollar"
        case .cad: return "Canadian dollar"
        case .vnd: return "Vietnamese dong"
        }
    }

    var separatesSymbol: Bool { self == .aed }

    var minorUnitExponent: Int {
        self == .vnd ? 0 : 2
    }

    var minorUnitsPerMajorUnit: Int {
        Int(pow(10.0, Double(minorUnitExponent)))
    }
}

/// Money helpers — all amounts are `Decimal`. Amounts keep the minor units of
/// their currency (paise, cents); only zero-exponent currencies such as VND are
/// whole numbers. Never use `Double` for money (see HANDOFF.md §2).
enum Money {
    static let currencyDefaultsKey = "defaultCurrencyCode"

    static var currentCurrency: AppCurrency {
        let code = UserDefaults.standard.string(forKey: currencyDefaultsKey) ?? AppCurrency.inr.rawValue
        return AppCurrency(rawValue: code) ?? .inr
    }

    static var symbol: String { currentCurrency.symbol }

    static func setCurrentCurrency(_ currency: AppCurrency) {
        UserDefaults.standard.set(currency.rawValue, forKey: currencyDefaultsKey)
    }

    /// Minor-unit exponent for a raw currency code. Unknown codes use 2.
    static func exponent(for currencyCode: String) -> Int {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return AppCurrency(rawValue: code)?.minorUnitExponent ?? 2
    }

    /// Round to 2 decimal places, half-up (banker's nemesis — always away from zero at .5).
    static func cents(_ d: Decimal) -> Decimal {
        rounded(d, exponent: 2)
    }

    /// Round to the currency's minor unit, half-up. ₹99.50 stays ₹99.50.
    static func rounded(_ d: Decimal, exponent: Int) -> Decimal {
        var input = d
        var result = Decimal()
        NSDecimalRound(&result, &input, max(0, exponent), .plain)
        return result
    }

    /// Floor a positive amount to the currency's minor unit (used before distributing remainders).
    static func floored(_ d: Decimal, exponent: Int) -> Decimal {
        var input = d
        var result = Decimal()
        NSDecimalRound(&result, &input, max(0, exponent), .down)
        return result
    }

    /// Round to a complete currency unit, half-up. Only for counts such as
    /// split shares; money keeps its minor units.
    static func whole(_ d: Decimal) -> Decimal {
        rounded(d, exponent: 0)
    }

    /// The smallest amount a currency can hold: 0.01 for INR, 1 for VND.
    static func minorUnit(exponent: Int) -> Decimal {
        var unit = Decimal(1)
        for _ in 0..<max(0, exponent) { unit /= 10 }
        return unit
    }

    /// "143" or "99.50". Whole amounts drop the decimals unless
    /// `keepsDecimals` is set; others show every minor-unit digit of the currency.
    static func string(_ d: Decimal, exponent: Int = 2, keepsDecimals: Bool = false) -> String {
        let value = rounded(d, exponent: exponent)
        let n = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let isWhole = !keepsDecimals && rounded(value, exponent: 0) == value
        f.minimumFractionDigits = isWhole ? 0 : max(0, exponent)
        f.maximumFractionDigits = isWhole ? 0 : max(0, exponent)
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        return f.string(from: n) ?? "\(n)"
    }

    /// "₹143", "₹99.50", "$143", or "د.إ 143".
    static func currency(_ d: Decimal, currency: AppCurrency? = nil, keepsDecimals: Bool = false) -> String {
        let currency = currency ?? currentCurrency
        let sign = d < 0 ? "-" : ""
        return sign + currency.symbol + (currency.separatesSymbol ? " " : "")
            + string(d < 0 ? -d : d, exponent: currency.minorUnitExponent, keepsDecimals: keepsDecimals)
    }

    /// Formats an amount with a raw server currency code.
    /// Unknown server currencies stay visible and are never relabeled as INR.
    static func currency(_ d: Decimal, currencyCode: String, keepsDecimals: Bool = false) -> String {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let known = AppCurrency(rawValue: code) else {
            return "\(code) \(string(d, keepsDecimals: keepsDecimals))"
        }
        return currency(d, currency: known, keepsDecimals: keepsDecimals)
    }

    /// Plain, ungrouped text suitable for an editable field: "99.5" or "100".
    static func inputString(_ d: Decimal, exponent: Int = 2) -> String {
        NSDecimalNumber(decimal: rounded(d, exponent: exponent)).stringValue
    }

    /// Parses editable money text while distinguishing grouping commas from a
    /// decimal comma. For example, `3,496` is 3496 while `86,5` is 86.5.
    static func parseInput(_ raw: String) -> Decimal? {
        var value = raw.replacingOccurrences(of: "\u{200E}", with: "")
        for currency in AppCurrency.allCases.sorted(by: { $0.symbol.count > $1.symbol.count }) {
            value = value
                .replacingOccurrences(of: currency.symbol.replacingOccurrences(of: "\u{200E}", with: ""), with: "")
                .replacingOccurrences(of: currency.rawValue, with: "", options: .caseInsensitive)
        }
        value = value
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else { return nil }

        if value.contains(".") {
            value.removeAll { $0 == "," }
        } else if value.contains(",") {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let looksGrouped = parts.count > 2 || parts.last?.count == 3
            value = looksGrouped
                ? value.replacingOccurrences(of: ",", with: "")
                : value.replacingOccurrences(of: ",", with: ".")
        }

        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension String {
    /// Ensures pasted or hardware-keyboard text follows the same convention as
    /// sentence-autocapitalized form fields.
    var capitalizingFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

enum GroupCopy {
    static func memberCount(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }
}
