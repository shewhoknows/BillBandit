#if DEBUG
import Foundation

actor MockDataStore {
    var currentUser = UserProfile(
        id: "user-prateek",
        name: "Prateek Ranka",
        email: "prateek@example.com",
        imageURL: nil,
        phone: "+919876543210",
        preferredName: "Prateek",
        upiID: "prateek@upi",
        isProfileComplete: true
    )

    var users: [String: UserProfile]
    var trips: [Trip]
    var expensesByGroup: [String: [Expense]]
    var settlementsByGroup: [String: [Settlement]]

    init() {
        let prateek = currentUser
        let esha = UserProfile(
            id: "user-esha",
            name: "Esha Bhoon",
            email: "esha@example.com",
            imageURL: nil,
            phone: "+919811112222",
            preferredName: "Esha",
            upiID: "esha@upi",
            isProfileComplete: true
        )
        let aarav = UserProfile(
            id: "user-aarav",
            name: "Aarav Mehta",
            email: "aarav@example.com",
            imageURL: nil,
            phone: nil,
            preferredName: "Aarav",
            upiID: "aarav@upi",
            isProfileComplete: true
        )
        users = Dictionary(uniqueKeysWithValues: [prateek, esha, aarav].map { ($0.id, $0) })

        let trip = Trip(
            id: "group-goa",
            name: "Goa Monsoon",
            destination: nil,
            startDate: nil,
            endDate: nil,
            currency: .inr,
            participants: [
                TripParticipant(id: prateek.id, displayName: "Prateek", kind: .currentUser, role: .admin),
                TripParticipant(id: esha.id, displayName: "Esha", kind: .friend(friendId: esha.id)),
                TripParticipant(id: aarav.id, displayName: "Aarav", kind: .friend(friendId: aarav.id))
            ],
            status: .active
        )
        trips = [trip]
        expensesByGroup = [
            trip.id: [
                Expense(
                    id: "expense-dinner",
                    title: "Baga dinner",
                    amount: Money(minorUnits: 4_860_00, currency: .inr),
                    paidBy: prateek.id,
                    date: Date(timeIntervalSince1970: 1_783_132_400),
                    category: "food",
                    includedParticipants: [prateek.id, esha.id, aarav.id],
                    splitMethod: .equal
                )
            ]
        ]
        settlementsByGroup = [trip.id: []]
    }

    func authenticate() -> UserProfile {
        currentUser
    }

    func updateProfile(name: String?, preferredName: String?, upiID: String?) -> UserProfile {
        currentUser.name = name ?? currentUser.name
        currentUser.preferredName = preferredName ?? currentUser.preferredName
        currentUser.upiID = upiID ?? currentUser.upiID
        currentUser.isProfileComplete = ((currentUser.name ?? currentUser.preferredName) != nil) && currentUser.upiID != nil
        users[currentUser.id] = currentUser
        return currentUser
    }

    func listTrips() -> [Trip] {
        trips
    }

    func createTrip(name: String, description: String?, currency: Currency) -> Trip {
        let trip = Trip(
            id: "group-\(UUID().uuidString)",
            name: name,
            destination: nil,
            startDate: nil,
            endDate: nil,
            currency: currency,
            participants: [TripParticipant(id: currentUser.id, displayName: currentUser.preferredName ?? currentUser.name ?? "You", kind: .currentUser, role: .admin)],
            status: .active
        )
        trips.insert(trip, at: 0)
        expensesByGroup[trip.id] = []
        settlementsByGroup[trip.id] = []
        return trip
    }

    func tripDetail(id: String) throws -> TripDetail {
        guard let trip = trips.first(where: { $0.id == id }) else {
            throw APIError.notFound
        }
        let expenses = expensesByGroup[id] ?? []
        let settlements = settlementsByGroup[id] ?? []
        return TripDetail(
            trip: trip,
            expenses: expenses,
            settlementSummary: try SettlementEngine.summary(expenses: expenses, settlements: settlements)
        )
    }

    func finalizeTrip(id: String) throws -> TripDetail {
        guard let index = trips.firstIndex(where: { $0.id == id }) else {
            throw APIError.notFound
        }
        trips[index].status = .finalized
        return try tripDetail(id: id)
    }

    func addMember(groupId: String, email: String) throws -> TripParticipant {
        guard let tripIndex = trips.firstIndex(where: { $0.id == groupId }) else {
            throw APIError.notFound
        }
        guard trips[tripIndex].status != .finalized else {
            throw APIError.conflict("Group is finalized")
        }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = users.values.first(where: { $0.email?.lowercased() == normalizedEmail }) ?? UserProfile(
            id: "user-\(UUID().uuidString)",
            name: normalizedEmail.split(separator: "@").first.map(String.init),
            email: normalizedEmail,
            imageURL: nil,
            phone: nil,
            preferredName: normalizedEmail.split(separator: "@").first.map(String.init),
            upiID: nil,
            isProfileComplete: false
        )
        users[user.id] = user
        if trips[tripIndex].participants.contains(where: { $0.id == user.id }) {
            throw APIError.conflict("User is already a member of this group")
        }
        let participant = TripParticipant(
            id: user.id,
            displayName: user.preferredName ?? user.name ?? normalizedEmail,
            kind: user.id == currentUser.id ? .currentUser : .friend(friendId: user.id),
            role: user.id == currentUser.id ? .admin : .member
        )
        trips[tripIndex].participants.append(participant)
        return participant
    }

    func listExpenses(groupId: String) throws -> [Expense] {
        guard trips.contains(where: { $0.id == groupId }) else {
            throw APIError.notFound
        }
        return expensesByGroup[groupId] ?? []
    }

    func upsertExpense(id: String?, groupId: String?, expense: Expense) throws -> Expense {
        guard let groupId else {
            throw APIError.validation("Mock expenses must belong to a trip")
        }
        guard let trip = trips.first(where: { $0.id == groupId }) else {
            throw APIError.notFound
        }
        guard trip.status != .finalized else {
            throw APIError.conflict("Group is finalized")
        }
        var stored = expense
        stored.id = id ?? "expense-\(UUID().uuidString)"
        var expenses = expensesByGroup[groupId] ?? []
        if let index = expenses.firstIndex(where: { $0.id == stored.id }) {
            expenses[index] = stored
        } else {
            expenses.insert(stored, at: 0)
        }
        expensesByGroup[groupId] = expenses
        return stored
    }

    func deleteExpense(id: String) throws {
        for groupId in expensesByGroup.keys {
            if let index = expensesByGroup[groupId]?.firstIndex(where: { $0.id == id }) {
                expensesByGroup[groupId]?.remove(at: index)
                return
            }
        }
        throw APIError.notFound
    }

    func recordSettlement(groupId: String?, receiverId: ParticipantID?, senderId: ParticipantID?, amount: Money, note: String?) throws -> Settlement {
        guard let groupId else {
            throw APIError.validation("Mock settlements must belong to a trip")
        }
        guard (receiverId == nil) != (senderId == nil) else {
            throw APIError.validation("Provide exactly one of receiverId or senderId")
        }
        let settlement = Settlement(
            id: "settlement-\(UUID().uuidString)",
            from: senderId ?? currentUser.id,
            to: receiverId ?? currentUser.id,
            amount: amount,
            note: note
        )
        settlementsByGroup[groupId, default: []].append(settlement)
        return settlement
    }
}

struct MockAuthRepository: AuthRepository {
    let store: MockDataStore

    init(store: MockDataStore = MockDataStore()) {
        self.store = store
    }

    func appleSignIn(identityToken: String, nonce: String?, fullName: String?, email: String?) async throws -> UserProfile {
        await store.authenticate()
    }

    func emailLogin(email: String, password: String) async throws -> UserProfile {
        await store.authenticate()
    }

    func register(name: String, email: String, password: String) async throws -> UserProfile {
        await store.updateProfile(name: name, preferredName: name, upiID: nil)
    }

    func otpStart(identifier: String) async throws -> OTPStartEnvelope {
        OTPStartEnvelope(
            challengeId: "challenge-demo",
            maskedIdentifier: "pr••••••@example.com",
            deliveryChannel: .email,
            expiresInSeconds: 600,
            message: "Mock OTP sent"
        )
    }

    func otpVerify(challengeId: String, code: String) async throws -> UserProfile {
        await store.authenticate()
    }

    func me() async throws -> UserProfile {
        await store.authenticate()
    }

    func updateProfile(name: String?, preferredName: String?, upiID: String?) async throws -> UserProfile {
        await store.updateProfile(name: name, preferredName: preferredName, upiID: upiID)
    }
}

struct MockTripRepository: TripRepository {
    let store: MockDataStore

    init(store: MockDataStore = MockDataStore()) {
        self.store = store
    }

    func list() async throws -> [Trip] {
        await store.listTrips()
    }

    func create(name: String, description: String?, currency: Currency = .inr, category: MobileGroup.Category = .trip) async throws -> Trip {
        await store.createTrip(name: name, description: description, currency: currency)
    }

    func get(id: String) async throws -> TripDetail {
        try await store.tripDetail(id: id)
    }

    func finalize(id: String) async throws -> TripDetail {
        try await store.finalizeTrip(id: id)
    }
}

struct MockParticipantRepository: ParticipantRepository {
    let store: MockDataStore

    init(store: MockDataStore = MockDataStore()) {
        self.store = store
    }

    func addMember(groupId: String, email: String) async throws -> TripParticipant {
        try await store.addMember(groupId: groupId, email: email)
    }
}

struct MockExpenseRepository: ExpenseRepository {
    let store: MockDataStore

    init(store: MockDataStore = MockDataStore()) {
        self.store = store
    }

    func list(groupId: String) async throws -> [Expense] {
        try await store.listExpenses(groupId: groupId)
    }

    func create(groupId: String?, expense: Expense) async throws -> Expense {
        try await store.upsertExpense(id: nil, groupId: groupId, expense: expense)
    }

    func update(id: String, groupId: String?, expense: Expense) async throws -> Expense {
        try await store.upsertExpense(id: id, groupId: groupId, expense: expense)
    }

    func delete(id: String) async throws {
        try await store.deleteExpense(id: id)
    }
}

struct MockSettlementRepository: SettlementRepository {
    let store: MockDataStore

    init(store: MockDataStore = MockDataStore()) {
        self.store = store
    }

    func record(groupId: String?, receiverId: ParticipantID?, senderId: ParticipantID?, amount: Money, note: String?) async throws -> Settlement {
        try await store.recordSettlement(groupId: groupId, receiverId: receiverId, senderId: senderId, amount: amount, note: note)
    }
}
#endif
