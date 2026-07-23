import XCTest
@testable import BillBandit

final class SplitEngineTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    func testEqualSplitClean() throws {
        let r = try SplitEngine.compute(total: 100, inputs: [
            SplitInput(personID: a), SplitInput(personID: b),
        ])
        XCTAssertEqual(r[a], 50)
        XCTAssertEqual(r[b], 50)
        XCTAssertEqual(r.values.reduce(0, +), 100)
    }

    func testEqualSplitRemainderIsDeterministic() throws {
        // 10 / 3 → 4, 3, 3, always in input order.
        let r = try SplitEngine.compute(total: 10, inputs: [
            SplitInput(personID: a), SplitInput(personID: b), SplitInput(personID: c),
        ])
        XCTAssertEqual(r[a], 4)
        XCTAssertEqual(r[b], 3)
        XCTAssertEqual(r[c], 3)
        XCTAssertEqual(r.values.reduce(0, +), 10)
    }

    func testSubRupeeTotalIsRejected() {
        XCTAssertThrowsError(try SplitEngine.compute(total: Decimal(string: "0.01")!, inputs: [
            SplitInput(personID: a), SplitInput(personID: b), SplitInput(personID: c),
        ])) { error in
            XCTAssertEqual(error as? SplitError, .nonPositiveTotal)
        }
    }

    func testExactMustSum() throws {
        XCTAssertThrowsError(try SplitEngine.compute(total: 50, inputs: [
            SplitInput(personID: a, mode: .exact, value: 30),
            SplitInput(personID: b, mode: .exact, value: 19),
        ])) { error in
            XCTAssertEqual(error as? SplitError,
                           .exactMismatch(expected: 50, got: 49))
        }
    }

    func testExactOk() throws {
        let r = try SplitEngine.compute(total: 50, inputs: [
            SplitInput(personID: a, mode: .exact, value: 30),
            SplitInput(personID: b, mode: .exact, value: 20),
        ])
        XCTAssertEqual(r.values.reduce(0, +), 50)
        XCTAssertEqual(r[a], 30)
    }

    func testPercentMustBe100() {
        XCTAssertThrowsError(try SplitEngine.compute(total: 100, inputs: [
            SplitInput(personID: a, mode: .percent, value: 60),
            SplitInput(personID: b, mode: .percent, value: 30),
        ])) { error in
            XCTAssertEqual(error as? SplitError, .percentNot100(90))
        }
    }

    func testPercentRoundingDriftFixed() throws {
        // 33.33/66.67 of 10 → 3 + 7 = 10.
        let r = try SplitEngine.compute(total: 10, inputs: [
            SplitInput(personID: a, mode: .percent, value: Decimal(string: "33.33")!),
            SplitInput(personID: b, mode: .percent, value: Decimal(string: "66.67")!),
        ])
        XCTAssertEqual(r.values.reduce(0, +), 10)
        XCTAssertEqual(r[a], 3)
        XCTAssertEqual(r[b], 7)
    }

    func testSharesProportional() throws {
        // 2:1 shares of 90 → 60 / 30
        let r = try SplitEngine.compute(total: 90, inputs: [
            SplitInput(personID: a, mode: .shares, value: 2),
            SplitInput(personID: b, mode: .shares, value: 1),
        ])
        XCTAssertEqual(r[a], 60)
        XCTAssertEqual(r[b], 30)
        XCTAssertEqual(r.values.reduce(0, +), 90)
    }

    func testSharesRoundingDriftFixed() throws {
        let r = try SplitEngine.compute(total: 10, inputs: [
            SplitInput(personID: a, mode: .shares, value: 1),
            SplitInput(personID: b, mode: .shares, value: 1),
            SplitInput(personID: c, mode: .shares, value: 1),
        ])
        XCTAssertEqual(r.values.reduce(0, +), 10)
        XCTAssertEqual(r[a], 4)
        XCTAssertEqual(r[b], 3)
        XCTAssertEqual(r[c], 3)
    }

    func testHalfRupeeTotalRoundsAndDistributesAsWholeRupees() throws {
        let ids = [a, b, c, UUID(), UUID()]
        let result = try SplitEngine.compute(total: Decimal(string: "86.50")!,
                                             inputs: ids.map { SplitInput(personID: $0) })
        XCTAssertEqual(result.values.reduce(0, +), 87)
        XCTAssertTrue(result.values.allSatisfy { $0 == Money.whole($0) })
        XCTAssertEqual(result.values.filter { $0 == 18 }.count, 2)
        XCTAssertEqual(result.values.filter { $0 == 17 }.count, 3)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try SplitEngine.compute(total: 0, inputs: [SplitInput(personID: a)])) {
            XCTAssertEqual($0 as? SplitError, .nonPositiveTotal)
        }
        XCTAssertThrowsError(try SplitEngine.compute(total: 10, inputs: [])) {
            XCTAssertEqual($0 as? SplitError, .empty)
        }
    }
}
