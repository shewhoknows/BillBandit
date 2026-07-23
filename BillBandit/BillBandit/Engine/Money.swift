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

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .inr: return "₹"
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .aed: return "د.إ"
        case .sgd: return "S$"
        case .aud: return "A$"
        case .cad: return "C$"
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
        }
    }

    var separatesSymbol: Bool { self == .aed }
}

/// Money helpers — all amounts are `Decimal`. Ledger balances are whole currency units.
/// Never use `Double` for money (see HANDOFF.md §2).
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

    /// Round to 2 decimal places, half-up (banker's nemesis — always away from zero at .5).
    static func cents(_ d: Decimal) -> Decimal {
        var input = d
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    /// Round to a complete currency unit, half-up. BillBandit never leaves fractional debt.
    static func whole(_ d: Decimal) -> Decimal {
        var input = d
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, .plain)
        return result
    }

    /// Floor a positive amount to a complete rupee (used before distributing remainders).
    static func floorWhole(_ d: Decimal) -> Decimal {
        var input = d
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, .down)
        return result
    }

    /// "143"
    static func string(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: whole(d))
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        f.groupingSeparator = ","
        return f.string(from: n) ?? "\(n)"
    }

    /// "₹143", "$143", or "د.إ 143".
    static func currency(_ d: Decimal, currency: AppCurrency? = nil) -> String {
        let currency = currency ?? currentCurrency
        return currency.symbol + (currency.separatesSymbol ? " " : "") + string(d)
    }

    /// Plain, ungrouped whole-rupee text suitable for an editable field.
    static func inputString(_ d: Decimal) -> String {
        NSDecimalNumber(decimal: whole(d)).stringValue
    }

    /// Parses editable money text while distinguishing grouping commas from a
    /// decimal comma. For example, `3,496` is 3496 while `86,5` is 86.5.
    static func parseInput(_ raw: String) -> Decimal? {
        var value = raw
        for currency in AppCurrency.allCases.sorted(by: { $0.symbol.count > $1.symbol.count }) {
            value = value
                .replacingOccurrences(of: currency.symbol, with: "")
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
