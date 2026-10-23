import Foundation
import SwiftUI
import Combine

/// Profile owns the default currency. Ledger amounts keep their original
/// currency; estimates in the default currency are for reading only.
@MainActor
struct ProfileCurrencySettingsSection: View {
    let sourceCodes: [String]
    let balances: [ServerLedgerSurfaceAccountBalanceSummary]?
    @ObservedObject private var store = BaseCurrencyEstimateStore.shared
    @State private var settingsCurrency: AppCurrency?

    private var sourceCurrencies: [AppCurrency] {
        sourceCodes.compactMap(AppCurrency.init(rawValue:))
            .filter { $0 != store.selectedBaseCurrency }
    }

    private func convertedTotal(owed: Bool) -> Decimal? {
        guard let balances else { return nil }
        var total = Decimal.zero
        for balance in balances {
            let money = owed ? balance.owed : balance.owe
            guard let amount = money.majorUnits,
                  let converted = store.estimate(amount: amount, sourceCurrency: money.currencyCode) else { return nil }
            total += converted
        }
        return total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandSectionLabel("DEFAULT CURRENCY")
            Menu {
                ForEach(AppCurrency.allCases) { currency in
                    Button {
                        Task { await store.chooseDefault(currency) }
                    } label: {
                        if currency == store.selectedBaseCurrency {
                            Label("\(currency.symbol) \(currency.rawValue) · \(currency.name)", systemImage: "checkmark")
                        } else {
                            Text("\(currency.symbol) \(currency.rawValue) · \(currency.name)")
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Your currency")
                        .font(BrandFont.body(14, weight: .bold))
                    Spacer()
                    Text("\(store.selectedBaseCurrency.symbol) \(store.selectedBaseCurrency.rawValue)")
                        .font(BrandFont.type(13, bold: true))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.bold))
                }
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))
            }
            .accessibilityIdentifier("profileBaseCurrencyPicker")
            Text("New groups start in this currency. Amounts in other currencies show an estimate in \(store.selectedBaseCurrency.rawValue). Expenses and payments keep their own currency.")
                .font(BrandFont.body(12))
                .foregroundStyle(Color.Brand.cobalt.opacity(0.65))
            if balances != nil, !sourceCurrencies.isEmpty {
                if let owed = convertedTotal(owed: true), let owe = convertedTotal(owed: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Estimated totals in \(store.selectedBaseCurrency.rawValue)")
                            .font(BrandFont.body(12, weight: .bold))
                        Text("You are owed ≈ \(BaseCurrencyEstimateFormatting.amount(owed, currency: store.selectedBaseCurrency))")
                        Text("You owe ≈ \(BaseCurrencyEstimateFormatting.amount(owe, currency: store.selectedBaseCurrency))")
                    }
                    .font(BrandFont.type(11))
                } else {
                    Text("Waiting for exchange rates to estimate totals.").font(BrandFont.body(11))
                }
            }
            if !sourceCurrencies.isEmpty {
                BrandSectionLabel("EXCHANGE RATES")
            }
            ForEach(sourceCurrencies) { currency in
                HStack(alignment: .firstTextBaseline) {
                    if let rate = store.rate(for: currency) {
                        Text(BaseCurrencyEstimateFormatting.rateLine(rate))
                            .font(BrandFont.type(11, bold: true))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text("\(currency.rawValue) to \(store.selectedBaseCurrency.rawValue) · no rate yet")
                            .font(BrandFont.type(11))
                    }
                    Spacer(minLength: 8)
                    Button("Fix rate") { settingsCurrency = currency }
                        .font(BrandFont.body(11, weight: .bold))
                        .fixedSize()
                        .accessibilityLabel("Set a fixed \(currency.rawValue) rate")
                }
            }
            if !sourceCurrencies.isEmpty {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    HStack {
                        if store.isRefreshing { ProgressView().tint(Color.Brand.cobalt) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(store.isRefreshing ? "Refreshing exchange rates…" : "Refresh exchange rates")
                    }
                    .font(BrandFont.body(13, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 1.5))
                }
                .accessibilityIdentifier("profileRefreshExchangeRates")
                .disabled(store.isRefreshing)
            }
            if let error = store.lastError {
                Text(error).font(BrandFont.body(11))
            }
        }
        .foregroundStyle(Color.Brand.cobalt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .sheet(item: $settingsCurrency) { currency in
            BaseCurrencyEstimateSettingsView(store: store, sourceCurrency: currency)
        }
        .task(id: sourceCodes.joined(separator: ",") + store.selectedBaseCurrency.rawValue) {
            for currency in sourceCurrencies { await store.ensureRate(sourceCurrency: currency) }
        }
    }
}

/// Asks once for the person's own currency, then saves it on the server.
@MainActor
struct DefaultCurrencyPromptSheet: View {
    var onDone: () -> Void
    @ObservedObject private var store = BaseCurrencyEstimateStore.shared
    @State private var choice: AppCurrency = BaseCurrencyEstimateStore.suggestedCurrency()
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MascotView(mascot: .greeting, size: 96, idle: false)
                    .frame(maxWidth: .infinity)
                Text("Which currency is yours?")
                    .font(BrandFont.display(24, weight: .bold))
                Text("BillBandit shows totals and estimates in this currency. Each group keeps its own currency. You can change this in Profile.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.72))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AppCurrency.allCases) { option in
                        Button { choice = option } label: {
                            VStack(spacing: 2) {
                                Text("\(option.symbol) \(option.rawValue)")
                                    .font(BrandFont.type(13, bold: true))
                                Text(option.name)
                                    .font(BrandFont.body(9, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .opacity(0.75)
                            }
                            .foregroundStyle(choice == option ? Color.Brand.creamSoft : Color.Brand.cobalt)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .padding(.horizontal, 4)
                            .background(choice == option ? Color.Brand.cobalt : .clear, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(choice == option ? .isSelected : [])
                    }
                }
                if let error = store.lastError {
                    Text(error)
                        .font(BrandFont.body(12))
                }
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if await store.chooseDefault(choice) { onDone() }
                    }
                } label: {
                    Text(isSaving ? "Saving…" : "Use \(choice.symbol) \(choice.rawValue)")
                        .font(BrandFont.display(15.5, weight: .bold))
                        .foregroundStyle(Color.Brand.creamSoft)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.Brand.cobalt, in: Capsule())
                }
                .disabled(isSaving)
                .accessibilityIdentifier("defaultCurrencyConfirmButton")
            }
            .foregroundStyle(Color.Brand.cobalt)
            .padding(22)
        }
        .background(Color.Brand.creamSoft.ignoresSafeArea())
        .interactiveDismissDisabled()
        .onAppear { choice = store.isDefaultConfirmed ? store.selectedBaseCurrency : BaseCurrencyEstimateStore.suggestedCurrency() }
    }
}

/// A display-only exchange rate. `baseUnitsPerSourceUnit` is the number of
/// base-currency units for one source-currency unit.
struct BaseCurrencyRate: Codable, Equatable, Sendable {
    let sourceCurrencyCode: String
    let baseCurrencyCode: String
    let baseUnitsPerSourceUnit: Decimal
    let date: Date
    let source: String
    let isCached: Bool

    init(
        sourceCurrencyCode: String,
        baseCurrencyCode: String,
        baseUnitsPerSourceUnit: Decimal,
        date: Date,
        source: String,
        isCached: Bool = false
    ) {
        self.sourceCurrencyCode = BaseCurrencyConversion.normalizedCode(sourceCurrencyCode)
        self.baseCurrencyCode = BaseCurrencyConversion.normalizedCode(baseCurrencyCode)
        self.baseUnitsPerSourceUnit = baseUnitsPerSourceUnit
        self.date = date
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isCached = isCached
    }

    func cachedCopy() -> BaseCurrencyRate {
        BaseCurrencyRate(
            sourceCurrencyCode: sourceCurrencyCode,
            baseCurrencyCode: baseCurrencyCode,
            baseUnitsPerSourceUnit: baseUnitsPerSourceUnit,
            date: date,
            source: source,
            isCached: true
        )
    }
}

/// Pure conversion helpers used by the display layer. These values never
/// participate in canonical expenses, splits, balances, or settlements.
enum BaseCurrencyConversion {
    static func estimate(
        amount: Decimal,
        sourceCurrency: String,
        baseCurrency: String,
        rate: BaseCurrencyRate?
    ) -> Decimal? {
        let sourceCode = normalizedCode(sourceCurrency)
        let baseCode = normalizedCode(baseCurrency)
        guard AppCurrency(rawValue: sourceCode) != nil,
              let base = AppCurrency(rawValue: baseCode),
              isFinite(amount) else {
            return nil
        }

        if sourceCode == baseCode {
            if let rate {
                guard isUsable(rate),
                      rate.sourceCurrencyCode == sourceCode,
                      rate.baseCurrencyCode == baseCode else {
                    return nil
                }
            }
            return rounded(amount, exponent: base.minorUnitExponent)
        }

        guard let rate,
              isUsable(rate),
              rate.sourceCurrencyCode == sourceCode,
              rate.baseCurrencyCode == baseCode else {
            return nil
        }

        var amountValue = amount
        var multiplier = rate.baseUnitsPerSourceUnit
        var converted = Decimal()
        guard NSDecimalMultiply(&converted, &amountValue, &multiplier, .plain) == .noError,
              isFinite(converted) else {
            return nil
        }
        return rounded(converted, exponent: base.minorUnitExponent)
    }

    static func normalizedCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isUsable(_ rate: BaseCurrencyRate, now: Date = Date()) -> Bool {
        guard AppCurrency(rawValue: rate.sourceCurrencyCode) != nil,
              AppCurrency(rawValue: rate.baseCurrencyCode) != nil,
              !rate.source.isEmpty,
              isFinite(rate.baseUnitsPerSourceUnit),
              rate.baseUnitsPerSourceUnit > .zero,
              rate.date.timeIntervalSinceReferenceDate.isFinite,
              rate.date <= now else {
            return false
        }
        return true
    }

    private static func rounded(_ value: Decimal, exponent: Int) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, exponent, .plain)
        return output
    }

    private static func isFinite(_ value: Decimal) -> Bool {
        let number = NSDecimalNumber(decimal: value)
        return number != NSDecimalNumber.notANumber && number.doubleValue.isFinite
    }
}

enum BaseCurrencyEstimateFormatting {
    static func amount(_ value: Decimal, currency: AppCurrency) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.currencySymbol = currency.symbol
        formatter.locale = Locale(identifier: "en_IN")
        formatter.minimumFractionDigits = currency.minorUnitExponent
        formatter.maximumFractionDigits = currency.minorUnitExponent
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? "\(currency.symbol)\(NSDecimalNumber(decimal: value).stringValue)"
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    /// "22 Oct", in UTC because reference rates are dated by UTC day.
    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    /// "S$1 = ₹65.12". When one source unit is worth less than one minor
    /// unit of the base (₫1 = ₹0.0032), the line flips to "₹1 = ₫311".
    static func rateEquation(_ rate: BaseCurrencyRate) -> String {
        guard let source = AppCurrency(rawValue: rate.sourceCurrencyCode),
              let base = AppCurrency(rawValue: rate.baseCurrencyCode) else {
            return "1 \(rate.sourceCurrencyCode) = \(NSDecimalNumber(decimal: rate.baseUnitsPerSourceUnit).stringValue) \(rate.baseCurrencyCode)"
        }
        if rate.baseUnitsPerSourceUnit >= Decimal(string: "0.1")! {
            return "\(unit(source)) = \(rateAmount(rate.baseUnitsPerSourceUnit, currency: base))"
        }
        var one = Decimal(1)
        var value = rate.baseUnitsPerSourceUnit
        var inverse = Decimal()
        guard NSDecimalDivide(&inverse, &one, &value, .plain) == .noError else {
            return "\(unit(source)) = \(rateAmount(rate.baseUnitsPerSourceUnit, currency: base))"
        }
        return "\(unit(base)) = \(rateAmount(inverse, currency: source))"
    }

    /// "S$1 = ₹65.12 · rate from 22 Oct"
    static func rateLine(_ rate: BaseCurrencyRate) -> String {
        if rate.source == BaseCurrencyEstimateStore.manualSource {
            return "\(rateEquation(rate)) · your fixed rate"
        }
        return "\(rateEquation(rate)) · rate from \(shortDate(rate.date))"
    }

    private static func unit(_ currency: AppCurrency) -> String {
        currency.symbol + (currency.separatesSymbol ? " " : "") + "1"
    }

    private static func rateAmount(_ value: Decimal, currency: AppCurrency) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_IN")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let digits = formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? NSDecimalNumber(decimal: rounded).stringValue
        return currency.symbol + (currency.separatesSymbol ? " " : "") + digits
    }
}

enum BaseCurrencyEstimateStoreError: LocalizedError {
    case unsupportedPair
    case invalidManualRate
    case invalidRemoteResponse
    case invalidRemoteDate
    case network

    var errorDescription: String? {
        switch self {
        case .unsupportedPair:
            return "Choose a different currency to set an exchange rate."
        case .invalidManualRate:
            return "Enter a positive exchange rate and a valid date."
        case .invalidRemoteResponse, .invalidRemoteDate:
            return "The server sent an exchange rate BillBandit could not read."
        case .network:
            return "Could not refresh exchange rates. Saved rates still show."
        }
    }
}

@MainActor
final class BaseCurrencyEstimateStore: ObservableObject {
    static let shared = BaseCurrencyEstimateStore()
    static let manualSource = "Manual fixed rate"
    private var automaticAttempts = Set<String>()
    private var refreshTask: Task<Void, Never>?

    /// The person's default currency. The server holds the real value; this
    /// copy lets every screen read it without waiting.
    @Published var selectedBaseCurrency: AppCurrency {
        didSet {
            userDefaults.set(selectedBaseCurrency.rawValue, forKey: Self.baseCurrencyKey)
            userDefaults.set(selectedBaseCurrency.rawValue, forKey: Money.currencyDefaultsKey)
        }
    }

    @Published private(set) var ratesByPair: [String: BaseCurrencyRate]
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    /// True once the server has a default currency for this person.
    @Published private(set) var isDefaultConfirmed: Bool {
        didSet { userDefaults.set(isDefaultConfirmed, forKey: Self.confirmedKey) }
    }

    private let userDefaults: UserDefaults

    private static let baseCurrencyKey = "baseCurrencyEstimate.baseCurrency"
    private static let confirmedKey = "defaultCurrency.confirmedOnServer"
    private static let rateKeyPrefix = "baseCurrencyEstimate.rate."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let savedBase = (userDefaults.string(forKey: Self.baseCurrencyKey)
            ?? userDefaults.string(forKey: Money.currencyDefaultsKey))
            .flatMap(AppCurrency.init(rawValue:)) ?? .inr
        _selectedBaseCurrency = Published(initialValue: savedBase)
        _isDefaultConfirmed = Published(initialValue: userDefaults.bool(forKey: Self.confirmedKey))
        _ratesByPair = Published(initialValue: [:])
        loadRates()
    }

    /// A first guess from the phone's region, used only to preselect a choice.
    static func suggestedCurrency(locale: Locale = .current) -> AppCurrency {
        locale.currency.flatMap { AppCurrency(rawValue: $0.identifier.uppercased()) } ?? .inr
    }

    /// Applies the value the server returned. Never writes back.
    func applyServerDefault(_ currency: AppCurrency) {
        if selectedBaseCurrency != currency { selectedBaseCurrency = currency }
        isDefaultConfirmed = true
    }

    /// Saves a new default currency on the server first. The app switches
    /// only after the server accepts it.
    @discardableResult
    func chooseDefault(_ currency: AppCurrency) async -> Bool {
        do {
            let user = try await UsernameIdentityService.updateDefaultCurrency(currency)
            let saved = user.defaultCurrency.flatMap(AppCurrency.init(rawValue:)) ?? currency
            applyServerDefault(saved)
            lastError = nil
            await refreshAll()
            return true
        } catch {
            lastError = "Your currency was not saved. Check your connection and try again."
            return false
        }
    }

    func rate(for sourceCurrency: AppCurrency, baseCurrency: AppCurrency? = nil) -> BaseCurrencyRate? {
        let base = baseCurrency ?? selectedBaseCurrency
        return rate(for: sourceCurrency.rawValue, baseCurrencyCode: base.rawValue)
    }

    func rate(for sourceCurrencyCode: String, baseCurrencyCode: String? = nil) -> BaseCurrencyRate? {
        let source = BaseCurrencyConversion.normalizedCode(sourceCurrencyCode)
        let base = BaseCurrencyConversion.normalizedCode(baseCurrencyCode ?? selectedBaseCurrency.rawValue)
        return ratesByPair[pairKey(source: source, base: base)]
    }

    func estimate(amount: Decimal, sourceCurrency: String) -> Decimal? {
        BaseCurrencyConversion.estimate(
            amount: amount,
            sourceCurrency: sourceCurrency,
            baseCurrency: selectedBaseCurrency.rawValue,
            rate: rate(for: sourceCurrency)
        )
    }

    /// Saves a fixed trip rate entered as source units for one base unit.
    /// For example, `90` means `90 VND per 1 INR`. A fixed rate wins over the
    /// daily rate until the next refresh.
    @discardableResult
    func saveManualRate(
        sourceCurrency: AppCurrency,
        sourceUnitsPerBaseUnit: Decimal,
        date: Date = Date(),
        source: String = BaseCurrencyEstimateStore.manualSource
    ) -> Bool {
        guard sourceCurrency != selectedBaseCurrency,
              isFinitePositive(sourceUnitsPerBaseUnit),
              date <= Date(),
              date.timeIntervalSinceReferenceDate.isFinite else {
            lastError = BaseCurrencyEstimateStoreError.invalidManualRate.localizedDescription
            return false
        }

        var one = Decimal(1)
        var sourceUnits = sourceUnitsPerBaseUnit
        var baseUnitsPerSource = Decimal()
        let divisionResult = NSDecimalDivide(&baseUnitsPerSource, &one, &sourceUnits, .plain)
        guard divisionResult == .noError || divisionResult == .lossOfPrecision,
              isFinitePositive(baseUnitsPerSource) else {
            lastError = BaseCurrencyEstimateStoreError.invalidManualRate.localizedDescription
            return false
        }

        let rate = BaseCurrencyRate(
            sourceCurrencyCode: sourceCurrency.rawValue,
            baseCurrencyCode: selectedBaseCurrency.rawValue,
            baseUnitsPerSourceUnit: baseUnitsPerSource,
            date: date,
            source: source,
            isCached: false
        )
        return set(rate: rate)
    }

    @discardableResult
    func set(rate: BaseCurrencyRate) -> Bool {
        guard BaseCurrencyConversion.isUsable(rate) else {
            lastError = BaseCurrencyEstimateStoreError.invalidManualRate.localizedDescription
            return false
        }
        ratesByPair[pairKey(source: rate.sourceCurrencyCode, base: rate.baseCurrencyCode)] = rate
        persist(rate)
        lastError = nil
        return true
    }

    /// Shows a saved rate at once, then asks the server for today's rates
    /// at most once per UTC day. The attempt is recorded before the request
    /// so a failed request cannot create a SwiftUI refresh loop.
    func ensureRate(sourceCurrency: AppCurrency) async {
        let baseCurrency = selectedBaseCurrency
        guard sourceCurrency != baseCurrency else { return }

        let pair = pairKey(source: sourceCurrency.rawValue, base: baseCurrency.rawValue)
        let today = Self.dayKey(Date())
        if ratesByPair[pair] == nil, let persistedRate = persistedRate(for: pair) {
            ratesByPair[pair] = persistedRate.cachedCopy()
        }
        if let cachedRate = ratesByPair[pair],
           cachedRate.source == Self.manualSource || Self.dayKey(cachedRate.date) == today { return }
        guard automaticAttempts.insert(baseCurrency.rawValue + today).inserted else { return }
        await refreshAll()
    }

    func refresh(sourceCurrency: AppCurrency) async {
        await refreshAll()
    }

    /// One server call returns every rate for the default currency.
    /// Saved rates stay in place when the request fails.
    func refreshAll() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        isRefreshing = true
        await task.value
        refreshTask = nil
        isRefreshing = false
    }

    private func performRefresh() async {
        let baseCurrency = selectedBaseCurrency
        do {
            let response: ServerRatesResponse = try await APIClient.live().get(
                "/api/mobile/rates?base=\(baseCurrency.rawValue)"
            )
            guard BaseCurrencyConversion.normalizedCode(response.base) == baseCurrency.rawValue else {
                throw BaseCurrencyEstimateStoreError.invalidRemoteResponse
            }
            for quote in response.rates {
                guard let source = AppCurrency(rawValue: BaseCurrencyConversion.normalizedCode(quote.quote)),
                      source != baseCurrency,
                      let basePerQuote = Decimal(string: quote.basePerQuote, locale: Locale(identifier: "en_US_POSIX")),
                      let date = Self.parseRemoteDate(quote.rateDate) else { continue }
                let pair = pairKey(source: source.rawValue, base: baseCurrency.rawValue)
                // A person's fixed trip rate stays until they change it.
                if ratesByPair[pair]?.source == Self.manualSource { continue }
                _ = set(rate: BaseCurrencyRate(
                    sourceCurrencyCode: source.rawValue,
                    baseCurrencyCode: baseCurrency.rawValue,
                    baseUnitsPerSourceUnit: basePerQuote,
                    date: min(date, Date()),
                    source: response.source,
                    isCached: response.stale
                ))
            }
            lastError = nil
        } catch let error as BaseCurrencyEstimateStoreError {
            lastError = error.localizedDescription
        } catch {
            lastError = BaseCurrencyEstimateStoreError.network.localizedDescription
        }
    }

    /// Drops a fixed rate so the daily rate shows again.
    func clearManualRate(sourceCurrency: AppCurrency) async {
        let pair = pairKey(source: sourceCurrency.rawValue, base: selectedBaseCurrency.rawValue)
        ratesByPair[pair] = nil
        userDefaults.removeObject(forKey: Self.rateKeyPrefix + pair)
        automaticAttempts.removeAll()
        await refreshAll()
    }

    private func loadRates() {
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(Self.rateKeyPrefix) {
            let pair = String(key.dropFirst(Self.rateKeyPrefix.count))
            guard let rate = persistedRate(for: pair) else { continue }
            ratesByPair[pairKey(source: rate.sourceCurrencyCode, base: rate.baseCurrencyCode)] = rate.cachedCopy()
        }
    }

    private func persistedRate(for pair: String) -> BaseCurrencyRate? {
        guard let data = userDefaults.data(forKey: Self.rateKeyPrefix + pair),
              let rate = try? JSONDecoder().decode(BaseCurrencyRate.self, from: data),
              BaseCurrencyConversion.isUsable(rate) else {
            return nil
        }
        return rate
    }

    private func persist(_ rate: BaseCurrencyRate) {
        guard let data = try? JSONEncoder().encode(rate) else { return }
        userDefaults.set(data, forKey: Self.rateKeyPrefix + pairKey(source: rate.sourceCurrencyCode, base: rate.baseCurrencyCode))
    }

    private func pairKey(source: String, base: String) -> String {
        "\(source.uppercased())→\(base.uppercased())"
    }

    private func isFinitePositive(_ value: Decimal) -> Bool {
        let number = NSDecimalNumber(decimal: value)
        return number != NSDecimalNumber.notANumber && number.doubleValue.isFinite && value > .zero
    }

    private static func parseRemoteDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// `GET /api/mobile/rates?base=INR`. Rates are decimal strings so no value
/// passes through `Double`.
private struct ServerRatesResponse: Decodable {
    struct Quote: Decodable {
        let quote: String
        let rateDate: String
        let basePerQuote: String
    }

    let base: String
    let source: String
    let stale: Bool
    let rates: [Quote]
}

/// An estimate of a foreign amount in the person's default currency, with the
/// rate it used. Sits inside the cream invoice card.
@MainActor
struct BaseCurrencyEstimatePanel: View {
    let amount: Decimal
    let currencyCode: String
    let title: String

    @ObservedObject private var store: BaseCurrencyEstimateStore

    init(amount: Decimal, currencyCode: String, title: String) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.title = title
        _store = ObservedObject(wrappedValue: BaseCurrencyEstimateStore.shared)
    }

    private var sourceCurrency: AppCurrency? {
        AppCurrency(rawValue: BaseCurrencyConversion.normalizedCode(currencyCode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(BrandFont.type(9, bold: true))
                .tracking(1)
                .opacity(0.6)

            if let sourceCurrency,
               let estimate = store.estimate(amount: amount, sourceCurrency: sourceCurrency.rawValue) {
                Text("≈ \(BaseCurrencyEstimateFormatting.amount(estimate, currency: store.selectedBaseCurrency))")
                    .font(BrandFont.type(15, bold: true))
                    .accessibilityIdentifier("baseCurrencyEstimatedAmount")
                    .accessibilityLabel("Estimated \(BaseCurrencyEstimateFormatting.amount(estimate, currency: store.selectedBaseCurrency)) in \(store.selectedBaseCurrency.name)")

                if let rate = store.rate(for: sourceCurrency), sourceCurrency != store.selectedBaseCurrency {
                    Text(BaseCurrencyEstimateFormatting.rateLine(rate))
                        .font(BrandFont.type(9.5))
                        .opacity(0.7)
                }
            } else {
                Text(store.isRefreshing
                     ? "Getting today's \(currencyCode) to \(store.selectedBaseCurrency.rawValue) rate…"
                     : "No \(currencyCode) to \(store.selectedBaseCurrency.rawValue) rate yet. Pull to refresh.")
                    .font(BrandFont.type(9.5))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(Color.Brand.cobalt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sourceCurrency.map { "\($0.rawValue)/\(store.selectedBaseCurrency.rawValue)" }) {
            if let sourceCurrency {
                await store.ensureRate(sourceCurrency: sourceCurrency)
            }
        }
    }
}

/// Lets a person pin a fixed trip rate for one currency.
@MainActor
private struct BaseCurrencyEstimateSettingsView: View {
    @ObservedObject var store: BaseCurrencyEstimateStore
    let sourceCurrency: AppCurrency

    @Environment(\.dismiss) private var dismiss
    @State private var sourceUnitsText = ""

    private var currentRate: BaseCurrencyRate? {
        store.rate(for: sourceCurrency)
    }

    private var base: AppCurrency { store.selectedBaseCurrency }

    /// Ask in the same direction as the rate line above: "S$1 = ₹73.98"
    /// asks for rupees per dollar, "₹1 = ₫273.22" asks for dong per rupee.
    private var asksBasePerSource: Bool {
        if let currentRate { return currentRate.baseUnitsPerSourceUnit >= Decimal(string: "0.1")! }
        return sourceCurrency.minorUnitExponent > 0
    }

    private var question: String {
        asksBasePerSource
            ? "How many \(base.rawValue) did 1 \(sourceCurrency.rawValue) cost on your trip? Estimates will use this number until you clear it."
            : "How many \(sourceCurrency.rawValue) did 1 \(base.rawValue) buy on your trip? Estimates will use this number until you clear it."
    }

    private var placeholder: String {
        asksBasePerSource
            ? "\(base.rawValue) per 1 \(sourceCurrency.rawValue)"
            : "\(sourceCurrency.rawValue) per 1 \(base.rawValue)"
    }

    /// The typed number as source units per one base unit, the store's form.
    private var enteredSourceUnitsPerBase: Decimal? {
        guard var value = Money.parseInput(sourceUnitsText), value > 0 else { return nil }
        guard asksBasePerSource else { return value }
        var one = Decimal(1)
        var inverse = Decimal()
        guard NSDecimalDivide(&inverse, &one, &value, .plain) == .noError else { return nil }
        return inverse
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let currentRate {
                        BrandSectionLabel("RATE IN USE")
                        Text(BaseCurrencyEstimateFormatting.rateLine(currentRate))
                            .font(BrandFont.type(13, bold: true))
                    }

                    BrandSectionLabel("FIXED TRIP RATE")
                    Text(question)
                        .font(BrandFont.body(12))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.72))
                    TextField(placeholder, text: $sourceUnitsText)
                        .keyboardType(.decimalPad)
                        .font(BrandFont.type(15, bold: true))
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))
                        .accessibilityIdentifier("fixedRateField")

                    Button {
                        guard let value = enteredSourceUnitsPerBase,
                              store.saveManualRate(sourceCurrency: sourceCurrency, sourceUnitsPerBaseUnit: value) else {
                            return
                        }
                        dismiss()
                    } label: {
                        Text("Save fixed rate")
                            .font(BrandFont.display(15, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }

                    if currentRate?.source == BaseCurrencyEstimateStore.manualSource {
                        Button {
                            Task {
                                await store.clearManualRate(sourceCurrency: sourceCurrency)
                                dismiss()
                            }
                        } label: {
                            Text("Use the daily rate again")
                                .font(BrandFont.display(15, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))
                        }
                    }

                    if let lastError = store.lastError {
                        Text(lastError)
                            .font(BrandFont.body(12))
                    }
                }
                .foregroundStyle(Color.Brand.cobalt)
                .padding(20)
            }
            .background(Color.Brand.creamSoft.ignoresSafeArea())
            .navigationTitle("\(sourceCurrency.rawValue) rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.Brand.cobalt, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.Brand.creamSoft)
                }
            }
            .onAppear {
                if let currentRate, currentRate.source == BaseCurrencyEstimateStore.manualSource {
                    sourceUnitsText = asksBasePerSource
                        ? roundedText(currentRate.baseUnitsPerSourceUnit)
                        : reciprocalText(currentRate.baseUnitsPerSourceUnit)
                }
            }
        }
    }

    private func reciprocalText(_ rate: Decimal) -> String {
        var one = Decimal(1)
        var value = rate
        var reciprocal = Decimal()
        guard NSDecimalDivide(&reciprocal, &one, &value, .plain) == .noError else {
            return ""
        }
        return roundedText(reciprocal)
    }

    private func roundedText(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 4, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
