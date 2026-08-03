import Foundation
import SwiftData

enum ServerLedgerCacheError: Error, Equatable, Sendable {
    case invalidSnapshotData
}

/// One account- and server-group-scoped cache row.
///
/// These models are deliberately not added to `AppStore.schema` in this
/// phase. A later migration can opt into them after the server-ledger cutover
/// is ready.
@Model
final class CachedLedgerSnapshot {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var cacheKey: String
    var accountID: String
    var serverGroupID: String
    var scopeKindRaw: String
    var revision: Int64
    var payload: Data
    var currencyCode: String?
    var currencyExponent: Int?
    var currencyMinorUnits: String?
    var updatedAt: Date

    init(id: UUID = UUID(), snapshot: ServerLedgerSnapshot) {
        self.id = id
        self.cacheKey = Self.cacheKey(accountID: snapshot.accountID, groupID: snapshot.groupID)
        self.accountID = snapshot.accountID
        self.serverGroupID = snapshot.groupID
        self.scopeKindRaw = LedgerScopeKind.serverBacked.rawValue
        self.revision = snapshot.revision
        self.payload = snapshot.payload
        self.currencyCode = snapshot.money?.currencyCode
        self.currencyExponent = snapshot.money?.currencyExponent
        self.currencyMinorUnits = snapshot.money?.minorUnits
        self.updatedAt = snapshot.fetchedAt
    }

    static func cacheKey(accountID: String, groupID: String) -> String {
        "\(accountID)::\(groupID)"
    }

    var groupID: String { serverGroupID }
    var snapshotPayload: Data {
        get { payload }
        set { payload = newValue }
    }

    var scope: LedgerScope {
        .serverBacked(accountID: accountID, groupID: serverGroupID)
    }

    func update(from snapshot: ServerLedgerSnapshot) {
        cacheKey = Self.cacheKey(accountID: snapshot.accountID, groupID: snapshot.groupID)
        accountID = snapshot.accountID
        serverGroupID = snapshot.groupID
        scopeKindRaw = LedgerScopeKind.serverBacked.rawValue
        revision = snapshot.revision
        payload = snapshot.payload
        currencyCode = snapshot.money?.currencyCode
        currencyExponent = snapshot.money?.currencyExponent
        currencyMinorUnits = snapshot.money?.minorUnits
        updatedAt = snapshot.fetchedAt
    }

    func decodedSnapshot() throws -> ServerLedgerSnapshot {
        ServerLedgerSnapshot(
            accountID: accountID,
            groupID: serverGroupID,
            revision: revision,
            payload: payload,
            fetchedAt: updatedAt,
            money: currencyCode.map {
                ServerLedgerMoney(
                    currencyCode: $0,
                    currencyExponent: currencyExponent ?? 0,
                    minorUnits: currencyMinorUnits ?? ""
                )
            }
        )
    }
}

// These aliases keep the cache row vocabulary flexible for later store work
// without introducing additional SwiftData entities.
typealias ServerLedgerCacheRecord = CachedLedgerSnapshot
typealias CachedLedger = CachedLedgerSnapshot
