import XCTest
@testable import BillBandit

final class DataTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAuthLoginUsesContractPathBodyAndStoresBearerToken() async throws {
        StubURLProtocol.enqueue(statusCode: 200, body: """
        {
          "token": "jwt-123",
          "user": {
            "id": "user-1",
            "name": "Prateek",
            "email": "prateek@example.com",
            "image": null,
            "phone": null,
            "preferredName": "Prateek",
            "upiID": "prateek@upi",
            "isProfileComplete": true
          }
        }
        """)
        let tokenStore = InMemoryTokenStore()
        let auth = LiveAuthRepository(client: makeClient(tokenStore: tokenStore), tokenStore: tokenStore, sessionState: SessionState())

        let user = try await auth.emailLogin(email: "prateek@example.com", password: "password123")

        XCTAssertEqual(user.id, "user-1")
        let storedToken = try await tokenStore.token()
        XCTAssertEqual(storedToken, "jwt-123")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/mobile/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["email"] as? String, "prateek@example.com")
        XCTAssertEqual(body["password"] as? String, "password123")
    }

    func testTripRepositoryUsesGroupEndpointsAndBearerHeader() async throws {
        StubURLProtocol.enqueue(statusCode: 200, body: """
        {
          "groups": [
            {
              "id": "group-1",
              "name": "Goa",
              "description": null,
              "image": null,
              "currency": "INR",
              "category": "TRIP",
              "status": "ACTIVE",
              "finalizedAt": null,
              "finalizedById": null,
              "memberCount": 1,
              "expenseCount": 0,
              "members": [],
              "createdAt": "2026-07-01T00:00:00.000Z",
              "updatedAt": "2026-07-01T00:00:00.000Z"
            }
          ]
        }
        """)
        StubURLProtocol.enqueue(statusCode: 201, body: """
        {
          "group": {
            "id": "group-2",
            "name": "Jaipur",
            "description": "Weekend",
            "image": null,
            "currency": "INR",
            "category": "TRIP",
            "status": "ACTIVE",
            "finalizedAt": null,
            "finalizedById": null,
            "memberCount": 1,
            "expenseCount": 0,
            "members": [],
            "createdAt": null,
            "updatedAt": null
          }
        }
        """)
        let repository = LiveTripRepository(client: makeClient(token: "jwt-abc"), sessionState: SessionState())

        let trips = try await repository.list()
        let created = try await repository.create(name: "Jaipur", description: "Weekend", currency: .inr, category: .trip)

        XCTAssertEqual(trips.first?.id, "group-1")
        XCTAssertEqual(created.id, "group-2")
        XCTAssertEqual(StubURLProtocol.requests[0].url?.path, "/api/mobile/groups")
        XCTAssertEqual(StubURLProtocol.requests[0].httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer jwt-abc")
        XCTAssertEqual(StubURLProtocol.requests[1].url?.path, "/api/mobile/groups")
        XCTAssertEqual(StubURLProtocol.requests[1].httpMethod, "POST")
        let body = try XCTUnwrap(StubURLProtocol.requests[1].jsonBody)
        XCTAssertEqual(body["name"] as? String, "Jaipur")
        XCTAssertEqual(body["description"] as? String, "Weekend")
        XCTAssertEqual(body["currency"] as? String, "INR")
        XCTAssertEqual(body["category"] as? String, "TRIP")
    }

    func testGroupDetailDecodesContractExpenseFixtureAndBalances() async throws {
        StubURLProtocol.enqueue(statusCode: 200, body: groupDetailJSON)
        let repository = LiveTripRepository(client: makeClient(token: "jwt"), sessionState: SessionState())

        let detail = try await repository.get(id: "group-1")

        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/mobile/groups/group-1")
        XCTAssertEqual(detail.trip.name, "Goa Monsoon")
        XCTAssertNil(detail.trip.destination)
        XCTAssertNil(detail.trip.startDate)
        XCTAssertEqual(detail.expenses.first?.amount.minorUnits, 12_345)
        XCTAssertEqual(detail.expenses.first?.splitMethod, .equal)
        XCTAssertEqual(detail.settlementSummary.balances.first?.net.minorUnits, 6_173)
    }

    func testParticipantExpenseSettlementAndFinalizeEndpointsMatchContract() async throws {
        StubURLProtocol.enqueue(statusCode: 201, body: """
        {
          "member": {
            "userId": "user-2",
            "role": "MEMBER",
            "joinedAt": "2026-07-01T00:00:00.000Z",
            "user": {
              "id": "user-2",
              "name": "Esha",
              "email": "esha@example.com",
              "image": null,
              "phone": null,
              "preferredName": null,
              "upiID": null,
              "isProfileComplete": false
            }
          }
        }
        """)
        StubURLProtocol.enqueue(statusCode: 201, body: expenseEnvelopeJSON(id: "expense-1"))
        StubURLProtocol.enqueue(statusCode: 200, body: expenseEnvelopeJSON(id: "expense-1"))
        StubURLProtocol.enqueue(statusCode: 200, body: #"{"success": true}"#)
        StubURLProtocol.enqueue(statusCode: 201, body: """
        {
          "transaction": {
            "id": "txn-1",
            "amount": 50.0,
            "currency": "INR",
            "note": "UPI",
            "group": { "id": "group-1", "name": "Goa" },
            "sender": { "id": "user-2", "name": "Esha", "image": null, "email": "esha@example.com" },
            "receiver": { "id": "user-1", "name": "Prateek", "image": null, "email": "prateek@example.com" },
            "createdAt": "2026-07-01T10:00:00.000Z"
          }
        }
        """)
        StubURLProtocol.enqueue(statusCode: 200, body: groupDetailJSON)

        let client = makeClient(token: "jwt")
        _ = try await LiveParticipantRepository(client: client, sessionState: SessionState()).addMember(groupId: "group-1", email: "esha@example.com")
        let expense = Expense(
            id: "local",
            title: "Taxi",
            amount: Money(minorUnits: 100_00, currency: .inr),
            paidBy: "user-1",
            date: Date(timeIntervalSince1970: 1_783_132_400),
            category: "travel",
            includedParticipants: ["user-1", "user-2"],
            splitMethod: .equal
        )
        _ = try await LiveExpenseRepository(client: client).create(groupId: "group-1", expense: expense)
        _ = try await LiveExpenseRepository(client: client).update(id: "expense-1", groupId: "group-1", expense: expense)
        try await LiveExpenseRepository(client: client).delete(id: "expense-1")
        _ = try await LiveSettlementRepository(client: client).record(groupId: "group-1", receiverId: "user-1", senderId: nil, amount: Money(minorUnits: 50_00), note: "UPI")
        _ = try await LiveTripRepository(client: client, sessionState: SessionState()).finalize(id: "group-1")

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, [
            "/api/mobile/groups/group-1/members",
            "/api/mobile/expenses",
            "/api/mobile/expenses/expense-1",
            "/api/mobile/expenses/expense-1",
            "/api/mobile/transactions",
            "/api/mobile/groups/group-1/finalize"
        ])
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" }, ["POST", "POST", "PUT", "DELETE", "POST", "POST"])
        XCTAssertEqual(try XCTUnwrap(requests[1].jsonBody)["paidById"] as? String, "user-1")
        XCTAssertEqual(try XCTUnwrap(requests[1].jsonBody)["groupId"] as? String, "group-1")
        XCTAssertEqual(try XCTUnwrap(requests[1].jsonBody)["splitType"] as? String, "EQUAL")
        XCTAssertEqual(try XCTUnwrap(requests[4].jsonBody)["receiverId"] as? String, "user-1")
        XCTAssertNil(try XCTUnwrap(requests[4].jsonBody)["senderId"] as? String)
    }

    func testUnauthorizedStatusMapsToUnauthorized() async throws {
        StubURLProtocol.enqueue(statusCode: 401, body: #"{"error":"Unauthorized"}"#)
        let repository = LiveTripRepository(client: makeClient(token: "expired"), sessionState: SessionState())

        do {
            _ = try await repository.list()
            XCTFail("Expected unauthorized")
        } catch APIError.unauthorized {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMoneyMajorUnitRoundTripThroughExpenseRequestAndDTO() throws {
        let expense = Expense(
            id: "expense",
            title: "Coffee",
            amount: Money(apiMajorUnitNumber: 123.45, currency: .inr),
            paidBy: "user-1",
            date: Date(timeIntervalSince1970: 0),
            includedParticipants: ["user-1", "user-2"],
            splitMethod: .exactAmounts([
                "user-1": Money(apiMajorUnitNumber: 23.45, currency: .inr),
                "user-2": Money(apiMajorUnitNumber: 100.00, currency: .inr)
            ])
        )

        let request = try expense.toAPIRequest(groupId: "group-1")
        let dto = MobileExpense(
            id: "expense",
            description: request.description,
            amount: request.amount,
            currency: request.currency,
            date: request.date,
            category: request.category,
            groupId: request.groupId,
            group: nil,
            paidById: request.paidById,
            paidBy: nil,
            splitType: request.splitType,
            notes: request.notes,
            splits: request.splits.map { MobileExpense.Split(userId: $0.userId, amount: $0.amount, percentage: $0.percentage, shares: $0.shares, user: nil) },
            createdAt: nil,
            updatedAt: nil
        )

        XCTAssertEqual(request.amount, 123.45, accuracy: 0.0001)
        XCTAssertEqual(dto.toDomain().amount.minorUnits, 12_345)
        XCTAssertEqual(dto.toDomain().amount.apiMajorUnitNumber, 123.45, accuracy: 0.0001)
    }

    func testMockRepositoriesCreateTripAddExpenseBalancesFlow() async throws {
        let store = MockDataStore()
        let tripRepository = MockTripRepository(store: store)
        let participantRepository = MockParticipantRepository(store: store)
        let expenseRepository = MockExpenseRepository(store: store)

        let trip = try await tripRepository.create(name: "Kerala Backwaters", description: nil, currency: .inr, category: .trip)
        let member = try await participantRepository.addMember(groupId: trip.id, email: "neha@example.com")
        let expense = Expense(
            id: "local",
            title: "Houseboat",
            amount: Money(minorUnits: 8_000_00, currency: .inr),
            paidBy: "user-prateek",
            includedParticipants: ["user-prateek", member.id],
            splitMethod: .equal
        )
        _ = try await expenseRepository.create(groupId: trip.id, expense: expense)

        let detail = try await tripRepository.get(id: trip.id)

        XCTAssertEqual(detail.trip.name, "Kerala Backwaters")
        XCTAssertEqual(detail.expenses.count, 1)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: detail.settlementSummary.balances.map { ($0.participantId, $0.net.minorUnits) })["user-prateek"],
            4_000_00
        )
        XCTAssertEqual(detail.settlementSummary.simplifiedInstructions.first?.from, member.id)
    }

    private func makeClient(token: String? = nil, tokenStore: InMemoryTokenStore? = nil) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(
            baseURL: URL(string: "https://billbandit-api.contenthelper.in")!,
            session: session,
            tokenStore: tokenStore ?? InMemoryTokenStore(token: token)
        )
    }
}

private let groupDetailJSON = """
{
  "group": {
    "id": "group-1",
    "name": "Goa Monsoon",
    "description": null,
    "image": null,
    "currency": "INR",
    "category": "TRIP",
    "status": "ACTIVE",
    "finalizedAt": null,
    "finalizedById": null,
    "memberCount": 2,
    "expenseCount": 1,
    "members": [
      {
        "userId": "user-1",
        "role": "ADMIN",
        "joinedAt": "2026-07-01T00:00:00.000Z",
        "user": {
          "id": "user-1",
          "name": "Prateek",
          "email": "prateek@example.com",
          "image": null,
          "phone": null,
          "preferredName": "Prateek",
          "upiID": "prateek@upi",
          "isProfileComplete": true
        }
      }
    ],
    "expenses": [
      {
        "id": "expense-1",
        "description": "Dinner",
        "amount": 123.45,
        "currency": "INR",
        "date": "2026-07-01T10:00:00.000Z",
        "category": "food",
        "groupId": "group-1",
        "group": { "id": "group-1", "name": "Goa Monsoon" },
        "paidById": "user-1",
        "paidBy": null,
        "splitType": "EQUAL",
        "notes": null,
        "splits": [
          { "userId": "user-1", "amount": 61.72, "percentage": null, "shares": null, "user": null },
          { "userId": "user-2", "amount": 61.73, "percentage": null, "shares": null, "user": null }
        ],
        "createdAt": "2026-07-01T10:00:00.000Z",
        "updatedAt": "2026-07-01T10:00:00.000Z"
      }
    ],
    "createdAt": "2026-07-01T00:00:00.000Z",
    "updatedAt": "2026-07-01T10:00:00.000Z"
  },
  "balances": {
    "netBalances": [
      { "userId": "user-1", "name": "Prateek", "image": null, "netAmount": 61.73 },
      { "userId": "user-2", "name": "Esha", "image": null, "netAmount": -61.73 }
    ],
    "simplifiedDebts": [
      { "fromId": "user-2", "toId": "user-1", "amount": 61.73, "fromName": "Esha", "toName": "Prateek" }
    ]
  }
}
"""

private func expenseEnvelopeJSON(id: String) -> String {
    """
    {
      "expense": {
        "id": "\(id)",
        "description": "Taxi",
        "amount": 100.0,
        "currency": "INR",
        "date": "2026-07-01T10:00:00.000Z",
        "category": "travel",
        "groupId": "group-1",
        "group": { "id": "group-1", "name": "Goa" },
        "paidById": "user-1",
        "paidBy": null,
        "splitType": "EQUAL",
        "notes": null,
        "splits": [
          { "userId": "user-1", "amount": 50.0, "percentage": null, "shares": null, "user": null },
          { "userId": "user-2", "amount": 50.0, "percentage": null, "shares": null, "user": null }
        ],
        "createdAt": "2026-07-01T10:00:00.000Z",
        "updatedAt": "2026-07-01T10:00:00.000Z"
      }
    }
    """
}

private struct CapturedRequest {
    var url: URL?
    var httpMethod: String?
    var headers: [String: String]
    var body: Data?

    func value(forHTTPHeaderField field: String) -> String? {
        headers.first { $0.key.lowercased() == field.lowercased() }?.value
    }

    var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        var statusCode: Int
        var body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [Response] = []
    private nonisolated(unsafe) static var capturedRequests: [CapturedRequest] = []

    static var requests: [CapturedRequest] {
        lock.withLock { capturedRequests }
    }

    static func enqueue(statusCode: Int, body: String) {
        lock.withLock {
            responses.append(Response(statusCode: statusCode, body: Data(body.utf8)))
        }
    }

    static func reset() {
        lock.withLock {
            responses = []
            capturedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBodyStream)
        let captured = CapturedRequest(
            url: request.url,
            httpMethod: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let response = Self.lock.withLock {
            Self.capturedRequests.append(captured)
            return Self.responses.isEmpty ? Response(statusCode: 500, body: Data(#"{"error":"Missing stub"}"#.utf8)) : Self.responses.removeFirst()
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}
