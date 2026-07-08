import Foundation

struct TripDetail: Hashable, Sendable {
    var trip: Trip
    var expenses: [Expense]
    var settlementSummary: SettlementSummary
}

protocol AuthRepository: Sendable {
    func appleSignIn(identityToken: String, nonce: String?, fullName: String?, email: String?) async throws -> UserProfile
    func emailLogin(email: String, password: String) async throws -> UserProfile
    func register(name: String, email: String, password: String) async throws -> UserProfile
    func otpStart(identifier: String) async throws -> OTPStartEnvelope
    func otpVerify(challengeId: String, code: String) async throws -> UserProfile
    func me() async throws -> UserProfile
    func updateProfile(name: String?, preferredName: String?, upiID: String?) async throws -> UserProfile
}

protocol TripRepository: Sendable {
    func list() async throws -> [Trip]
    func create(name: String, description: String?, currency: Currency, category: MobileGroup.Category) async throws -> Trip
    func get(id: String) async throws -> TripDetail
    func finalize(id: String) async throws -> TripDetail
}

protocol ParticipantRepository: Sendable {
    func addMember(groupId: String, email: String) async throws -> TripParticipant
}

protocol ExpenseRepository: Sendable {
    func list(groupId: String) async throws -> [Expense]
    func create(groupId: String?, expense: Expense) async throws -> Expense
    func update(id: String, groupId: String?, expense: Expense) async throws -> Expense
    func delete(id: String) async throws
}

protocol SettlementRepository: Sendable {
    // There is no transaction list endpoint. Recorded settlements are visible only through recomputed balances.
    func record(groupId: String?, receiverId: ParticipantID?, senderId: ParticipantID?, amount: Money, note: String?) async throws -> Settlement
}

