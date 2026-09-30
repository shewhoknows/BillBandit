import Foundation
import SwiftUI
import Combine

struct CurrencyEstimateAmount {
    let amount: Decimal
    let currencyCode: String
}

/// Adds display estimates only after every original currency has a valid rate.
struct BaseCurrencyTotalsEstimatePanel: View {
    let owed: [CurrencyEstimateAmount]
    let owe: [CurrencyEstimateAmount]
    @ObservedObject private var store = BaseCurrencyEstimateStore.shared

    private var sourceCodes: [String] {
        Set((owed + owe).map(\.currencyCode)).sorted()
    }

    private func convertedTotal(_ values: [CurrencyEstimateAmount]) -> Decimal? {
        var total = Decimal.zero
        for value in values {
            guard let estimate = store.estimate(amount: value.amount, sourceCurrency: value.currencyCode) else {
                return nil
            }
            total += estimate
        }
        return total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimated totals in \(store.selectedBaseCurrency.rawValue)")
                .font(BrandFont.type(12, bold: true))
            if let owedTotal = convertedTotal(owed), let oweTotal = convertedTotal(owe) {
                Text("You are owed ≈ \(BaseCurrencyEstimateFormatting.amount(owedTotal, currency: store.selectedBaseCurrency))")
                Text("You owe ≈ \(BaseCurrencyEstimateFormatting.amount(oweTotal, currency: store.selectedBaseCurrency))")
            } else {
                Text("Waiting for exchange rates. Original balances are shown above.")
            }
            ForEach(sourceCodes, id: \.self) { code in
                if let rate = store.rate(for: code), code != store.selectedBaseCurrency.rawValue {
                    Text("\(code)/\(rate.baseCurrencyCode) · \(BaseCurrencyEstimateFormatting.date(rate.date)) · \(rate.source)\(rate.isCached ? " · saved rate" : "")")
                        .font(BrandFont.type(9))
                }
            }
            Menu("Base currency: \(store.selectedBaseCurrency.rawValue)") {
                Picker("Base currency", selection: $store.selectedBaseCurrency) {
                    ForEach(AppCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
            }
            Button("Refresh exchange rates") {
                Task {
                    for code in sourceCodes {
                        if let currency = AppCurrency(rawValue: code), currency != store.selectedBaseCurrency {
                            await store.refresh(sourceCurrency: currency)
                        }
                    }
                }
            }
            .disabled(store.isRefreshing)
        }
        .font(BrandFont.type(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.Brand.creamSoft)
        .foregroundStyle(Color.Brand.cobalt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("baseCurrencyOverallEstimate")
        .task(id: sourceCodes.joined(separator: ",") + store.selectedBaseCurrency.rawValue) {
            for code in sourceCodes {
                if let currency = AppCurrency(rawValue: code) {
                    await store.ensureRate(sourceCurrency: currency)
                }
            }
        }
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
            return "Choose a different base currency to set an exchange rate."
        case .invalidManualRate:
            return "Enter a positive exchange rate and a valid date."
        case .invalidRemoteResponse, .invalidRemoteDate:
            return "The exchange-rate service returned an invalid rate."
        case .network:
            return "Could not refresh the rate. A cached rate remains available."
        }
    }
}

@MainActor
final class BaseCurrencyEstimateStore: ObservableObject {
    static let shared = BaseCurrencyEstimateStore()
    private var automaticAttempts = Set<String>()
    private var refreshingPairs = Set<String>()
    @Published var selectedBaseCurrency: AppCurrency {
        didSet {
            userDefaults.set(selectedBaseCurrency.rawValue, forKey: Self.baseCurrencyKey)
        }
    }

    @Published private(set) var ratesByPair: [String: BaseCurrencyRate]
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let userDefaults: UserDefaults

    private static let baseCurrencyKey = "baseCurrencyEstimate.baseCurrency"
    private static let rateKeyPrefix = "baseCurrencyEstimate.rate."

    private static let remoteSource = "Frankfurter daily reference rate"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let savedBase = userDefaults.string(forKey: Self.baseCurrencyKey)
            .flatMap(AppCurrency.init(rawValue:)) ?? .inr
        _selectedBaseCurrency = Published(initialValue: savedBase)
        _ratesByPair = Published(initialValue: [:])
        loadRates()
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
    /// For example, `90` means `90 VND per 1 INR`.
    @discardableResult
    func saveManualRate(
        sourceCurrency: AppCurrency,
        sourceUnitsPerBaseUnit: Decimal,
        date: Date = Date(),
        source: String = "Manual fixed rate"
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

    /// Ensures that a missing or stale pair gets one automatic refresh per UTC
    /// day. The attempt is recorded before the request so a failed request
    /// cannot create a SwiftUI refresh loop.
    func ensureRate(sourceCurrency: AppCurrency) async {
        let baseCurrency = selectedBaseCurrency
        guard sourceCurrency != baseCurrency else { return }

        let pair = pairKey(source: sourceCurrency.rawValue, base: baseCurrency.rawValue)
        let today = Self.dayKey(Date())
        if ratesByPair[pair] == nil, let persistedRate = persistedRate(for: pair) {
            ratesByPair[pair] = persistedRate.cachedCopy()
        }
        if let cachedRate = ratesByPair[pair], Self.dayKey(cachedRate.date) == today { return }
        guard automaticAttempts.insert(pair + today).inserted else { return }
        await refresh(sourceCurrency: sourceCurrency)
    }

    /// Fetches a daily reference rate only when the user requests a refresh.
    /// Existing cached data stays in place when the request fails.
    func refresh(sourceCurrency: AppCurrency) async {
        let baseCurrency = selectedBaseCurrency
        guard sourceCurrency != baseCurrency else {
            lastError = BaseCurrencyEstimateStoreError.unsupportedPair.localizedDescription
            return
        }
        let pair = pairKey(source: sourceCurrency.rawValue, base: baseCurrency.rawValue)
        guard refreshingPairs.insert(pair).inserted else { return }
        isRefreshing = true
        defer {
            refreshingPairs.remove(pair)
            isRefreshing = !refreshingPairs.isEmpty
        }

        do {
            let endpoint = "https://api.frankfurter.dev/v2/rate/\(sourceCurrency.rawValue.lowercased())/\(baseCurrency.rawValue.lowercased())"
            guard let url = URL(string: endpoint) else { throw BaseCurrencyEstimateStoreError.invalidRemoteResponse }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw BaseCurrencyEstimateStoreError.network
            }

            let payload = try JSONDecoder().decode(FrankfurterRateResponse.self, from: data)
            let responseSource = BaseCurrencyConversion.normalizedCode(payload.base)
            let responseBase = BaseCurrencyConversion.normalizedCode(payload.quote)
            guard responseSource == sourceCurrency.rawValue,
                  responseBase == baseCurrency.rawValue else {
                throw BaseCurrencyEstimateStoreError.invalidRemoteResponse
            }
            guard let date = Self.parseRemoteDate(payload.date), date <= Date() else {
                throw BaseCurrencyEstimateStoreError.invalidRemoteDate
            }

            let rate = BaseCurrencyRate(
                sourceCurrencyCode: responseSource,
                baseCurrencyCode: responseBase,
                baseUnitsPerSourceUnit: payload.rate,
                date: date,
                source: Self.remoteSource
            )
            guard set(rate: rate) else { throw BaseCurrencyEstimateStoreError.invalidRemoteResponse }
        } catch let error as BaseCurrencyEstimateStoreError {
            lastError = error.localizedDescription
        } catch {
            lastError = BaseCurrencyEstimateStoreError.network.localizedDescription
        }
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

private struct FrankfurterRateResponse: Decodable {
    let date: String
    let base: String
    let quote: String
    let rate: Decimal
}

@MainActor
struct BaseCurrencyEstimatePanel: View {
    let amount: Decimal
    let currencyCode: String
    let title: String

    @ObservedObject private var store: BaseCurrencyEstimateStore
    @State private var isShowingSettings = false

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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if let sourceCurrency,
               let estimate = store.estimate(amount: amount, sourceCurrency: sourceCurrency.rawValue) {
                Text("≈ \(BaseCurrencyEstimateFormatting.amount(estimate, currency: store.selectedBaseCurrency))")
                    .font(.headline)
                    .accessibilityIdentifier("baseCurrencyEstimatedAmount")
                    .accessibilityLabel("Estimated \(BaseCurrencyEstimateFormatting.amount(estimate, currency: store.selectedBaseCurrency)) in \(store.selectedBaseCurrency.name)")

                if let rate = store.rate(for: sourceCurrency), sourceCurrency != store.selectedBaseCurrency {
                    Text("1 \(rate.sourceCurrencyCode) ≈ \(NSDecimalNumber(decimal: rate.baseUnitsPerSourceUnit).stringValue) \(rate.baseCurrencyCode)")
                        .font(.caption)
                    Text("Approximate • \(rate.sourceCurrencyCode)/\(rate.baseCurrencyCode) • \(BaseCurrencyEstimateFormatting.date(rate.date)) • \(rate.source)\(rate.isCached ? " • saved rate" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Set exchange rate to see \(store.selectedBaseCurrency.rawValue) estimate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Exchange-rate settings") { isShowingSettings = true }
                    .font(.caption.weight(.semibold))

                if let sourceCurrency, sourceCurrency != store.selectedBaseCurrency {
                    Button {
                        Task { await store.refresh(sourceCurrency: sourceCurrency) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .disabled(store.isRefreshing)
                }
            }

            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            if let sourceCurrency {
                BaseCurrencyEstimateSettingsView(store: store, sourceCurrency: sourceCurrency)
            }
        }
        .task(id: sourceCurrency.map { "\($0.rawValue)/\(store.selectedBaseCurrency.rawValue)" }) {
            if let sourceCurrency {
                await store.ensureRate(sourceCurrency: sourceCurrency)
            }
        }
    }
}

@MainActor
private struct BaseCurrencyEstimateSettingsView: View {
    @ObservedObject var store: BaseCurrencyEstimateStore
    let sourceCurrency: AppCurrency

    @Environment(\.dismiss) private var dismiss
    @State private var sourceUnitsText = ""
    @State private var rateDate = Date()

    private var currentRate: BaseCurrencyRate? {
        store.rate(for: sourceCurrency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display currency") {
                    Picker("Show estimates in", selection: $store.selectedBaseCurrency) {
                        ForEach(AppCurrency.allCases) { currency in
                            Text("\(currency.rawValue) — \(currency.name)").tag(currency)
                        }
                    }
                }

                if sourceCurrency != store.selectedBaseCurrency {
                    Section("Fixed trip rate") {
                        Text("Enter how many \(sourceCurrency.rawValue) equal 1 \(store.selectedBaseCurrency.rawValue).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextField("\(sourceCurrency.rawValue) per 1 \(store.selectedBaseCurrency.rawValue)", text: $sourceUnitsText)
                            .keyboardType(.decimalPad)

                        DatePicker("Rate date", selection: $rateDate, displayedComponents: .date)

                        Button("Save fixed rate") {
                            guard let value = Money.parseInput(sourceUnitsText),
                                  store.saveManualRate(sourceCurrency: sourceCurrency, sourceUnitsPerBaseUnit: value, date: rateDate) else {
                                return
                            }
                            dismiss()
                        }

                        Button {
                            Task { await store.refresh(sourceCurrency: sourceCurrency) }
                        } label: {
                            if store.isRefreshing {
                                ProgressView()
                            } else {
                                Text("Refresh daily reference rate")
                            }
                        }
                        .disabled(store.isRefreshing)

                        if let currentRate {
                            Text("Current: \(currentRate.sourceCurrencyCode) per 1 \(currentRate.baseCurrencyCode) is approximately \(reciprocalText(currentRate.baseUnitsPerSourceUnit)). Dated \(BaseCurrencyEstimateFormatting.date(currentRate.date)).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("The source and display currencies match. No exchange rate is required.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastError = store.lastError {
                    Section {
                        Text(lastError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Exchange rates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let currentRate {
                    rateDate = currentRate.date
                    sourceUnitsText = reciprocalText(currentRate.baseUnitsPerSourceUnit)
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
        return NSDecimalNumber(decimal: reciprocal).stringValue
    }
}
