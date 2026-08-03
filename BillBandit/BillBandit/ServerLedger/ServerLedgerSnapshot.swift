import Foundation

/// Exact-money metadata used by the server-derived ledger read model.
/// `minorUnits` stays a string so the client never parses shared money through
/// floating-point arithmetic.
struct ServerLedgerMoney: Codable, Equatable, Hashable, Sendable {
    let currencyCode: String
    let currencyExponent: Int
    let minorUnits: String

    init(currencyCode: String, currencyExponent: Int, minorUnits: String) {
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.minorUnits = minorUnits
    }
}

/// The smallest server-derived read model carried by this substrate.
///
/// The opaque payload is intentionally left to the later canonical ledger
/// contract. Identity, account ownership, and revision are kept outside it so
/// cache reads can enforce them without decoding a future payload version.
struct ServerLedgerSnapshot: Codable, Equatable, Sendable {
    let accountID: String
    let groupID: String
    let revision: Int64
    let payload: Data
    let fetchedAt: Date
    let money: ServerLedgerMoney?

    init(accountID: String,
         groupID: String,
         revision: Int64,
         payload: Data = Data(),
         fetchedAt: Date = .now,
         money: ServerLedgerMoney? = nil) {
        self.accountID = accountID
        self.groupID = groupID
        self.revision = revision
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.money = money
    }

    init(scope: ServerBackedLedgerScope,
         revision: Int64,
         payload: Data = Data(),
         fetchedAt: Date = .now,
         money: ServerLedgerMoney? = nil) {
        self.init(
            accountID: scope.accountID,
            groupID: scope.groupID,
            revision: revision,
            payload: payload,
            fetchedAt: fetchedAt,
            money: money
        )
    }

    var scope: ServerBackedLedgerScope {
        ServerBackedLedgerScope(accountID: accountID, groupID: groupID)
    }

    var serverGroupID: String { groupID }
    var readModel: Data { payload }
}
