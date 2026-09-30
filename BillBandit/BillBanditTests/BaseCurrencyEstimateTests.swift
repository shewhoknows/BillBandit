import XCTest
@testable import BillBandit

final class BaseCurrencyEstimateTests: XCTestCase {
    func testZeroDecimalVNDConvertsToTwoDecimalINREstimate() {
        let sourceAmount = Decimal(string: "100001", locale: Locale(identifier: "en_US_POSIX"))!
        let rate = BaseCurrencyRate(
            sourceCurrencyCode: "VND",
            baseCurrencyCode: "INR",
            baseUnitsPerSourceUnit: Decimal(string: "0.000551", locale: Locale(identifier: "en_US_POSIX"))!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            source: "Manual fixed rate"
        )

        XCTAssertEqual(
            BaseCurrencyConversion.estimate(
                amount: sourceAmount,
                sourceCurrency: "VND",
                baseCurrency: "INR",
                rate: rate
            ),
            Decimal(string: "55.10", locale: Locale(identifier: "en_US_POSIX"))
        )
    }

    func testMissingMismatchedAndNonPositiveRatesReturnNoEstimate() {
        let amount = Decimal(string: "1000", locale: Locale(identifier: "en_US_POSIX"))!

        XCTAssertNil(
            BaseCurrencyConversion.estimate(
                amount: amount,
                sourceCurrency: "VND",
                baseCurrency: "INR",
                rate: nil
            )
        )

        let mismatched = BaseCurrencyRate(
            sourceCurrencyCode: "USD",
            baseCurrencyCode: "INR",
            baseUnitsPerSourceUnit: Decimal(string: "0.01", locale: Locale(identifier: "en_US_POSIX"))!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            source: "Manual fixed rate"
        )
        XCTAssertNil(
            BaseCurrencyConversion.estimate(
                amount: amount,
                sourceCurrency: "VND",
                baseCurrency: "INR",
                rate: mismatched
            )
        )

        let nonPositive = BaseCurrencyRate(
            sourceCurrencyCode: "VND",
            baseCurrencyCode: "INR",
            baseUnitsPerSourceUnit: .zero,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            source: "Manual fixed rate"
        )
        XCTAssertNil(
            BaseCurrencyConversion.estimate(
                amount: amount,
                sourceCurrency: "VND",
                baseCurrency: "INR",
                rate: nonPositive
            )
        )

        let future = BaseCurrencyRate(
            sourceCurrencyCode: "VND",
            baseCurrencyCode: "INR",
            baseUnitsPerSourceUnit: Decimal(string: "0.00055", locale: Locale(identifier: "en_US_POSIX"))!,
            date: Date().addingTimeInterval(60),
            source: "Manual fixed rate"
        )
        XCTAssertNil(
            BaseCurrencyConversion.estimate(
                amount: amount,
                sourceCurrency: "VND",
                baseCurrency: "INR",
                rate: future
            )
        )
    }

    func testEstimateDoesNotMutateOriginalDecimalInput() {
        let original = Decimal(string: "12345.67", locale: Locale(identifier: "en_US_POSIX"))!
        let rate = BaseCurrencyRate(
            sourceCurrencyCode: "VND",
            baseCurrencyCode: "INR",
            baseUnitsPerSourceUnit: Decimal(string: "0.00055", locale: Locale(identifier: "en_US_POSIX"))!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            source: "Manual fixed rate"
        )

        _ = BaseCurrencyConversion.estimate(
            amount: original,
            sourceCurrency: "VND",
            baseCurrency: "INR",
            rate: rate
        )

        XCTAssertEqual(original, Decimal(string: "12345.67", locale: Locale(identifier: "en_US_POSIX")))
    }

    @MainActor
    func testManualVNDPerINRRatePersistsAndLoadsAsCached() {
        let suiteName = "BaseCurrencyEstimateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BaseCurrencyEstimateStore(userDefaults: defaults)
        store.selectedBaseCurrency = .inr
        XCTAssertTrue(
            store.saveManualRate(
                sourceCurrency: .vnd,
                sourceUnitsPerBaseUnit: Decimal(string: "90", locale: Locale(identifier: "en_US_POSIX"))!,
                date: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        XCTAssertEqual(
            store.estimate(amount: Decimal(string: "1000")!, sourceCurrency: "VND"),
            Decimal(string: "11.11")
        )

        let reloaded = BaseCurrencyEstimateStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.rate(for: .vnd)?.isCached == true)
        XCTAssertEqual(reloaded.rate(for: .vnd)?.sourceCurrencyCode, "VND")
        XCTAssertEqual(reloaded.rate(for: .vnd)?.baseCurrencyCode, "INR")
    }
}
