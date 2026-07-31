import Foundation

struct LiveAuthRepository: AuthRepository {
    private let client: APIClient
    private let tokenStore: any TokenStore
    private let sessionState: SessionState

    init(client: APIClient, tokenStore: any TokenStore, sessionState: SessionState) {
        self.client = client
        self.tokenStore = tokenStore
        self.sessionState = sessionState
    }

    func appleSignIn(identityToken: String, nonce: String?, fullName: String?, email: String?) async throws -> UserProfile {
        let envelope: AuthEnvelope = try await client.request(
            .post,
            path: "api/mobile/auth/apple",
            body: AppleSignInRequest(identityToken: identityToken, nonce: nonce, fullName: fullName, email: email),
            authorized: false
        )
        return try await persist(envelope.token, user: envelope.user)
    }

    func emailLogin(email: String, password: String) async throws -> UserProfile {
        let envelope: AuthEnvelope = try await client.request(
            .post,
            path: "api/mobile/auth/login",
            body: EmailLoginRequest(email: email, password: password),
            authorized: false
        )
        return try await persist(envelope.token, user: envelope.user)
    }

    func register(name: String, email: String, password: String) async throws -> UserProfile {
        let envelope: RegisterEnvelope = try await client.request(
            .post,
            path: "api/mobile/auth/register",
            body: RegisterRequest(name: name, email: email, password: password),
            authorized: false
        )
        return try await persist(envelope.token, user: envelope.user)
    }

    func otpStart(identifier: String) async throws -> OTPStartEnvelope {
        try await client.request(
            .post,
            path: "api/mobile/auth/otp/start",
            body: OTPStartRequest(identifier: identifier),
            authorized: false
        )
    }

    func otpVerify(challengeId: String, code: String) async throws -> UserProfile {
        let envelope: AuthEnvelope = try await client.request(
            .post,
            path: "api/mobile/auth/otp/verify",
            body: OTPVerifyRequest(challengeId: challengeId, code: code),
            authorized: false
        )
        return try await persist(envelope.token, user: envelope.user)
    }

    func me() async throws -> UserProfile {
        let envelope: UserEnvelope = try await client.request(.get, path: "api/mobile/auth/me")
        let user = envelope.user.toDomain()
        await sessionState.setCurrentUser(user)
        return user
    }

    func updateProfile(name: String?, preferredName: String?, upiID: String?) async throws -> UserProfile {
        let envelope: UserEnvelope = try await client.request(
            .put,
            path: "api/mobile/auth/profile",
            body: UpdateProfileRequest(name: name, preferredName: preferredName, upiID: upiID)
        )
        let user = envelope.user.toDomain()
        await sessionState.setCurrentUser(user)
        return user
    }

    private func persist(_ token: String, user mobileUser: MobileUser) async throws -> UserProfile {
        try await tokenStore.saveToken(token)
        let user = mobileUser.toDomain()
        await sessionState.setCurrentUser(user)
        return user
    }
}

struct LiveTripRepository: TripRepository {
    private let client: APIClient
    private let sessionState: SessionState

    init(client: APIClient, sessionState: SessionState) {
        self.client = client
        self.sessionState = sessionState
    }

    func list() async throws -> [Trip] {
        let envelope: GroupsEnvelope = try await client.request(.get, path: "api/mobile/groups")
        let currentUserId = await sessionState.currentUser?.id
        return envelope.groups.map { $0.toDomain(currentUserId: currentUserId) }
    }

    func create(name: String, description: String?, currency: Currency = .inr, category: MobileGroup.Category = .trip) async throws -> Trip {
        let envelope: GroupEnvelopeWithoutBalances = try await client.request(
            .post,
            path: "api/mobile/groups",
            body: CreateGroupRequest(name: name, description: description, currency: currency.code, category: category)
        )
        let currentUserId = await sessionState.currentUser?.id
        return envelope.group.toDomain(currentUserId: currentUserId)
    }

    func get(id: String) async throws -> TripDetail {
        let envelope: GroupEnvelope = try await client.request(.get, path: "api/mobile/groups/\(id)")
        return await detail(from: envelope)
    }

    func finalize(id: String) async throws -> TripDetail {
        let envelope: GroupEnvelope = try await client.request(.post, path: "api/mobile/groups/\(id)/finalize")
        return await detail(from: envelope)
    }

    private func detail(from envelope: GroupEnvelope) async -> TripDetail {
        let currentUserId = await sessionState.currentUser?.id
        let currency = Currency(code: envelope.group.currency)
        return TripDetail(
            trip: envelope.group.toDomain(currentUserId: currentUserId),
            expenses: (envelope.group.expenses ?? []).map { $0.toDomain() },
            settlementSummary: envelope.balances.toDomain(currency: currency)
        )
    }
}

private struct GroupEnvelopeWithoutBalances: Decodable, Sendable {
    var group: MobileGroup
}

struct LiveParticipantRepository: ParticipantRepository {
    private let client: APIClient
    private let sessionState: SessionState

    init(client: APIClient, sessionState: SessionState) {
        self.client = client
        self.sessionState = sessionState
    }

    func addMember(groupId: String, email: String) async throws -> TripParticipant {
        let envelope: MemberEnvelope = try await client.request(
            .post,
            path: "api/mobile/groups/\(groupId)/members",
            body: AddMemberRequest(email: email)
        )
        let currentUserId = await sessionState.currentUser?.id
        return envelope.member.toDomain(currentUserId: currentUserId)
    }
}

struct LiveExpenseRepository: ExpenseRepository {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func list(groupId: String) async throws -> [Expense] {
        let envelope: GroupEnvelope = try await client.request(.get, path: "api/mobile/groups/\(groupId)")
        return (envelope.group.expenses ?? []).map { $0.toDomain() }
    }

    func create(groupId: String?, expense: Expense) async throws -> Expense {
        let envelope: ExpenseEnvelope = try await client.request(
            .post,
            path: "api/mobile/expenses",
            body: try expense.toAPIRequest(groupId: groupId)
        )
        return envelope.expense.toDomain()
    }

    func update(id: String, groupId: String?, expense: Expense) async throws -> Expense {
        let envelope: ExpenseEnvelope = try await client.request(
            .put,
            path: "api/mobile/expenses/\(id)",
            body: try expense.toAPIRequest(groupId: groupId)
        )
        return envelope.expense.toDomain()
    }

    func delete(id: String) async throws {
        let envelope: DeleteEnvelope = try await client.request(.delete, path: "api/mobile/expenses/\(id)")
        guard envelope.success else {
            throw APIError.server(statusCode: 200, message: "Delete response did not confirm success")
        }
    }
}

struct LiveSettlementRepository: SettlementRepository {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func record(groupId: String?, receiverId: ParticipantID?, senderId: ParticipantID?, amount: Money, note: String?) async throws -> Settlement {
        let envelope: TransactionEnvelope = try await client.request(
            .post,
            path: "api/mobile/transactions",
            body: CreateTransactionRequest(
                receiverId: receiverId,
                senderId: senderId,
                amount: amount.apiMajorUnitNumber,
                currency: amount.currency.code,
                groupId: groupId,
                note: note
            )
        )
        return envelope.transaction.toDomain()
    }
}

