import Foundation

struct DataContainer: Sendable {
    var authRepository: any AuthRepository
    var tripRepository: any TripRepository
    var participantRepository: any ParticipantRepository
    var expenseRepository: any ExpenseRepository
    var settlementRepository: any SettlementRepository
    var sessionState: SessionState
    var capabilities: BackendCapabilities
}

enum AppDependencies {
    static func live(baseURL: URL = APIClient.baseURLFromInfoPlist()) -> DataContainer {
        let tokenStore = KeychainTokenStore()
        let sessionState = SessionState()
        let client = APIClient(baseURL: baseURL, tokenStore: tokenStore)
        return DataContainer(
            authRepository: LiveAuthRepository(client: client, tokenStore: tokenStore, sessionState: sessionState),
            tripRepository: LiveTripRepository(client: client, sessionState: sessionState),
            participantRepository: LiveParticipantRepository(client: client, sessionState: sessionState),
            expenseRepository: LiveExpenseRepository(client: client),
            settlementRepository: LiveSettlementRepository(client: client),
            sessionState: sessionState,
            capabilities: .current
        )
    }

    #if DEBUG
    static func mock() -> DataContainer {
        let store = MockDataStore()
        return DataContainer(
            authRepository: MockAuthRepository(store: store),
            tripRepository: MockTripRepository(store: store),
            participantRepository: MockParticipantRepository(store: store),
            expenseRepository: MockExpenseRepository(store: store),
            settlementRepository: MockSettlementRepository(store: store),
            sessionState: SessionState(),
            capabilities: .current
        )
    }
    #endif
}
