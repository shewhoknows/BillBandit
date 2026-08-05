import SwiftUI
import SwiftData
import UIKit
import AuthenticationServices
import Combine

enum ServerLedgerSurfaceLedgerKind: Equatable {
    case shared
    case localOnly
}

enum ServerLedgerSurfaceScopePolicy {
    static func normalizedServerGroupID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func kind(serverGroupID: String?) -> ServerLedgerSurfaceLedgerKind {
        normalizedServerGroupID(serverGroupID) == nil ? .localOnly : .shared
    }

    static func accepts(
        snapshot: ServerLedgerSnapshot,
        accountID: String,
        groupID: String
    ) -> Bool {
        snapshot.accountID == accountID && snapshot.groupID == groupID
    }
}

extension Group {
    /// The API scope is the only shared-ledger identity used by these surfaces.
    /// A local UUID, a CloudKit zone, or a Settle Up launch override is never
    /// enough to select server data.
    var serverLedgerGroupID: String? {
        ServerLedgerSurfaceScopePolicy.normalizedServerGroupID(
            serverGroupId
        )
    }
}

private enum ServerLedgerMinorUnits {
    static func add(_ lhs: String, _ rhs: String) -> String {
        let leftNegative = lhs.first == "-"
        let rightNegative = rhs.first == "-"
        let left = magnitude(lhs)
        let right = magnitude(rhs)

        if leftNegative == rightNegative {
            let sum = addMagnitude(left, right)
            return leftNegative && sum != "0" ? "-\(sum)" : sum
        }

        switch compareMagnitude(left, right) {
        case .orderedSame:
            return "0"
        case .orderedDescending:
            let difference = subtractMagnitude(left, right)
            return leftNegative ? "-\(difference)" : difference
        case .orderedAscending:
            let difference = subtractMagnitude(right, left)
            return rightNegative ? "-\(difference)" : difference
        }
    }

    private static func magnitude(_ value: String) -> String {
        value.first == "-" ? String(value.dropFirst()) : value
    }

    private static func compareMagnitude(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func addMagnitude(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.compactMap { Int(String($0)) }
        let right = rhs.compactMap { Int(String($0)) }
        var index = 0
        var carry = 0
        var result: [Int] = []

        while index < left.count || index < right.count || carry > 0 {
            let a = index < left.count ? left[left.count - index - 1] : 0
            let b = index < right.count ? right[right.count - index - 1] : 0
            let sum = a + b + carry
            result.append(sum % 10)
            carry = sum / 10
            index += 1
        }

        return result.reversed().map(String.init).joined()
    }

    private static func subtractMagnitude(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.compactMap { Int(String($0)) }
        let right = rhs.compactMap { Int(String($0)) }
        var index = 0
        var borrow = 0
        var result: [Int] = []

        while index < left.count {
            var digit = left[left.count - index - 1] - borrow
            let subtrahend = index < right.count ? right[right.count - index - 1] : 0
            if digit < subtrahend {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(digit - subtrahend)
            index += 1
        }

        while result.count > 1, result.last == 0 { result.removeLast() }
        return result.reversed().map(String.init).joined()
    }
}

struct ServerLedgerSurfaceMoney: Codable, Equatable, Hashable, Sendable {
    let minorUnits: String
    let currencyCode: String
    let currencyExponent: Int

    init?(minorUnits: String, currencyCode: String, currencyExponent: Int) {
        guard ServerLedgerMoneyDTO.isCanonicalMinorUnits(minorUnits),
              currencyCode.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
              (0...9).contains(currencyExponent) else { return nil }
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
    }

    init?(_ dto: ServerLedgerMoneyDTO) {
        self.init(
            minorUnits: dto.minorUnits,
            currencyCode: dto.currencyCode,
            currencyExponent: dto.currencyExponent
        )
    }

    var isZero: Bool { minorUnits == "0" }
    var isPositive: Bool { minorUnits != "0" && minorUnits.first != "-" }

    func adding(_ other: ServerLedgerSurfaceMoney) -> ServerLedgerSurfaceMoney? {
        guard currencyCode == other.currencyCode,
              currencyExponent == other.currencyExponent else { return nil }
        return ServerLedgerSurfaceMoney(
            minorUnits: ServerLedgerMinorUnits.add(minorUnits, other.minorUnits),
            currencyCode: currencyCode,
            currencyExponent: currencyExponent
        )
    }

    var absoluteDisplayText: String {
        let rawMagnitude = minorUnits.first == "-" ? String(minorUnits.dropFirst()) : minorUnits
        guard var decimal = Decimal(string: rawMagnitude, locale: Locale(identifier: "en_US_POSIX")) else {
            return rawMagnitude
        }
        var divisor = Decimal(1)
        for _ in 0..<currencyExponent { divisor *= 10 }
        var major = Decimal()
        NSDecimalDivide(&major, &decimal, &divisor, .plain)

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = currencyExponent
        formatter.maximumFractionDigits = currencyExponent
        formatter.groupingSeparator = ","
        let value = formatter.string(from: NSDecimalNumber(decimal: major)) ?? rawMagnitude
        let symbol = AppCurrency(rawValue: currencyCode)?.symbol ?? currencyCode
        return "\(symbol)\(AppCurrency(rawValue: currencyCode)?.separatesSymbol == true ? " " : "")\(value)"
    }
}

struct ServerLedgerSurfaceMember: Codable, Equatable, Hashable, Sendable {
    let memberID: String
    let accountID: String
    let localIdentityID: String?
    let displayName: String
}

struct ServerLedgerSurfaceTransfer: Codable, Equatable, Hashable, Sendable {
    let payerMemberID: String
    let recipientMemberID: String
    let amount: ServerLedgerSurfaceMoney
}

struct ServerLedgerSurfaceActivityItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let type: String
    let groupID: String
    let groupName: String
    let amount: ServerLedgerSurfaceMoney
    let at: Date
}

struct ServerLedgerSurfaceGroup: Identifiable, Codable, Equatable, Sendable {
    let serverGroupID: String
    let accountID: String
    let localGroupID: UUID?
    let name: String
    let readRevision: Int64
    let currentMemberID: String
    let currentAccount: [ServerLedgerSurfaceMoney]
    let members: [ServerLedgerSurfaceMember]
    let transfers: [ServerLedgerSurfaceTransfer]
    let activity: [ServerLedgerSurfaceActivityItem]
    let isStale: Bool
    let isReadOnly: Bool

    var id: String { serverGroupID }

    init(
        serverGroupID: String,
        accountID: String,
        localGroupID: UUID? = nil,
        name: String,
        readRevision: Int64,
        currentMemberID: String,
        currentAccount: [ServerLedgerSurfaceMoney],
        members: [ServerLedgerSurfaceMember] = [],
        transfers: [ServerLedgerSurfaceTransfer] = [],
        activity: [ServerLedgerSurfaceActivityItem] = [],
        isStale: Bool = false,
        isReadOnly: Bool = false
    ) {
        self.serverGroupID = serverGroupID
        self.accountID = accountID
        self.localGroupID = localGroupID
        self.name = name
        self.readRevision = readRevision
        self.currentMemberID = currentMemberID
        self.currentAccount = currentAccount
        self.members = members
        self.transfers = transfers
        self.activity = activity
        self.isStale = isStale
        self.isReadOnly = isReadOnly
    }

    func assigning(localGroupID: UUID?) -> ServerLedgerSurfaceGroup {
        ServerLedgerSurfaceGroup(
            serverGroupID: serverGroupID,
            accountID: accountID,
            localGroupID: localGroupID,
            name: name,
            readRevision: readRevision,
            currentMemberID: currentMemberID,
            currentAccount: currentAccount,
            members: members,
            transfers: transfers,
            activity: activity,
            isStale: isStale,
            isReadOnly: isReadOnly
        )
    }
}

struct ServerLedgerSurfaceSnapshot: Equatable, Sendable {
    let accountID: String
    let readRevision: Int64
    let groups: [ServerLedgerSurfaceGroup]
    let balanceByCurrency: [ServerLedgerSurfaceMoney]
    let isStale: Bool
    let isReadOnly: Bool

    func group(for serverGroupID: String) -> ServerLedgerSurfaceGroup? {
        groups.first { $0.serverGroupID == serverGroupID }
    }

    func group(for localGroupID: UUID) -> ServerLedgerSurfaceGroup? {
        groups.first { $0.localGroupID == localGroupID }
    }

    func friendBalance(for localPersonID: UUID) -> [ServerLedgerSurfaceMoney]? {
        var foundMember = false
        var totals: [String: ServerLedgerSurfaceMoney] = [:]

        for group in groups {
            guard let friend = group.members.first(where: {
                guard let localIdentityID = $0.localIdentityID else { return false }
                return UUID(uuidString: localIdentityID) == localPersonID
            }) else { continue }
            foundMember = true

            for transfer in group.transfers {
                guard transfer.amount.isZero == false else { continue }
                let signed: ServerLedgerSurfaceMoney?
                if transfer.payerMemberID == friend.memberID,
                   transfer.recipientMemberID == group.currentMemberID {
                    signed = transfer.amount
                } else if transfer.payerMemberID == group.currentMemberID,
                          transfer.recipientMemberID == friend.memberID {
                    signed = ServerLedgerSurfaceMoney(
                        minorUnits: transfer.amount.minorUnits.first == "-"
                            ? String(transfer.amount.minorUnits.dropFirst())
                            : "-\(transfer.amount.minorUnits)",
                        currencyCode: transfer.amount.currencyCode,
                        currencyExponent: transfer.amount.currencyExponent
                    )
                } else {
                    signed = nil
                }
                guard let signed else { continue }
                let key = "\(signed.currencyCode):\(signed.currencyExponent)"
                if let existing = totals[key] {
                    totals[key] = existing.adding(signed)
                } else {
                    totals[key] = signed
                }
            }
        }

        guard foundMember else { return nil }
        return totals.values.sorted {
            ($0.currencyCode, $0.currencyExponent) < ($1.currencyCode, $1.currencyExponent)
        }
    }

    var activity: [ServerLedgerSurfaceActivityItem] {
        groups.flatMap(\.activity).sorted {
            if $0.at == $1.at { return $0.id > $1.id }
            return $0.at > $1.at
        }
    }
}

enum ServerLedgerSurfaceProjectionResult: Equatable {
    case empty
    case ready(ServerLedgerSurfaceSnapshot)
    case inconsistent(revisions: Set<Int64>)
    case invalidScope
}

enum ServerLedgerSurfaceProjection {
    static func project(
        accountID: String,
        groups: [ServerLedgerSurfaceGroup]
    ) -> ServerLedgerSurfaceProjectionResult {
        guard groups.isEmpty == false else { return .empty }
        guard groups.allSatisfy({ $0.accountID == accountID }) else { return .invalidScope }
        let revisions = Set(groups.map(\.readRevision))
        guard revisions.count == 1, let readRevision = revisions.first else {
            return .inconsistent(revisions: revisions)
        }

        var totals: [String: ServerLedgerSurfaceMoney] = [:]
        for money in groups.flatMap(\.currentAccount) {
            let key = "\(money.currencyCode):\(money.currencyExponent)"
            if let existing = totals[key] {
                totals[key] = existing.adding(money)
            } else {
                totals[key] = money
            }
        }

        let snapshot = ServerLedgerSurfaceSnapshot(
            accountID: accountID,
            readRevision: readRevision,
            groups: groups,
            balanceByCurrency: totals.values.sorted {
                ($0.currencyCode, $0.currencyExponent) < ($1.currencyCode, $1.currencyExponent)
            },
            isStale: groups.contains { $0.isStale },
            isReadOnly: groups.contains { $0.isReadOnly }
        )
        return .ready(snapshot)
    }
}

enum ServerLedgerSurfaceBalanceAudience {
    case account
    case group
    case friend
}

struct ServerLedgerSurfaceBalancePresentation: Equatable {
    let label: String
    let isPositive: Bool
}

enum ServerLedgerSurfaceBalanceFormatter {
    static func presentation(
        amounts: [ServerLedgerSurfaceMoney],
        audience: ServerLedgerSurfaceBalanceAudience
    ) -> ServerLedgerSurfaceBalancePresentation {
        let nonZero = amounts.filter { !$0.isZero }
        guard !nonZero.isEmpty else {
            return ServerLedgerSurfaceBalancePresentation(label: "settled up", isPositive: false)
        }

        let allPositive = nonZero.allSatisfy(\.isPositive)
        let allNegative = nonZero.allSatisfy { !$0.isPositive }
        let labels = nonZero.map { money -> String in
            let prefix: String
            switch audience {
            case .account, .group:
                prefix = money.isPositive ? "owed " : "owe "
            case .friend:
                prefix = money.isPositive ? "owes you " : "you owe "
            }
            return prefix + money.absoluteDisplayText
        }

        if allPositive || allNegative {
            let prefix: String
            switch audience {
            case .account, .group:
                prefix = allPositive ? "owed " : "owe "
            case .friend:
                prefix = allPositive ? "owes you " : "you owe "
            }
            let joined = nonZero.map(\.absoluteDisplayText).joined(separator: " · ")
            return ServerLedgerSurfaceBalancePresentation(
                label: prefix + joined,
                isPositive: allPositive
            )
        }

        return ServerLedgerSurfaceBalancePresentation(
            label: labels.joined(separator: " · "),
            isPositive: false
        )
    }
}

enum ServerLedgerSurfacePhase: Equatable {
    case signedOut
    case loading
    case ready
    case cached
    case stale
    case empty
    case error
}

struct ServerLedgerSurfaceStatus: Equatable {
    let phase: ServerLedgerSurfacePhase
    let readRevision: Int64?
    let message: String?

    init(
        phase: ServerLedgerSurfacePhase,
        readRevision: Int64? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.readRevision = readRevision
        self.message = message
    }

    var label: String {
        switch phase {
        case .signedOut:
            return ServerLedgerUserFacingCopy.signInForSharedBalances
        case .loading:
            return ServerLedgerUserFacingCopy.loadingSharedBalances
        case .ready:
            return "Shared balances are up to date"
        case .cached:
            return ServerLedgerUserFacingCopy.offlineCachedBalances
        case .stale:
            return ServerLedgerUserFacingCopy.friendlyMessage(message)
                ?? ServerLedgerUserFacingCopy.staleBalances
        case .empty:
            return ServerLedgerUserFacingCopy.noSharedGroups
        case .error:
            return ServerLedgerUserFacingCopy.friendlyMessage(message)
                ?? ServerLedgerUserFacingCopy.sharedBalancesUnavailable
        }
    }

    var canDisplayCachedBalances: Bool {
        phase == .ready || phase == .cached || phase == .stale
    }
}

private struct ServerLedgerSurfaceReadEnvelope: Decodable {
    let contractVersion: Int
    let scope: ServerLedgerScopeDTO
    let readRevision: Int64
    let stale: ServerLedgerStaleStateDTO
    let migration: ServerLedgerMigrationDTO
    let data: ServerLedgerSurfaceReadData
}

private struct ServerLedgerSurfaceReadData: Decodable {
    let group: ServerLedgerSurfaceReadGroup
}

private struct ServerLedgerSurfaceReadGroup: Decodable {
    let groupID: String
    let accountID: String
    let name: String
    let localOnly: Bool
    let readRevision: Int64
    let members: [ServerLedgerSurfaceReadMember]
    let balances: ServerLedgerSurfaceReadBalances
    let settlementPlan: ServerLedgerSurfaceReadPlan
    let activity: [ServerLedgerSurfaceReadActivity]
    let migration: ServerLedgerMigrationDTO
    let stale: ServerLedgerStaleStateDTO

    private enum CodingKeys: String, CodingKey {
        case groupID = "groupId"
        case accountID = "accountId"
        case name
        case localOnly
        case readRevision
        case members
        case balances
        case settlementPlan
        case activity
        case migration
        case stale
    }
}

private struct ServerLedgerSurfaceReadMember: Decodable {
    let memberID: String
    let accountID: String
    let localIdentityID: String?
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case memberID = "memberId"
        case accountID = "accountId"
        case localIdentityID = "localIdentityId"
        case displayName
    }
}

private struct ServerLedgerSurfaceReadBalances: Decodable {
    let currentAccount: ServerLedgerSurfaceReadMemberBalance
}

private struct ServerLedgerSurfaceReadMemberBalance: Decodable {
    let memberID: String
    let byCurrency: [ServerLedgerMoneyDTO]

    private enum CodingKeys: String, CodingKey {
        case memberID = "memberId"
        case byCurrency
    }
}

private struct ServerLedgerSurfaceReadPlan: Decodable {
    let transfers: [ServerLedgerSurfaceReadTransfer]
}

private struct ServerLedgerSurfaceReadTransfer: Decodable {
    let payerMemberID: String
    let recipientMemberID: String
    let amount: ServerLedgerMoneyDTO

    private enum CodingKeys: String, CodingKey {
        case payerMemberID = "payerMemberId"
        case recipientMemberID = "recipientMemberId"
        case amount
    }
}

private struct ServerLedgerSurfaceReadActivity: Decodable {
    let activityID: String
    let type: String
    let amount: ServerLedgerMoneyDTO
    let at: String

    private enum CodingKeys: String, CodingKey {
        case activityID = "activityId"
        case type
        case amount
        case at
    }
}

@MainActor
final class ServerLedgerSurfaceStore: ObservableObject {
    static let shared = ServerLedgerSurfaceStore()
    static let accountIDDefaultsKey = "serverLedgerAccountID"

    @Published private(set) var snapshot: ServerLedgerSurfaceSnapshot?
    @Published private(set) var status = ServerLedgerSurfaceStatus(phase: .signedOut)

    private let cacheStore: ServerLedgerStore
    private let sync: ServerLedgerSync
    private var activeAccountID: String?
    private var refreshGeneration = 0

    var hasSharedGroups: Bool { snapshot?.groups.isEmpty == false }

    private init() {
        let store = AppStore.serverLedgerStore
        cacheStore = store
        sync = ServerLedgerSync(store: store, apiClient: URLSessionServerLedgerAPIClient.live())
        activeAccountID = UserDefaults.standard.string(forKey: Self.accountIDDefaultsKey)
    }

    func accountDidAuthenticate(_ rawAccountID: String) {
        let accountID = rawAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else { return }
        do {
            if activeAccountID != accountID || sync.activeAccountID != accountID {
                refreshGeneration &+= 1
                try sync.activate(accountID: accountID)
                snapshot = nil
                status = ServerLedgerSurfaceStatus(phase: .loading)
            }
            activeAccountID = accountID
            UserDefaults.standard.set(accountID, forKey: Self.accountIDDefaultsKey)
        } catch {
            activeAccountID = nil
            snapshot = nil
            status = ServerLedgerSurfaceStatus(phase: .error, message: ServerLedgerUserFacingCopy.friendlyErrorMessage(error))
        }
    }

    func accountDidSignOut(accountID: String? = nil) {
        let account = accountID ?? activeAccountID ?? sync.activeAccountID
        if let account { try? sync.signOut(accountID: account) }
        refreshGeneration &+= 1
        activeAccountID = nil
        snapshot = nil
        status = ServerLedgerSurfaceStatus(phase: .signedOut)
        UserDefaults.standard.removeObject(forKey: Self.accountIDDefaultsKey)
    }

    func groupBalancePresentation(for serverGroupID: String) -> ServerLedgerSurfaceBalancePresentation? {
        guard let group = snapshot?.group(for: serverGroupID) else { return nil }
        return ServerLedgerSurfaceBalanceFormatter.presentation(
            amounts: group.currentAccount,
            audience: .group
        )
    }

    func accountBalancePresentation() -> ServerLedgerSurfaceBalancePresentation? {
        guard let snapshot else { return nil }
        return ServerLedgerSurfaceBalanceFormatter.presentation(
            amounts: snapshot.balanceByCurrency,
            audience: .account
        )
    }

    func friendBalancePresentation(for localPersonID: UUID) -> ServerLedgerSurfaceBalancePresentation? {
        guard let amounts = snapshot?.friendBalance(for: localPersonID) else { return nil }
        return ServerLedgerSurfaceBalanceFormatter.presentation(amounts: amounts, audience: .friend)
    }

    func hasCanonicalMembership(for localPersonID: UUID) -> Bool {
        snapshot?.groups.contains { group in
            group.members.contains { member in
                guard let localIdentityID = member.localIdentityID else { return false }
                return UUID(uuidString: localIdentityID) == localPersonID
            }
        } == true
    }

    func refresh(groups: [Group]) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let sharedGroups = groups.compactMap { group -> (Group, String)? in
            guard let serverGroupID = group.serverLedgerGroupID else { return nil }
            return (group, serverGroupID)
        }

        guard sharedGroups.isEmpty == false else {
            guard generation == refreshGeneration else { return }
            snapshot = nil
            status = ServerLedgerSurfaceStatus(phase: .empty)
            return
        }

        guard let accountID = await ensureActiveAccount() else { return }
        guard generation == refreshGeneration else { return }

        var cachedGroups = [ServerLedgerSurfaceGroup]()
        for (group, serverGroupID) in sharedGroups {
            guard let cached = cachedSnapshot(
                for: ServerBackedLedgerScope(accountID: accountID, groupID: serverGroupID)
            ),
            ServerLedgerSurfaceScopePolicy.accepts(
                snapshot: cached,
                accountID: accountID,
                groupID: serverGroupID
            ),
            let model = try? makeSurfaceGroup(
                snapshot: cached,
                localGroupID: group.id
            ) else { continue }
            cachedGroups.append(model)
        }

        if cachedGroups.count == sharedGroups.count {
            applyCachedProjection(cachedGroups, accountID: accountID, generation: generation)
        } else {
            status = ServerLedgerSurfaceStatus(
                phase: .loading,
                readRevision: snapshot?.readRevision
            )
        }

        sync.markReconnected()
        var freshGroups = [ServerLedgerSurfaceGroup]()
        var errors = [Error]()
        var usedCache = false

        for (group, serverGroupID) in sharedGroups {
            guard generation == refreshGeneration else { return }
            let scope = ServerBackedLedgerScope(accountID: accountID, groupID: serverGroupID)
            do {
                let fresh = try await sync.refresh(scope: scope)
                guard ServerLedgerSurfaceScopePolicy.accepts(
                    snapshot: fresh,
                    accountID: accountID,
                    groupID: serverGroupID
                ) else {
                    errors.append(ServerLedgerSyncError.snapshotScopeMismatch)
                    continue
                }
                freshGroups.append(try makeSurfaceGroup(snapshot: fresh, localGroupID: group.id))
            } catch {
                errors.append(error)
                if let cached = cachedSnapshot(for: scope),
                   ServerLedgerSurfaceScopePolicy.accepts(
                       snapshot: cached,
                       accountID: accountID,
                       groupID: serverGroupID
                   ),
                   let model = try? makeSurfaceGroup(snapshot: cached, localGroupID: group.id) {
                    freshGroups.append(model)
                    usedCache = true
                }
            }
        }

        guard generation == refreshGeneration else { return }
        guard freshGroups.count == sharedGroups.count else {
            if snapshot == nil { status = failureStatus(errors.first) }
            else {
                status = ServerLedgerSurfaceStatus(
                    phase: .stale,
                    readRevision: snapshot?.readRevision,
                    message: errors.first.map { ServerLedgerUserFacingCopy.friendlyErrorMessage($0) }
                )
            }
            return
        }

        switch ServerLedgerSurfaceProjection.project(accountID: accountID, groups: freshGroups) {
        case .empty:
            snapshot = nil
            status = ServerLedgerSurfaceStatus(phase: .empty)
        case .invalidScope:
            status = ServerLedgerSurfaceStatus(
                phase: .error,
                readRevision: snapshot?.readRevision,
                message: "Shared ledger scope mismatch"
            )
        case let .inconsistent(revisions):
            status = ServerLedgerSurfaceStatus(
                phase: .stale,
                readRevision: snapshot?.readRevision,
                message: "Shared groups are at different revisions (\(revisions.sorted().map { String($0) }.joined(separator: ", ")))."
            )
        case let .ready(projected):
            snapshot = projected
            let phase: ServerLedgerSurfacePhase
            if projected.isStale {
                phase = .stale
            } else if usedCache {
                phase = .cached
            } else if errors.isEmpty {
                phase = .ready
            } else {
                phase = .cached
            }
            status = ServerLedgerSurfaceStatus(
                phase: phase,
                readRevision: projected.readRevision,
                message: errors.first.map { ServerLedgerUserFacingCopy.friendlyErrorMessage($0) }
            )
        }
    }

    private func applyCachedProjection(
        _ groups: [ServerLedgerSurfaceGroup],
        accountID: String,
        generation: Int
    ) {
        guard generation == refreshGeneration else { return }
        switch ServerLedgerSurfaceProjection.project(accountID: accountID, groups: groups) {
        case .empty:
            break
        case .invalidScope:
            status = ServerLedgerSurfaceStatus(
                phase: .error,
                readRevision: snapshot?.readRevision,
                message: "Shared ledger scope mismatch"
            )
        case let .inconsistent(revisions):
            status = ServerLedgerSurfaceStatus(
                phase: .stale,
                readRevision: snapshot?.readRevision,
                message: "Shared groups are at different revisions (\(revisions.sorted().map { String($0) }.joined(separator: ", ")))."
            )
        case let .ready(projected):
            snapshot = projected
            status = ServerLedgerSurfaceStatus(
                phase: .cached,
                readRevision: projected.readRevision,
                message: ServerLedgerUserFacingCopy.offlineCachedBalances
            )
        }
    }

    private func ensureActiveAccount() async -> String? {
        guard UsernameIdentityService.hasStoredSession else {
            snapshot = nil
            activeAccountID = nil
            status = ServerLedgerSurfaceStatus(phase: .signedOut)
            return nil
        }

        if let activeAccountID {
            if sync.activeAccountID != activeAccountID { try? sync.activate(accountID: activeAccountID) }
            return activeAccountID
        }

        if let stored = UserDefaults.standard.string(forKey: Self.accountIDDefaultsKey),
           !stored.isEmpty {
            accountDidAuthenticate(stored)
            return activeAccountID
        }

        do {
            let remoteUser = try await UsernameIdentityService.currentUser()
            accountDidAuthenticate(remoteUser.id)
            return activeAccountID
        } catch {
            status = ServerLedgerSurfaceStatus(phase: .error, message: ServerLedgerUserFacingCopy.friendlyErrorMessage(error))
            return nil
        }
    }

    private func makeSurfaceGroup(
        snapshot: ServerLedgerSnapshot,
        localGroupID: UUID
    ) throws -> ServerLedgerSurfaceGroup {
        let envelope = try JSONDecoder.serverLedger.decode(
            ServerLedgerSurfaceReadEnvelope.self,
            from: snapshot.payload
        )
        let group = envelope.data.group
        guard envelope.contractVersion == ServerLedgerContract.version,
              envelope.scope.kind == .shared,
              envelope.scope.localOnly == false,
              envelope.scope.accountID == snapshot.accountID,
              envelope.scope.groupID == snapshot.groupID,
              group.localOnly == false,
              group.accountID == snapshot.accountID,
              group.groupID == snapshot.groupID,
              group.readRevision == envelope.readRevision,
              envelope.readRevision == snapshot.revision else {
            throw ServerLedgerAPIClientError.snapshotScopeMismatch
        }

        let currentAccount = try group.balances.currentAccount.byCurrency.map {
            guard let money = ServerLedgerSurfaceMoney($0) else {
                throw ServerLedgerDTOError.invalidMoney(path: "data.group.balances.currentAccount")
            }
            return money
        }
        let members = group.members.map {
            ServerLedgerSurfaceMember(
                memberID: $0.memberID,
                accountID: $0.accountID,
                localIdentityID: $0.localIdentityID,
                displayName: $0.displayName
            )
        }
        let transfers = try group.settlementPlan.transfers.map {
            guard let amount = ServerLedgerSurfaceMoney($0.amount) else {
                throw ServerLedgerDTOError.invalidMoney(path: "data.group.settlementPlan.transfers")
            }
            return ServerLedgerSurfaceTransfer(
                payerMemberID: $0.payerMemberID,
                recipientMemberID: $0.recipientMemberID,
                amount: amount
            )
        }
        let activity = try group.activity.map {
            guard let amount = ServerLedgerSurfaceMoney($0.amount) else {
                throw ServerLedgerDTOError.invalidMoney(path: "data.group.activity")
            }
            guard let at = parseISO8601Date($0.at) else {
                throw ServerLedgerAPIClientError.invalidResponse
            }
            return ServerLedgerSurfaceActivityItem(
                id: $0.activityID,
                type: $0.type,
                groupID: group.groupID,
                groupName: group.name,
                amount: amount,
                at: at
            )
        }

        let migrationReadOnly = ["pending", "in_progress", "blocked"].contains(group.migration.status)
            || ["pending", "in_progress", "blocked"].contains(envelope.migration.status)
        return ServerLedgerSurfaceGroup(
            serverGroupID: group.groupID,
            accountID: group.accountID,
            localGroupID: localGroupID,
            name: group.name,
            readRevision: envelope.readRevision,
            currentMemberID: group.balances.currentAccount.memberID,
            currentAccount: currentAccount,
            members: members,
            transfers: transfers,
            activity: activity,
            isStale: group.stale.isStale || envelope.stale.isStale,
            isReadOnly: migrationReadOnly || group.stale.isStale || envelope.stale.isStale
        )
    }

    private func failureStatus(_ error: Error?) -> ServerLedgerSurfaceStatus {
        if let error {
            return ServerLedgerSurfaceStatus(
                phase: .error,
                message: ServerLedgerUserFacingCopy.friendlyErrorMessage(error)
            )
        }
        return ServerLedgerSurfaceStatus(
            phase: .error,
            message: ServerLedgerUserFacingCopy.sharedBalancesUnavailable
        )
    }

    private func cachedSnapshot(for scope: ServerBackedLedgerScope) -> ServerLedgerSnapshot? {
        do {
            return try cacheStore.cachedSnapshot(for: scope)
        } catch {
            return nil
        }
    }

    private func parseISO8601Date(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: rawValue)
        }()
    }
}

struct ServerLedgerSurfaceStatusView: View {
    @ObservedObject var ledger: ServerLedgerSurfaceStore
    var includeEmpty = false
    var onLight = false
    var onRetry: (() -> Void)?

    private var showsRetry: Bool {
        ledger.status.phase == .error || ledger.status.phase == .stale
    }

    var body: some View {
        if includeEmpty || ledger.status.phase != .empty {
            SwiftUI.Group {
                if showsRetry, let onRetry {
                    Button(action: onRetry) {
                        statusContent
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Retries loading shared balances")
                } else {
                    statusContent
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sharedLedgerStatus")
        }
    }

    private var statusContent: some View {
        HStack(spacing: 7) {
            BrandIconView(icon: .pulse, size: 13)
            Text(ledger.status.label)
                .font(BrandFont.type(9, bold: true))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if showsRetry, onRetry != nil {
                Text("retry")
                    .font(BrandFont.type(8.5, bold: true))
                    .opacity(0.72)
            }
        }
        .foregroundStyle(onLight ? Color.Brand.cobalt.opacity(0.78) : Color.Brand.creamSoft.opacity(0.78))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (onLight ? Color.Brand.cobalt : Color.Brand.creamSoft).opacity(0.10),
            in: Capsule()
        )
    }
}

struct ServerLedgerBalanceChip: View {
    let presentation: ServerLedgerSurfaceBalancePresentation
    var onLight = false

    var body: some View {
        Text(presentation.label)
            .font(BrandFont.type(10.5, bold: true))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(onLight ? Color.Brand.cobalt : Color.Brand.creamSoft)
            .overlay(Capsule().stroke(
                onLight ? Color.Brand.cobalt : Color.Brand.creamSoft,
                lineWidth: onLight ? 2.5 : 1.8
            ))
            .accessibilityLabel(presentation.label)
    }
}

struct ServerLedgerUnavailableChip: View {
    var onLight = false
    var isLoading = false

    var body: some View {
        Text(isLoading
             ? ServerLedgerUserFacingCopy.loadingBalance
             : ServerLedgerUserFacingCopy.balanceUnavailable)
            .font(BrandFont.type(9, bold: true))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(onLight ? Color.Brand.cobalt.opacity(0.68) : Color.Brand.creamSoft.opacity(0.74))
            .overlay(Capsule().stroke(
                onLight ? Color.Brand.cobalt.opacity(0.6) : Color.Brand.creamSoft.opacity(0.7),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    dash: isLoading ? [] : [3, 3]
                )
            ))
            .accessibilityLabel(isLoading
                                ? ServerLedgerUserFacingCopy.loadingBalance
                                : ServerLedgerUserFacingCopy.balanceUnavailable)
    }
}

enum AppleCredentialGateDecision: Equatable {
    case authorize
    case preserveSession
    case signOut
}

enum AppleCredentialGatePolicy {
    static func shouldRequestCredentialState(
        hasIdentifier: Bool,
        accountOnboardingComplete: Bool,
        deferNextCheck: Bool,
        credentialStateChecksAreReliable: Bool = true
    ) -> Bool {
        hasIdentifier && accountOnboardingComplete && !deferNextCheck &&
            credentialStateChecksAreReliable
    }

    static func decision(
        for state: ASAuthorizationAppleIDProvider.CredentialState,
        error: Error?
    ) -> AppleCredentialGateDecision {
        guard error == nil else { return .preserveSession }
        switch state {
        case .authorized:
            return .authorize
        case .revoked, .transferred:
            return .signOut
        case .notFound:
            return .preserveSession
        @unknown default:
            return .preserveSession
        }
    }
}

struct AppleAccountBootstrapAccount: Equatable {
    let identifier: String
    let sessionIsActive: Bool?
}

enum AppleAccountBootstrapDecision: Equatable {
    case authenticate(identifier: String, recoveredFromProfile: Bool)
    case signedOut
    case ambiguous
}

enum AppleAccountBootstrapPolicy {
    static func decision(
        storedIdentifier: String?,
        currentAccounts: [AppleAccountBootstrapAccount]
    ) -> AppleAccountBootstrapDecision {
        let normalizedAccounts = currentAccounts.compactMap { account -> AppleAccountBootstrapAccount? in
            let identifier = account.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { return nil }
            return .init(identifier: identifier, sessionIsActive: account.sessionIsActive)
        }
        let distinctIdentifiers = Set(normalizedAccounts.map(\.identifier))
        let stored = storedIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if let stored {
            if normalizedAccounts.contains(where: {
                $0.identifier == stored && $0.sessionIsActive == false
            }) {
                return .signedOut
            }
            return .authenticate(identifier: stored, recoveredFromProfile: false)
        }

        guard distinctIdentifiers.count <= 1 else { return .ambiguous }
        guard let identifier = distinctIdentifiers.first else { return .signedOut }
        guard normalizedAccounts.contains(where: {
            $0.identifier == identifier && $0.sessionIsActive != false
        }) else {
            return .signedOut
        }
        return .authenticate(identifier: identifier, recoveredFromProfile: true)
    }
}

enum AccountOnboardingAccessPolicy {
    static func mayEnterApp(hasAppleIdentifier: Bool,
                            accountOnboardingComplete: Bool) -> Bool {
        hasAppleIdentifier && accountOnboardingComplete
    }
}

struct AppRootView: View {
    private enum AccountGateState: Equatable { case checking, signedOut, authorized }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("accountOnboardingComplete") private var accountOnboardingComplete = false
    @AppStorage("appleUserIdentifier") private var appleUserIdentifier = ""
    @AppStorage("applePrivateEmail") private var applePrivateEmail = ""
    @AppStorage("usernameHandleVerified") private var usernameHandleVerified = false
    @AppStorage("deferNextAppleCredentialStateCheck") private var deferNextAppleCredentialStateCheck = false
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accountGateState: AccountGateState = .checking

    private var bypassOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-skipOnboarding") || args.contains("-tab") ||
            args.contains("-showAdd") || args.contains("-showAddFriend") ||
            args.contains("-showProfile") || args.contains("-showMotionLab") ||
            args.contains("-openGroup")
    }

    private var forceSignedOutOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-forceSignedOutOnboarding")
    }

    private var forceConnectedIncompleteOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-onboardingConnectedIncomplete")
    }

    private var credentialStateChecksAreReliable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    var body: some View {
        SwiftUI.Group {
            if bypassOnboarding {
                RootTabView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else if accountGateState == .authorized &&
                        AccountOnboardingAccessPolicy.mayEnterApp(
                            hasAppleIdentifier: !appleUserIdentifier.isEmpty,
                            accountOnboardingComplete: accountOnboardingComplete
                        ) && usernameHandleVerified {
                RootTabView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else if accountGateState == .checking {
                accountCheckView
                    .transition(.opacity)
            } else {
                OnboardingScreen(startAtSignIn: hasCompletedOnboarding) {
                    withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
                        hasCompletedOnboarding = true
                        accountOnboardingComplete = true
                        accountGateState = .authorized
                    }
                }
                .transition(.opacity)
            }
        }
        .task { await prepareAccountGate() }
    }

    private var accountCheckView: some View {
        ZStack {
            Color.Brand.cobalt.ignoresSafeArea()
            VStack(spacing: 16) {
                MascotView(mascot: .thinking, size: 152, idle: false)
                Text("checking your lookout pass…")
                    .font(BrandFont.hand(25, weight: .bold))
                    .foregroundStyle(Color.Brand.creamSoft)
                ProgressView().tint(Color.Brand.creamSoft)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checking Apple sign in")
    }

    @MainActor
    private func prepareAccountGate() async {
        AppStore.seedIfNeeded(context: context)
        if forceConnectedIncompleteOnboarding {
            appleUserIdentifier = "ui-test-connected-apple-account"
            accountOnboardingComplete = false
            usernameHandleVerified = false
            accountGateState = .signedOut
            return
        }
        if forceSignedOutOnboarding {
            ServerLedgerSurfaceStore.shared.accountDidSignOut()
            verifyAppleCredential()
            return
        }
        if bypassOnboarding {
            // UI-test launch flags skip the onboarding screen, but they must
            // not skip session reconciliation when a real mobile session is
            // present. This keeps a relaunch from displaying the previous
            // Apple account's local current-user row.
            if !appleUserIdentifier.isEmpty && UsernameIdentityService.hasStoredSession {
                await reconcileUsernameAndVerifyAppleCredential()
            } else {
                verifyAppleCredential()
            }
            return
        }

        let people = (try? context.fetch(
            FetchDescriptor<Person>(predicate: #Predicate { $0.isCurrentUser })
        )) ?? []
        let currentAccounts = people.compactMap { person -> AppleAccountBootstrapAccount? in
            guard let identifier = person.appleUserIdentifier else { return nil }
            let sessionIsActive: Bool?
            switch person.appleSessionStateRaw {
            case "active": sessionIsActive = true
            case "userSignedOut", "providerRevoked": sessionIsActive = false
            default: sessionIsActive = nil
            }
            return .init(
                identifier: identifier,
                sessionIsActive: sessionIsActive
            )
        }
        switch AppleAccountBootstrapPolicy.decision(
            storedIdentifier: appleUserIdentifier,
            currentAccounts: currentAccounts
        ) {
        case .authenticate(let identifier, _):
            appleUserIdentifier = identifier
            if AccountOnboardingAccessPolicy.mayEnterApp(
                hasAppleIdentifier: true,
                accountOnboardingComplete: accountOnboardingComplete
            ) {
                await reconcileUsernameAndVerifyAppleCredential()
            } else {
                accountGateState = .signedOut
            }
        case .signedOut, .ambiguous:
            appleUserIdentifier = ""
            applePrivateEmail = ""
            accountOnboardingComplete = false
            usernameHandleVerified = false
            UsernameIdentityService.signOut()
            CloudCollaborationService.shared.accountDidSignOut()
            ServerLedgerSurfaceStore.shared.accountDidSignOut()
            accountGateState = .signedOut
        }
    }

    @MainActor
    private func reconcileUsernameAndVerifyAppleCredential() async {
        guard UsernameIdentityService.hasStoredSession else {
            ServerLedgerSurfaceStore.shared.accountDidSignOut()
            usernameHandleVerified = false
            accountGateState = .signedOut
            return
        }

        do {
            let remoteUser = try await UsernameIdentityService.currentUser()
            ServerLedgerSurfaceStore.shared.accountDidAuthenticate(remoteUser.id)
            switch UsernameAccountReconciliationPolicy.decision(
                remoteUsername: remoteUser.username
            ) {
            case .verified(let username):
                let current = AccountProfileIntegrity.canonicalize(
                    appleUserIdentifier: appleUserIdentifier,
                    cloudUserRecordName: nil,
                    context: context
                )
                let nameChanged = current.name != username
                if nameChanged {
                    current.name = username
                    current.profileUpdatedAt = .now
                }
                current.appleSessionStateRaw = "active"
                try context.save()
                usernameHandleVerified = true
                if nameChanged {
                    CloudCollaborationService.shared.currentPersonDidChange()
                }
                verifyAppleCredential()
            case .requiresClaim:
                usernameHandleVerified = false
                accountGateState = .signedOut
            }
        } catch {
            if UsernameIdentityService.hasStoredSession {
                // A temporary backend outage must not lock a previously verified
                // account out of its local ledger. The server remains the atomic
                // authority for every new claim and rename.
                verifyAppleCredential()
            } else {
                ServerLedgerSurfaceStore.shared.accountDidSignOut()
                usernameHandleVerified = false
                accountGateState = .signedOut
            }
        }
    }

    private func verifyAppleCredential() {
        if forceSignedOutOnboarding {
            accountGateState = .signedOut
            return
        }
        guard !bypassOnboarding else {
            accountGateState = .authorized
            return
        }
        guard !appleUserIdentifier.isEmpty else {
            accountGateState = .signedOut
            accountOnboardingComplete = false
            return
        }
        guard AppleCredentialGatePolicy.shouldRequestCredentialState(
            hasIdentifier: true,
            accountOnboardingComplete: accountOnboardingComplete,
            deferNextCheck: deferNextAppleCredentialStateCheck,
            credentialStateChecksAreReliable: credentialStateChecksAreReliable
        ) else {
            if deferNextAppleCredentialStateCheck {
                deferNextAppleCredentialStateCheck = false
            }
            persistSession(isActive: true, identifier: appleUserIdentifier)
            accountGateState = .authorized
            return
        }
        accountGateState = .checking
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserIdentifier) { state, error in
            let decision = AppleCredentialGatePolicy.decision(for: state, error: error)
            DispatchQueue.main.async {
                switch decision {
                case .authorize, .preserveSession:
                    persistSession(isActive: true, identifier: appleUserIdentifier)
                    accountGateState = .authorized
                case .signOut:
                    persistSession(isActive: false, identifier: appleUserIdentifier)
                    appleUserIdentifier = ""
                    applePrivateEmail = ""
                    accountOnboardingComplete = false
                    usernameHandleVerified = false
                    UsernameIdentityService.signOut()
                    CloudCollaborationService.shared.accountDidSignOut()
                    ServerLedgerSurfaceStore.shared.accountDidSignOut()
                    accountGateState = .signedOut
                }
            }
        }
    }

    private func persistSession(isActive: Bool, identifier: String) {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else { return }
        let people = (try? context.fetch(
            FetchDescriptor<Person>(predicate: #Predicate { $0.isCurrentUser })
        )) ?? []
        for person in people where person.appleUserIdentifier == normalizedIdentifier {
            person.appleSessionStateRaw = isActive ? "active" : "providerRevoked"
        }
        try? context.save()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// App shell — cobalt tab bar with a raised cream FAB, mirroring the mockup board.
struct RootTabView: View {
    enum Tab: Int, CaseIterable {
        case home, groups, activity, profile

        var title: String {
            switch self {
            case .home: return "Home"
            case .groups: return "Groups"
            case .activity: return "Activity"
            case .profile: return "Profile"
            }
        }

        var icon: BrandIcon {
            switch self {
            case .home: return .home
            case .groups: return .users
            case .activity: return .pulse
            case .profile: return .user
            }
        }
    }

    @State private var tab: Tab = .home
    @State private var showAdd = false
    @State private var movesForward = true
    @State private var profilePickerRequested = false
    @StateObject private var rewardFeedback = RewardFeedbackCenter.shared
    @StateObject private var collaboration = CloudCollaborationService.shared
    @StateObject private var friendInvitations = FriendInvitationService.shared
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Query(sort: \ActivityItem.timestamp, order: .reverse) private var activityItems: [ActivityItem]
    @AppStorage("activityLastReadTimestamp") private var activityLastReadTimestamp = 0.0
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Screenshot support: `-tab N` selects the initial tab, `-showAdd` opens the add sheet.
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count,
           let n = Int(args[i + 1]), let t = Tab(rawValue: n) {
            _tab = State(initialValue: t)
        } else if args.contains("-showProfile") || args.contains("-showMotionLab") ||
                    args.contains("-showAddFriend") {
            _tab = State(initialValue: .profile)
        }
        if args.contains("-showAdd") { _showAdd = State(initialValue: true) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.Brand.cobalt.ignoresSafeArea()

            SwiftUI.Group {
                switch tab {
                case .home:     HomeScreen(onSeeAllGroups: { selectTab(.groups) },
                                           onOpenActivity: { selectTab(.activity) },
                                           unreadActivityCount: unreadActivityCount,
                                           onOpenProfile: {
                                               selectTab(.profile, showAvatarPicker: true)
                                           })
                case .groups:   GroupsScreen()
                case .activity: ActivityScreen()
                case .profile:  ProfileScreen(presentAvatarPicker: profilePickerRequested)
                }
            }
            .id(tab.rawValue)
            .transition(tabTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 76) // keep content clear of the floating dock

            tabBar

            if let groupID = collaboration.pendingMemberClaimGroupID {
                MemberClaimView(groupID: groupID)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(50)
            }
        }
        .overlay(alignment: .bottom) {
            if let outcome = rewardFeedback.current {
                RewardToastView(outcome: outcome)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 76)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : BrandMotion.revealSpring,
                   value: rewardFeedback.current?.id)
        .fullScreenCover(isPresented: $showAdd) {
            AddExpenseSheet()
        }
        .fullScreenCover(isPresented: $friendInvitations.shouldPresentInviteSheet) {
            FriendInvitationSheet(initialCode: friendInvitations.incomingCode)
        }
        .task { AppStore.seedIfNeeded(context: context) }
        .task {
            await friendInvitations.refreshAcceptedInvites()
            await CloudCollaborationService.shared.refreshFriendProfiles()
        }
        .onAppear {
            if tab == .activity { markActivityRead() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.home)
            tabButton(.groups)
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showAdd = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.Brand.creamSoft)
                        .frame(width: 48, height: 48)
                        .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
                    BrandIconView(icon: .plus, size: 23)
                        .foregroundStyle(Color.Brand.cobalt)
                }
            }
            .frame(width: 64)
            .buttonStyle(.plain)
            .accessibilityLabel("Add expense")

            tabButton(.activity)
            tabButton(.profile)
        }
        .padding(.horizontal, 12)
        .frame(height: 66)
        .background(
            Color.Brand.cobaltDeep.opacity(0.90),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .shadow(color: Color.Brand.cobaltDeep.opacity(0.34), radius: 12, y: 6)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func tabButton(_ t: Tab) -> some View {
        Button {
            guard tab != t else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selectTab(t)
        } label: {
            VStack(spacing: 3) {
                if t == .profile {
                    ProfileAvatarView(
                        avatar: currentUsers.first?.profileAvatar ?? .sunglasses,
                        size: 23
                    )
                    .opacity(t == tab ? 1 : 0.48)
                } else {
                    BrandIconView(icon: t.icon, size: 22)
                }
                Text(t.title)
                    .font(BrandFont.body(9.5, weight: .extraBold))
            }
            .foregroundStyle(Color.Brand.creamSoft.opacity(t == tab ? 1 : 0.4))
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(
            t == .profile
                ? "profileTabAvatar-\((currentUsers.first?.profileAvatar ?? .sunglasses).rawValue)"
                : "tab-\(t.title.lowercased())"
        )
    }

    private var tabTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let entering: Edge = movesForward ? .trailing : .leading
        let leaving: Edge = movesForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: entering).combined(with: .opacity),
            removal: .move(edge: leaving).combined(with: .opacity)
        )
    }

    private func selectTab(_ newTab: Tab, showAvatarPicker: Bool = false) {
        if newTab == .activity { markActivityRead() }
        guard tab != newTab else { return }
        movesForward = newTab.rawValue > tab.rawValue
        profilePickerRequested = newTab == .profile && showAvatarPicker
        withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
            tab = newTab
        }
    }

    private var unreadActivityCount: Int {
        guard let currentUserID = currentUsers.first?.id else { return 0 }
        let lastRead = Date(timeIntervalSince1970: activityLastReadTimestamp)
        return ActivityData.unreadCount(in: activityItems, currentUserID: currentUserID,
                                        lastRead: lastRead)
    }

    private func markActivityRead() {
        activityLastReadTimestamp = Date.now.timeIntervalSince1970
    }
}

private struct MemberClaimView: View {
    let groupID: UUID

    @Query private var groups: [Group]
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var group: Group? { groups.first { $0.id == groupID } }
    private var current: Person? { currentUsers.first }
    private var availableMembers: [Person] {
        group?.members.filter { $0.cloudUserRecordName == nil && !$0.isCurrentUser } ?? []
    }

    var body: some View {
        ZStack {
            Color.Brand.cobalt.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 12)
                MascotView(mascot: .greeting, size: 154, idle: false)
                VStack(spacing: 7) {
                    Text("which member are you? ")
                        .font(BrandFont.hand(30, weight: .bold))
                    Text("Match your profile to the name used on \(group?.name ?? "this shared bill").")
                        .font(BrandFont.body(14, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .opacity(0.72)
                }

                VStack(spacing: 10) {
                    ForEach(availableMembers) { member in
                        claimButton(member.name) {
                            claim(as: member.id)
                        }
                    }
                    if let current {
                        claimButton("Join as \(current.name)", outlined: true) {
                            claim(as: nil)
                        }
                    }
                }
                Spacer()
            }
            .foregroundStyle(Color.Brand.cobalt)
            .padding(.horizontal, 26)
            .padding(.vertical, 26)
            .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.vertical, 56)
        }
        .accessibilityIdentifier("memberClaimScreen")
    }

    private func claimButton(_ title: String, outlined: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.display(16, weight: .bold))
                .foregroundStyle(outlined ? Color.Brand.cobalt : Color.Brand.creamSoft)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(outlined ? Color.clear : Color.Brand.cobalt, in: Capsule())
                .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
    }

    private func claim(as memberID: UUID?) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
            CloudCollaborationService.shared.claimCurrentUser(in: groupID, as: memberID)
        }
    }
}

private struct RewardToastView: View {
    let outcome: RewardOutcome

    private var unlocked: StarterAchievement? { outcome.unlockedAchievements.first }

    var body: some View {
        HStack(spacing: 12) {
            if let unlocked {
                AchievementBadgeView(achievement: unlocked, size: 48)
            } else {
                Text("+\(outcome.xpAwarded)")
                    .font(BrandFont.type(14, bold: true))
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(width: 46, height: 46)
                    .background(Color.Brand.cobalt, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(unlocked?.title ?? (outcome.didLevelUp
                    ? "Level up · \(outcome.currentLevel.title)"
                    : "+\(outcome.xpAwarded) XP"))
                    .font(BrandFont.display(14, weight: .bold))
                Text(unlocked == nil
                    ? "\(outcome.totalXP) lifetime XP"
                    : "+\(outcome.xpAwarded) XP · pin unlocked")
                    .font(BrandFont.type(9.5, bold: true))
                    .opacity(0.62)
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(Color.Brand.cobalt, lineWidth: 2.5))
        .shadow(color: Color.black.opacity(0.22), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rewardToast")
    }
}

#Preview {
    RootTabView()
}
