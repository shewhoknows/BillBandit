import XCTest
@testable import BillBandit

final class DomainTests: XCTestCase {
    private let a = "a"
    private let b = "b"
    private let c = "c"

    func testMoneyDecodesApiMajorUnitsAndFormatsINR() {
        let amount = Money(apiMajorUnitNumber: 123.456)

        XCTAssertEqual(amount.minorUnits, 12_346)
        XCTAssertEqual(amount.currency, .inr)
        XCTAssertEqual(amount.apiMajorUnitNumber, 123.46, accuracy: 0.0001)
        XCTAssertTrue(amount.formatted(locale: Locale(identifier: "en_IN")).contains("123.46"))
    }

    func testOnePayerEqualSplitWithOddPaiseRounding() throws {
        let expense = makeExpense(amount: 10_000, paidBy: a, included: [a, b, c], splitMethod: .equal)

        let splits = try SplitEngine.splits(for: expense)

        XCTAssertEqual(amountsByParticipant(splits), [a: 3_334, b: 3_333, c: 3_333])
        XCTAssertEqual(splits.reduce(0) { $0 + $1.amount.minorUnits }, 10_000)
    }

    func testMultiplePayersAcrossExpensesSettleDeterministically() throws {
        let expenses = [
            makeExpense(id: "1", amount: 9_000, paidBy: a, included: [a, b, c], splitMethod: .equal),
            makeExpense(id: "2", amount: 6_000, paidBy: b, included: [a, b, c], splitMethod: .equal)
        ]

        let summary = try SettlementEngine.summary(expenses: expenses)

        XCTAssertEqual(netsByParticipant(summary), [a: 4_000, b: 1_000, c: -5_000])
        XCTAssertEqual(
            summary.simplifiedInstructions,
            [
                SettlementInstruction(from: c, to: a, amount: rupees(4_000)),
                SettlementInstruction(from: c, to: b, amount: rupees(1_000))
            ]
        )
    }

    func testPayerMayBeExcludedFromSplit() throws {
        let expense = makeExpense(amount: 12_000, paidBy: a, included: [b, c], splitMethod: .equal)

        let summary = try SettlementEngine.summary(expenses: [expense])

        XCTAssertEqual(netsByParticipant(summary), [a: 12_000, b: -6_000, c: -6_000])
    }

    func testExactPercentageSharesAndPayerOnlySplits() throws {
        let exact = makeExpense(
            amount: 10_000,
            paidBy: a,
            included: [a, b],
            splitMethod: .exactAmounts([a: rupees(2_500), b: rupees(7_500)])
        )
        XCTAssertEqual(amountsByParticipant(try SplitEngine.splits(for: exact)), [a: 2_500, b: 7_500])

        let percentage = makeExpense(
            amount: 10_001,
            paidBy: a,
            included: [a, b, c],
            splitMethod: .percentages([a: 50, b: 25, c: 25])
        )
        XCTAssertEqual(amountsByParticipant(try SplitEngine.splits(for: percentage)), [a: 5_001, b: 2_500, c: 2_500])

        let shares = makeExpense(
            amount: 10_000,
            paidBy: a,
            included: [a, b, c],
            splitMethod: .shares([a: 1, b: 2, c: 3])
        )
        XCTAssertEqual(amountsByParticipant(try SplitEngine.splits(for: shares)), [a: 1_667, b: 3_333, c: 5_000])

        let payerOnly = makeExpense(amount: 4_200, paidBy: b, included: [a], splitMethod: .payerOnly)
        XCTAssertEqual(amountsByParticipant(try SplitEngine.splits(for: payerOnly)), [b: 4_200])
    }

    func testParticipantRemovedAfterExpenseStillAppearsInLedger() throws {
        let trip = Trip(
            id: "trip",
            name: "Goa",
            destination: nil,
            startDate: nil,
            endDate: nil,
            currency: .inr,
            participants: [TripParticipant(id: a, displayName: "A", kind: .currentUser)],
            status: .active
        )
        let oldExpense = makeExpense(amount: 3_000, paidBy: a, included: [a, b, c], splitMethod: .equal)

        let summary = try SettlementEngine.summary(expenses: [oldExpense])

        XCTAssertEqual(trip.participants.map(\.id), [a])
        XCTAssertEqual(netsByParticipant(summary), [a: 2_000, b: -1_000, c: -1_000])
    }

    func testEditedAndDeletedExpensesRecomputeFromCurrentLedger() throws {
        let original = makeExpense(id: "meal", amount: 9_000, paidBy: a, included: [a, b, c], splitMethod: .equal)
        XCTAssertEqual(netsByParticipant(try SettlementEngine.summary(expenses: [original])), [a: 6_000, b: -3_000, c: -3_000])

        let edited = makeExpense(id: "meal", amount: 12_000, paidBy: a, included: [a, b], splitMethod: .equal)
        XCTAssertEqual(netsByParticipant(try SettlementEngine.summary(expenses: [edited])), [a: 6_000, b: -6_000])

        XCTAssertEqual(try SettlementEngine.summary(expenses: []).balances, [])
        XCTAssertEqual(try SettlementEngine.summary(expenses: []).simplifiedInstructions, [])
    }

    func testZeroExpensesSingleParticipantGuestAndInvitedParticipants() throws {
        let guest = TripParticipant(id: "guest-1", displayName: "Guest", kind: .guest)
        let invited = TripParticipant(id: "invite-1", displayName: "Pending", kind: .invited(email: "pending@example.com"))
        let trip = Trip(
            id: "trip",
            name: "Trip",
            destination: "Mumbai",
            startDate: nil,
            endDate: nil,
            currency: .inr,
            participants: [guest, invited],
            status: .active
        )

        let single = makeExpense(amount: 2_500, paidBy: guest.id, included: [guest.id], splitMethod: .equal)
        let summary = try SettlementEngine.summary(expenses: [single])

        XCTAssertEqual(trip.participants.count, 2)
        XCTAssertEqual(netsByParticipant(summary), [guest.id: 0])
        XCTAssertEqual(summary.simplifiedInstructions, [])
    }

    func testSettlementsZeroSumAndRecordedPaymentsAdjustNet() throws {
        let expense = makeExpense(amount: 9_000, paidBy: a, included: [a, b, c], splitMethod: .equal)
        let settlement = Settlement(id: "s1", from: b, to: a, amount: rupees(3_000))

        let summary = try SettlementEngine.summary(expenses: [expense], settlements: [settlement])

        XCTAssertEqual(netsByParticipant(summary), [a: 3_000, b: 0, c: -3_000])
        XCTAssertEqual(summary.balances.reduce(0) { $0 + $1.net.minorUnits }, 0)
        XCTAssertEqual(summary.simplifiedInstructions, [SettlementInstruction(from: c, to: a, amount: rupees(3_000))])
    }

    func testValidationRejectsInvalidExpenses() {
        XCTAssertThrowsError(
            try SplitEngine.splits(for: makeExpense(amount: -1, paidBy: a, included: [a], splitMethod: .equal))
        ) { XCTAssertEqual($0 as? ExpenseValidationError, .negativeAmount) }

        XCTAssertThrowsError(
            try SplitEngine.splits(for: makeExpense(amount: 1_000, paidBy: a, included: [], splitMethod: .equal))
        ) { XCTAssertEqual($0 as? ExpenseValidationError, .noIncludedParticipants) }

        XCTAssertThrowsError(
            try SplitEngine.splits(for: makeExpense(amount: 1_000, paidBy: a, included: [a, b], splitMethod: .percentages([a: 60, b: 30])))
        )

        XCTAssertThrowsError(
            try SplitEngine.splits(for: makeExpense(amount: 1_000, paidBy: a, included: [a, b], splitMethod: .exactAmounts([a: rupees(400), b: rupees(500)])))
        )

        XCTAssertThrowsError(
            try SplitEngine.splits(for: makeExpense(amount: 1_000, paidBy: a, included: [a, b], splitMethod: .exactAmounts([a: rupees(-100), b: rupees(1_100)])))
        ) { XCTAssertEqual($0 as? ExpenseValidationError, .negativeAmount) }

        XCTAssertThrowsError(
            try SplitEngine.splits(for: makeExpense(amount: 1_000, paidBy: a, included: [a, b], splitMethod: .percentages([a: -10, b: 110])))
        ) { XCTAssertEqual($0 as? ExpenseValidationError, .negativeAmount) }
    }

    func testInviteCodeRoundTripLinkResolutionAndBadChecksumRejection() throws {
        let code = InviteCode.generate(kind: .trip, bytes: [1, 2, 3, 250, 251, 252])
        let parsed = try InviteCode.parse("  \(code.rawValue.lowercased().replacingOccurrences(of: "-", with: " - "))  ")
        let link = InviteLinkResolver.makeLink(code: code)

        XCTAssertEqual(parsed, code)
        XCTAssertEqual(try InviteLinkResolver.resolve(link.url), code)

        let replacement: Character = code.rawValue.last == "2" ? "3" : "2"
        let bad = String(code.rawValue.dropLast()) + String(replacement)
        XCTAssertThrowsError(try InviteCode.parse(bad)) {
            XCTAssertEqual($0 as? InviteCodeError, .badChecksum)
        }
    }

    private func makeExpense(
        id: String = "expense",
        amount: Int,
        paidBy: ParticipantID,
        included: [ParticipantID],
        splitMethod: SplitMethod
    ) -> Expense {
        Expense(
            id: id,
            title: id,
            amount: rupees(amount),
            paidBy: paidBy,
            date: Date(timeIntervalSince1970: 0),
            includedParticipants: included,
            splitMethod: splitMethod
        )
    }

    private func rupees(_ minorUnits: Int) -> Money {
        Money(minorUnits: minorUnits, currency: .inr)
    }

    private func amountsByParticipant(_ splits: [ExpenseSplit]) -> [ParticipantID: Int] {
        Dictionary(uniqueKeysWithValues: splits.map { ($0.participantId, $0.amount.minorUnits) })
    }

    private func netsByParticipant(_ summary: SettlementSummary) -> [ParticipantID: Int] {
        Dictionary(uniqueKeysWithValues: summary.balances.map { ($0.participantId, $0.net.minorUnits) })
    }
}
