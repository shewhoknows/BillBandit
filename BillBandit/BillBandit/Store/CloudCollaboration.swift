import CloudKit
import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Stable routing helpers retained for invitation compatibility. They no
/// longer create, publish, or subscribe to ledger shares.
enum AutomaticGroupShareRouting {
    static let recordType = "BBGroupInvitation"
    static let recordPrefix = "BBGroupInvitation-"

    static func recipients(from cloudUsers: [String?], currentUser: String) -> [String] {
        Array(Set(cloudUsers.compactMap { value in
            guard let value, !value.isEmpty, value != currentUser else { return nil }
            return value
        })).sorted()
    }

    static func recordName(groupID: UUID, recipientCloudUser: String) -> String {
        let digest = SHA256.hash(data: Data(recipientCloudUser.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(recordPrefix)\(groupID.uuidString)-\(digest.prefix(24))"
    }

    static func subscriptionID(for cloudUser: String) -> String {
        let digest = SHA256.hash(data: Data(cloudUser.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "BillBandit.AutomaticGroupInvitations.\(digest.prefix(24))"
    }
}

enum CloudSyncIssueSource {
    case automaticInvitation
    case privateLedger
    case sharedLedger
    case localPromotion
}

struct CloudSyncIssue {
    let source: CloudSyncIssueSource
    let error: Error
}

/// Compatibility policy for existing diagnostics. The production service no
/// longer produces private/shared-ledger issues; friend/profile failures stay
/// isolated from API-backed ledger state.
enum CloudSyncIssuePolicy {
    private static let attentionCodes: Set<CKError.Code> = [
        .notAuthenticated,
        .permissionFailure,
        .quotaExceeded,
        .invalidArguments,
        .serverRejectedRequest,
    ]

    static func visibleError(from issues: [CloudSyncIssue]) -> Error? {
        issues.first { $0.source != .automaticInvitation }?.error
    }

    static func shouldSurfaceBanner(for error: Error) -> Bool {
        guard let code = CloudUploadFailurePolicy.cloudCode(for: error) else { return false }
        return attentionCodes.contains(code)
    }
}

enum AutomaticInvitationFailurePolicy {
    static func isTerminal(_ error: Error) -> Bool {
        switch cloudCode(for: error) {
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            return true
        default:
            return false
        }
    }

    private static func cloudCode(for error: Error) -> CKError.Code? {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            return cloudCode(for: underlying)
        }
        if let cloudError = error as? CKError { return cloudError.code }
        guard nsError.domain == CKError.errorDomain else { return nil }
        return CKError.Code(rawValue: nsError.code)
    }
}

/// Pure merge rules retained for local identity repair and migration tests.
/// They are not used to reconcile CloudKit ledger records anymore.
enum CloudRecordMergePolicy {
    static func localRecordIDsToDelete(local: Set<UUID>,
                                       remoteManifest: Set<UUID>) -> Set<UUID> {
        []
    }

    static func shouldApplyIncomingRecord(_ id: UUID,
                                          remoteManifest: Set<UUID>?) -> Bool {
        true
    }
}

/// Keeps legacy name-only friends from winning over the same person's
/// connected non-ledger CloudKit identity.
enum ConnectedFriendIdentity {
    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter(\.isLetter)
    }

    /// Remote profiles never retain local Apple-account or session identity.
    /// This also repairs rows reused from an older account-direction bug.
    @discardableResult
    static func normalizeIncomingFriend(_ person: Person, cloudUser: String) -> Bool {
        let normalizedCloudUser = cloudUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCloudUser.isEmpty else { return false }
        let changed = person.isCurrentUser ||
            person.appleUserIdentifier != nil ||
            person.appleSessionStateRaw != nil ||
            person.cloudUserRecordName != normalizedCloudUser
        person.isCurrentUser = false
        person.appleUserIdentifier = nil
        person.appleSessionStateRaw = nil
        person.cloudUserRecordName = normalizedCloudUser
        return changed
    }

    /// API identities are authoritative for social and ledger membership.
    /// A server friend can carry a legacy CloudKit profile link, but it can
    /// never carry this device's Apple session markers or become "You".
    @discardableResult
    static func normalizeIncomingFriend(
        _ person: Person,
        serverAccountID: String,
        cloudUser: String? = nil
    ) -> Bool {
        let accountID = serverAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else { return false }
        let normalizedCloudUser = cloudUser?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableCloudUser = normalizedCloudUser.flatMap { $0.isEmpty ? nil : $0 }
        let changed = person.isCurrentUser ||
            person.appleUserIdentifier != nil ||
            person.appleSessionStateRaw != nil ||
            person.serverAccountID != accountID ||
            person.friendshipStateRaw != "accepted" ||
            (usableCloudUser != nil && person.cloudUserRecordName != usableCloudUser)
        person.isCurrentUser = false
        person.appleUserIdentifier = nil
        person.appleSessionStateRaw = nil
        person.serverAccountID = accountID
        person.friendshipStateRaw = "accepted"
        if let usableCloudUser { person.cloudUserRecordName = usableCloudUser }
        return changed
    }

    @discardableResult
    static func applyInvitationSnapshot(name: String, avatarRaw: String?, to person: Person,
                                        isNew: Bool) -> Bool {
        guard isNew else { return false }
        person.name = name.capitalizingFirstLetter
        person.avatarRaw = avatarRaw
        return true
    }

    static func preferredPerson(for person: Person, among people: [Person]) -> Person {
        guard !person.isCurrentUser else { return person }
        if let accountID = person.serverAccountID, !accountID.isEmpty {
            return canonicalServerPerson(for: accountID, among: people) ?? person
        }
        if let cloudUser = person.cloudUserRecordName, !cloudUser.isEmpty {
            return canonicalConnectedPerson(for: cloudUser, among: people) ?? person
        }
        let normalized = normalizedName(person.name)
        let connectedByAccount = Dictionary(grouping: people.filter {
            !$0.isCurrentUser && $0.cloudUserRecordName != nil &&
                normalizedName($0.name) == normalized
        }, by: { $0.cloudUserRecordName! })
        guard connectedByAccount.count == 1,
              let cloudUser = connectedByAccount.keys.first else { return person }
        return canonicalConnectedPerson(for: cloudUser, among: people) ?? person
    }

    static func canonicalPeople(from people: [Person]) -> [Person] {
        var seen = Set<UUID>()
        return people.compactMap { person in
            let preferred = preferredPerson(for: person, among: people)
            return seen.insert(preferred.id).inserted ? preferred : nil
        }
    }

    /// Connected crew members linked through the friend-invite handshake.
    /// Rows that still carry a Sign in with Apple identifier are former local
    /// account profiles, not selectable friends.
    static func isConnectedFriend(_ person: Person) -> Bool {
        guard !person.isCurrentUser else { return false }
        guard person.appleUserIdentifier?.isEmpty != false else { return false }
        guard person.friendshipStateRaw == "accepted" else { return false }
        guard let accountID = person.serverAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty else {
            return false
        }
        return true
    }

    static func actualFriends(from people: [Person]) -> [Person] {
        canonicalPeople(from: people).filter(isConnectedFriend)
    }

    static func groupMemberOptions(from people: [Person]) -> [Person] {
        let canonical = canonicalPeople(from: people)
        let current = canonical.first(where: \.isCurrentUser)
        let friends = actualFriends(from: people)
        var seen = Set<UUID>()
        var options = [Person]()
        if let current, seen.insert(current.id).inserted {
            options.append(current)
        }
        for friend in friends where seen.insert(friend.id).inserted {
            options.append(friend)
        }
        return options.sorted {
            if $0.isCurrentUser != $1.isCurrentUser { return $0.isCurrentUser }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func canonicalConnectedPerson(for cloudUser: String,
                                                 among people: [Person]) -> Person? {
        people.filter {
            !$0.isCurrentUser && $0.cloudUserRecordName == cloudUser
        }.sorted { lhs, rhs in
            let lhsDate = lhs.profileUpdatedAt ?? .distantPast
            let rhsDate = rhs.profileUpdatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
    }

    private static func canonicalServerPerson(for accountID: String,
                                              among people: [Person]) -> Person? {
        people.filter {
            !$0.isCurrentUser && $0.serverAccountID == accountID
        }.sorted { lhs, rhs in
            if (lhs.friendshipStateRaw == "accepted") !=
                (rhs.friendshipStateRaw == "accepted") {
                return lhs.friendshipStateRaw == "accepted"
            }
            let lhsDate = lhs.profileUpdatedAt ?? .distantPast
            let rhsDate = rhs.profileUpdatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
    }

    @MainActor
    @discardableResult
    static func repairDuplicateAccounts(context: ModelContext) -> [Group] {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        var affectedByID: [UUID: Group] = [:]
        let remotePeople = people.filter { !$0.isCurrentUser }
        let accounts = Dictionary(grouping: remotePeople.compactMap { person -> (String, Person)? in
            if let accountID = person.serverAccountID, !accountID.isEmpty {
                return ("server:\(accountID)", person)
            }
            if let cloudUser = person.cloudUserRecordName, !cloudUser.isEmpty {
                return ("cloud:\(cloudUser)", person)
            }
            return nil
        }, by: { $0.0 })

        for (key, keyedRows) in accounts where keyedRows.count > 1 {
            let rows = keyedRows.map(\.1)
            let canonical: Person?
            if key.hasPrefix("server:") {
                canonical = canonicalServerPerson(
                    for: String(key.dropFirst("server:".count)), among: rows
                )
            } else {
                canonical = canonicalConnectedPerson(
                    for: String(key.dropFirst("cloud:".count)), among: rows
                )
            }
            guard let canonical else { continue }
            for duplicate in rows where duplicate.id != canonical.id {
                for group in mergeLegacyFriend(duplicate, into: canonical, context: context) {
                    affectedByID[group.id] = group
                }
            }
        }

        try? context.save()
        return affectedByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    @MainActor
    @discardableResult
    static func mergeLegacyFriend(_ legacy: Person, into connected: Person,
                                  context: ModelContext) -> [Group] {
        guard legacy.id != connected.id else { return [] }
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let affected = groups.filter {
            $0.members.contains(where: { $0.id == legacy.id })
        }
        for group in affected {
            group.members.removeAll { $0.id == legacy.id }
            if !group.members.contains(where: { $0.id == connected.id }) {
                group.members.append(connected)
            }
            for expense in group.expenses {
                if expense.paidBy?.id == legacy.id { expense.paidBy = connected }
                for split in expense.splits where split.person?.id == legacy.id {
                    split.person = connected
                }
            }
            for settlement in group.settlements {
                if settlement.from?.id == legacy.id { settlement.from = connected }
                if settlement.to?.id == legacy.id { settlement.to = connected }
            }
        }
        let activities = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        for item in activities where item.actorID == legacy.id {
            item.actorID = connected.id
        }
        context.delete(legacy)
        return affected
    }
}

enum CollaborationRetryPolicy {
    static func delay(after attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(pow(2, Double(attempt - 1)), 30)
    }

    static func delay(after attempt: Int, error: Error) -> TimeInterval {
        let retryAfter = (error as NSError).userInfo[CKErrorRetryAfterKey]
        if let seconds = retryAfter as? NSNumber {
            return max(0, seconds.doubleValue)
        }
        return delay(after: attempt)
    }
}

enum CloudUploadFailureDisposition: Equatable {
    case retry
    case needsAttention
}

enum CloudUploadFailurePolicy {
    private static let terminalCodes: Set<CKError.Code> = [
        .invalidArguments,
        .permissionFailure,
        .notAuthenticated,
        .quotaExceeded,
        .serverRejectedRequest,
    ]

    static func disposition(for error: Error) -> CloudUploadFailureDisposition {
        cloudCodes(for: error).isDisjoint(with: terminalCodes) ? .retry : .needsAttention
    }

    static func cloudCode(for error: Error) -> CKError.Code? {
        let codes = cloudCodes(for: error)
        if let terminal = codes.intersection(terminalCodes)
            .sorted(by: { $0.rawValue < $1.rawValue }).first {
            return terminal
        }
        return codes.sorted(by: { $0.rawValue < $1.rawValue }).first
    }

    private static func cloudCodes(for error: Error, depth: Int = 0) -> Set<CKError.Code> {
        guard depth < 8 else { return [] }
        let nsError = error as NSError
        var codes: Set<CKError.Code> = []
        if let cloudError = error as? CKError {
            codes.insert(cloudError.code)
        } else if nsError.domain == CKError.errorDomain,
                  let code = CKError.Code(rawValue: nsError.code) {
            codes.insert(code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            codes.formUnion(cloudCodes(for: underlying, depth: depth + 1))
        }
        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
            for case let nested as NSError in partialErrors.allValues {
                codes.formUnion(cloudCodes(for: nested, depth: depth + 1))
            }
        }
        return codes
    }
}

enum CloudSyncWorkPolicy {
    static func shouldYieldToPendingUpload(hasPendingUploadReady: Bool) -> Bool {
        hasPendingUploadReady
    }
}

/// Kept as a compatibility value for old diagnostics. No production code
/// calls it; the retired ledger service creates no CloudKit subscriptions.
enum CloudSubscriptionPolicy {
    static func shouldCreateRecordZoneSubscription(scope: CKDatabase.Scope) -> Bool {
        scope == .private
    }
}

enum CloudPersonRecordPolicy {
    static let writesProfileUpdatedAt = true
}

/// Public profile cards are the only CloudKit records still synchronized by
/// the collaboration service during normal app operation.
enum FriendProfileSync {
    static let recordType = "BBFriendProfile"
    static let recordPrefix = "BBFriendProfile-"

    static func recordID(for cloudUser: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(cloudUser.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return CKRecord.ID(recordName: "\(recordPrefix)\(digest.prefix(32))")
    }
}

@MainActor
final class CloudCollaborationService: ObservableObject {
    static let shared = CloudCollaborationService()

    nonisolated static let containerIdentifier = "iCloud.com.billbandit.app"

    enum State: Equatable {
        case idle
        case checking
        case syncing
        case ready
        case unavailable(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    enum DatabaseScope: String {
        case `private`
        case shared
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastIssue: String?
    @Published private(set) var pendingMemberClaimGroupID: UUID?

    let container: CKContainer
    private var currentUserRecordName: String?
    private var isPreparing = false
    private var foregroundSyncWorker: Task<Void, Never>?
    private var friendProfileRefreshTask: Task<Void, Never>?
    private var friendProfileRefreshTaskToken: UUID?
    private var accountGeneration = 0

    private init() {
        self.container = CKContainer(identifier: Self.containerIdentifier)
    }

    /// Prepares non-ledger friend/profile identity, activates the authenticated
    /// API account, and then performs the one-time CloudKit import if needed.
    /// No CloudKit group, expense, split, settlement, balance, invoice, or
    /// settlement-state path runs here.
    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        state = .checking
        let generation = accountGeneration

        let apiAccountReady = await prepareAPIAccount()
        guard generation == accountGeneration else {
            isPreparing = false
            return
        }
        let cloudIdentityReady = await prepareNonLedgerCloudIdentity()
        guard generation == accountGeneration else {
            isPreparing = false
            return
        }

        if apiAccountReady {
            await runLegacyCloudKitImportIfNeeded()
            await ServerSocialSyncService.shared.refresh()
            state = .syncing
            await ServerLedgerAccountLifecycle.shared.reconcile(trigger: .startup)
            lastSync = .now
        }

        if cloudIdentityReady || apiAccountReady {
            state = .ready
        } else if state == .checking {
            state = .idle
        }
        isPreparing = false
    }

    func startForegroundSync() {
        guard foregroundSyncWorker == nil else { return }
        foregroundSyncWorker = Task { [weak self] in
            await self?.refreshWhileVisible(every: .seconds(1))
        }
    }

    func stopForegroundSync() {
        foregroundSyncWorker?.cancel()
        foregroundSyncWorker = nil
    }

    /// Foreground/reconnect work is API-backed for ledger data. CloudKit is
    /// limited to non-ledger friend profiles and invitation records.
    func refreshWhileVisible(every interval: Duration = .seconds(1)) async {
        var tick = 0
        while !Task.isCancelled {
            // Keep the fast path API-only. CloudKit profile work runs once on
            // prepare/foreground and must not run every second.
            await ServerSocialSyncService.shared.pollForChanges()
            tick += 1
            if tick.isMultiple(of: 10) {
                await ServerLedgerAccountLifecycle.shared.reconcile(trigger: .foreground)
            }
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func synchronize(promoteLocalChanges: Bool = false) async {
        _ = promoteLocalChanges
        state = .syncing
        let generation = accountGeneration
        let apiAccountReady = await prepareAPIAccount()
        guard generation == accountGeneration else { return }
        let cloudIdentityReady = await prepareNonLedgerCloudIdentity()
        guard generation == accountGeneration else { return }
        if apiAccountReady {
            if cloudIdentityReady {
                await runLegacyCloudKitImportIfNeeded()
            }
            await ServerSocialSyncService.shared.refresh()
            await ServerLedgerAccountLifecycle.shared.reconcile(trigger: .reconnect)
        }
        await refreshFriendProfiles()
        lastSync = .now
        state = .ready
    }

    /// Legacy UI hooks intentionally do not write to CloudKit. T-15 mutations
    /// already use the canonical API queue; local-only groups remain local.
    func groupDidChange(_ group: Group) {
        _ = group
    }

    func expenseWasDeleted(_ expenseID: UUID, from group: Group) {
        _ = expenseID
        _ = group
    }

    func groupWasDeleted(_ group: Group) {
        _ = group
    }

    /// Re-activates both account boundaries after Apple/API authentication.
    /// The API account ID is resolved from `/auth/me`, never from CloudKit.
    func accountDidChange() async {
        resetAccountScopedState()
        _ = await prepareAPIAccount()
        _ = await prepareNonLedgerCloudIdentity()
        await runLegacyCloudKitImportIfNeeded()
        await ServerSocialSyncService.shared.refresh()
        await ServerLedgerAccountLifecycle.shared.reconcile(trigger: .reconnect)
        state = .ready
    }

    func accountDidSignOut() {
        stopForegroundSync()
        ServerLedgerAccountLifecycle.shared.signOut()
        ServerSocialSyncService.shared.accountDidSignOut()
        Task { await FriendInvitationService.shared.deleteAccountData() }
        resetAccountScopedState()
        state = .idle
    }

    /// Best-effort removal of the signed-in user's public profile before the
    /// API account is anonymized. Shared ledger records are not stored here.
    func deleteAccountData() async {
        let cloudUser = currentUserRecordName
        if let cloudUser {
            try? await container.publicCloudDatabase.deleteRecord(
                withID: FriendProfileSync.recordID(for: cloudUser)
            )
        }
        await FriendInvitationService.shared.deleteAccountData()
        currentUserRecordName = nil
    }

    func currentPersonDidChange() {
        linkCurrentPerson()
        Task { await publishFriendProfile() }
    }

    func refreshFriendProfiles() async {
        if currentUserRecordName == nil {
            guard UsernameIdentityService.hasStoredSession,
                  (try? await container.accountStatus()) == .available,
                  let recordName = try? await container.userRecordID().recordName else {
                return
            }
            currentUserRecordName = recordName
            linkCurrentPerson()
            await publishFriendProfile()
        }
        if let task = friendProfileRefreshTask {
            await task.value
            return
        }

        let token = UUID()
        friendProfileRefreshTaskToken = token
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshFriendProfilesWorker()
        }
        friendProfileRefreshTask = task
        await task.value
        if friendProfileRefreshTaskToken == token {
            friendProfileRefreshTask = nil
            friendProfileRefreshTaskToken = nil
        }
    }

    private func refreshFriendProfilesWorker() async {
        guard let currentUserRecordName else { return }
        let generation = accountGeneration
        let context = AppStore.container.mainContext
        let friends = ConnectedFriendIdentity.actualFriends(
            from: (try? context.fetch(FetchDescriptor<Person>())) ?? []
        ).filter { $0.serverAccountID == nil }
        let cloudUsers = friends.compactMap(\.cloudUserRecordName).filter { !$0.isEmpty }
        guard !cloudUsers.isEmpty else { return }

        let database = container.publicCloudDatabase
        let recordIDs = cloudUsers.map { FriendProfileSync.recordID(for: $0) }
        let outcome = try? await database.records(for: recordIDs)
        guard let outcome else { return }
        guard generation == accountGeneration,
              self.currentUserRecordName == currentUserRecordName else { return }

        var changed = false
        for cloudUser in cloudUsers {
            let recordID = FriendProfileSync.recordID(for: cloudUser)
            guard case .success(let record)? = outcome[recordID],
                  record.recordType == FriendProfileSync.recordType,
                  record.string("cloudUser") == cloudUser,
                  let name = record.string("name") else { continue }
            if applyFriendProfile(
                name: name,
                avatarRaw: record.string("avatar"),
                profileUpdatedAt: record.date("profileUpdatedAt"),
                cloudUser: cloudUser
            ) {
                changed = true
            }
        }
        if changed { try? context.save() }
        _ = currentUserRecordName
    }

    private func prepareAPIAccount() async -> Bool {
        guard UsernameIdentityService.hasStoredSession else {
            ServerLedgerAccountLifecycle.shared.signOut()
            return false
        }
        let generation = accountGeneration
        do {
            let remoteUser = try await UsernameIdentityService.currentUser()
            guard generation == accountGeneration,
                  UsernameIdentityService.hasStoredSession else { return false }
            try ServerLedgerAccountLifecycle.shared.activate(accountID: remoteUser.id)
            return true
        } catch {
            guard generation == accountGeneration else { return false }
            lastIssue = error.localizedDescription
            return false
        }
    }

    private func prepareNonLedgerCloudIdentity() async -> Bool {
        let generation = accountGeneration
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                lastIssue = "iCloud is unavailable for profile and friend sync."
                return false
            }
            let recordName = try await container.userRecordID().recordName
            guard generation == accountGeneration else { return false }
            currentUserRecordName = recordName
            linkCurrentPerson()
            await publishFriendProfile()
            await refreshFriendProfiles()
            return true
        } catch {
            guard generation == accountGeneration else { return false }
            lastIssue = Self.readable(error)
            return false
        }
    }

    private func resetAccountScopedState() {
        friendProfileRefreshTask?.cancel()
        friendProfileRefreshTask = nil
        friendProfileRefreshTaskToken = nil
        accountGeneration &+= 1
        currentUserRecordName = nil
        pendingMemberClaimGroupID = nil
        lastIssue = nil
    }

    @discardableResult
    private func applyFriendProfile(name: String,
                                    avatarRaw: String?,
                                    profileUpdatedAt: Date?,
                                    cloudUser: String) -> Bool {
        let context = AppStore.container.mainContext
        ConnectedFriendIdentity.repairDuplicateAccounts(context: context)
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard let existing = people.first(where: {
            $0.cloudUserRecordName == cloudUser &&
                $0.serverAccountID == nil &&
                ConnectedFriendIdentity.isConnectedFriend($0)
        }) else {
            return false
        }
        guard AccountProfileMergePolicy.shouldApplyRemoteProfile(
            remoteUpdatedAt: profileUpdatedAt,
            localUpdatedAt: existing.profileUpdatedAt,
            isCurrentUser: false
        ) else { return false }

        existing.name = name
        existing.avatarRaw = avatarRaw
        existing.profileUpdatedAt = profileUpdatedAt
        return true
    }

    private func publishFriendProfile() async {
        guard let cloudUser = currentUserRecordName else { return }
        let generation = accountGeneration
        let context = AppStore.container.mainContext
        guard let profile = AccountProfileIntegrity.canonicalCurrentPerson(
            appleUserIdentifier: UserDefaults.standard.string(forKey: "appleUserIdentifier"),
            cloudUserRecordName: cloudUser,
            context: context
        ) else { return }
        let publicName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicName.isEmpty,
              publicName.caseInsensitiveCompare("You") != .orderedSame else {
            return
        }
        guard generation == accountGeneration,
              currentUserRecordName == cloudUser else { return }

        let record = CKRecord(
            recordType: FriendProfileSync.recordType,
            recordID: FriendProfileSync.recordID(for: cloudUser)
        )
        record["cloudUser"] = cloudUser as CKRecordValue
        record["name"] = publicName as CKRecordValue
        record["avatar"] = profile.avatarRaw as CKRecordValue?
        if let profileUpdatedAt = profile.profileUpdatedAt {
            record["profileUpdatedAt"] = profileUpdatedAt as CKRecordValue
        }
        do {
            _ = try await container.publicCloudDatabase.save(record)
        } catch {
            guard generation == accountGeneration else { return }
            lastIssue = Self.readable(error)
        }
    }

    private func linkCurrentPerson() {
        guard let recordName = currentUserRecordName else { return }
        let context = AppStore.container.mainContext
        AccountProfileIntegrity.canonicalize(
            appleUserIdentifier: UserDefaults.standard.string(forKey: "appleUserIdentifier"),
            cloudUserRecordName: recordName,
            context: context
        )
    }

    /// Explicit local identity claim used by the legacy member-picker UI. It
    /// only repairs local references; it never changes API membership or sends
    /// a CloudKit ledger record.
    func claimCurrentUser(in groupID: UUID, as memberID: UUID?) {
        guard let recordName = currentUserRecordName else { return }
        let context = AppStore.container.mainContext
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let current = AccountProfileIntegrity.canonicalize(
            appleUserIdentifier: UserDefaults.standard.string(forKey: "appleUserIdentifier"),
            cloudUserRecordName: recordName,
            context: context
        )
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        current.cloudUserRecordName = recordName
        if let memberID, let member = group.members.first(where: { $0.id == memberID }) {
            replaceMember(member, with: current, in: group)
        } else if !group.members.contains(where: { $0.id == current.id }) {
            group.members.append(current)
        }
        try? context.save()
        pendingMemberClaimGroupID = nil
    }

    private func replaceMember(_ member: Person, with current: Person, in group: Group) {
        guard member.id != current.id else {
            current.cloudUserRecordName = currentUserRecordName
            return
        }
        group.members.removeAll { $0.id == member.id }
        if !group.members.contains(where: { $0.id == current.id }) {
            group.members.append(current)
        }
        for expense in group.expenses {
            if expense.paidBy?.id == member.id { expense.paidBy = current }
            for split in expense.splits where split.person?.id == member.id {
                split.person = current
            }
        }
        for settlement in group.settlements {
            if settlement.from?.id == member.id { settlement.from = current }
            if settlement.to?.id == member.id { settlement.to = current }
        }
        current.cloudUserRecordName = currentUserRecordName
    }

    static func readable(_ error: Error) -> String {
        switch CloudUploadFailurePolicy.cloudCode(for: error) {
        case .notAuthenticated:
            return "Sign in to iCloud in Settings to connect with friends."
        case .networkFailure, .networkUnavailable:
            return "Cloud sync will retry when you're online."
        case .quotaExceeded:
            return "Your iCloud storage is full."
        case .permissionFailure:
            return "BillBandit needs iCloud permission for friend profiles."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "Cloud sync is temporarily busy. It will retry automatically."
        case .invalidArguments, .serverRejectedRequest:
            return "Cloud sync needs an app update. Your data is saved on this device."
        default:
            return "Cloud sync hit a temporary problem. It will retry automatically."
        }
    }
}

// MARK: - Exactly-once legacy CloudKit import

/// The importer is the sole remaining path that reads legacy ledger zones.
/// It is account-gated, checkpointed in SwiftData, and never feeds local
/// Group/Expense/Settlement models. After the server completes it is frozen.
private extension CloudCollaborationService {
    struct LegacyImportOwner: Codable {
        let cloudKitRecordName: String
    }

    struct LegacyImportCurrency: Codable {
        let currencyCode: String
        let currencyExponent: Int
    }

    struct LegacyImportClaim: Codable {
        let personRecordName: String
        let cloudKitRecordName: String?
        let accountId: String?

        private enum CodingKeys: String, CodingKey {
            case personRecordName
            case cloudKitRecordName
            case accountId
        }
    }

    struct LegacyImportZone: Codable, Hashable {
        let name: String
        let ownerName: String
    }

    indirect enum LegacyJSONValue: Codable, Equatable {
        case object([String: LegacyJSONValue])
        case array([LegacyJSONValue])
        case string(String)
        case number(String)
        case boolean(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode([String: LegacyJSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([LegacyJSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .number(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .object(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .boolean(value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

        var stringValue: String? {
            if case let .string(value) = self { return value }
            return nil
        }
    }

    struct LegacyImportRecord: Codable, Equatable {
        let database: String
        let zone: LegacyImportZone
        let recordType: String
        let recordName: String
        var fields: [String: LegacyJSONValue]
    }

    struct LegacyImportExport: Codable {
        let source: String
        var sourceKey: String
        let owner: LegacyImportOwner
        let defaultCurrency: LegacyImportCurrency
        var claims: [LegacyImportClaim]
        var records: [LegacyImportRecord]
    }

    struct LegacyImportResponse: Decodable {
        let importID: String?
        let status: String?
        let sourceKey: String?
        let migration: LegacyMigrationResponse?

        private enum CodingKeys: String, CodingKey {
            case importID = "importId"
            case status
            case sourceKey
            case migration
        }
    }

    struct LegacyMigrationResponse: Decodable {
        let status: String?
    }

    enum LegacyImportError: LocalizedError {
        case noAPIAccount
        case invalidCheckpoint
        case invalidResponse
        case server(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .noAPIAccount: return "An authenticated BillBandit API account is required."
            case .invalidCheckpoint: return "The legacy ledger migration checkpoint is unreadable."
            case .invalidResponse: return "BillBandit returned an unreadable migration response."
            case let .server(_, message): return message ?? "BillBandit could not migrate the legacy ledger."
            }
        }
    }

    var legacyImportContext: ModelContext { AppStore.container.mainContext }

    func runLegacyCloudKitImportIfNeeded() async {
        guard let accountID = ServerLedgerAccountLifecycle.shared.activeAccountID,
              let ownerCloudUser = currentUserRecordName else { return }
        guard UsernameIdentityService.hasStoredSession else { return }
        let generation = accountGeneration

        func isCurrentAccount() -> Bool {
            generation == accountGeneration &&
                ServerLedgerAccountLifecycle.shared.activeAccountID == accountID &&
                currentUserRecordName == ownerCloudUser &&
                UsernameIdentityService.hasStoredSession
        }

        let context = legacyImportContext
        let state: CloudKitLedgerImportState
        if let existing = ((try? context.fetch(FetchDescriptor<CloudKitLedgerImportState>())) ?? [])
            .first(where: { $0.accountID == accountID }) {
            state = existing
        } else {
            let created = CloudKitLedgerImportState(accountID: accountID)
            context.insert(created)
            try? context.save()
            state = created
        }
        guard !state.isComplete, state.statusRaw != "needsRepair" else { return }

        do {
            let export: LegacyImportExport?
            if state.statusRaw == "submitted" {
                guard let checkpointData = state.checkpointData,
                      let checkpoint = try? JSONDecoder().decode(
                          LegacyImportExport.self,
                          from: checkpointData
                      ) else {
                    throw LegacyImportError.invalidCheckpoint
                }
                // Once submitted, resume the exact same frozen export. A
                // foreground cycle must never re-read CloudKit as authority.
                export = checkpoint
            } else {
                export = try await captureLegacyExport(
                    accountID: accountID,
                    ownerCloudUser: ownerCloudUser,
                    state: state
                )
            }
            guard isCurrentAccount() else { return }
            guard let export else {
                state.statusRaw = "completed"
                state.lastError = "no_legacy_ledger_records"
                state.completedAt = .now
                state.updatedAt = .now
                try? context.save()
                return
            }

            state.statusRaw = "submitted"
            state.sourceKey = export.sourceKey
            state.checkpointData = try JSONEncoder().encode(export)
            state.lastError = nil
            state.updatedAt = .now
            try? context.save()

            guard isCurrentAccount() else { return }
            let response = try await submitLegacyExport(
                export,
                importID: state.importID
            )
            guard isCurrentAccount() else { return }
            if let importID = response.importID { state.importID = importID }
            if let sourceKey = response.sourceKey { state.sourceKey = sourceKey }
            let completed = response.status == "completed"
                || response.migration?.status == "complete"
            let needsRepair = response.status == "needs-repair"
                || response.migration?.status == "blocked"
            state.statusRaw = completed ? "completed" : (needsRepair ? "needsRepair" : "submitted")
            state.completedAt = completed ? .now : nil
            state.lastError = completed ? nil : response.status
            state.updatedAt = .now
            try? context.save()
        } catch {
            guard isCurrentAccount() else { return }
            state.lastError = error.localizedDescription
            if case let LegacyImportError.server(status, _) = error, status == 409 {
                state.statusRaw = "needsRepair"
            } else {
                state.statusRaw = state.importID == nil ? "collecting" : "submitted"
            }
            state.updatedAt = .now
            try? context.save()
        }
    }

    func captureLegacyExport(accountID: String,
                             ownerCloudUser: String,
                             state: CloudKitLedgerImportState) async throws -> LegacyImportExport? {
        var export = state.checkpointData
            .flatMap { try? JSONDecoder().decode(LegacyImportExport.self, from: $0) }
            ?? LegacyImportExport(
                source: "cloudkit",
                sourceKey: state.sourceKey ?? "pending",
                owner: LegacyImportOwner(cloudKitRecordName: ownerCloudUser),
                defaultCurrency: LegacyImportCurrency(
                    currencyCode: Money.currentCurrency.rawValue,
                    currencyExponent: 2
                ),
                claims: [],
                records: []
            )
        export.sourceKey = state.sourceKey ?? export.sourceKey

        let zones = try await container.privateCloudDatabase.allRecordZones()
            .filter { $0.zoneID.zoneName.hasPrefix("BillBandit.Group.") }
            .sorted { $0.zoneID.zoneName < $1.zoneID.zoneName }
        guard !zones.isEmpty else { return export.records.isEmpty ? nil : export }

        for zone in zones {
            let records = try await captureLegacyRecords(in: zone.zoneID)
            merge(records, into: &export)
            export.claims = makeClaims(export.records, accountID: accountID,
                                        ownerCloudUser: ownerCloudUser)
            export.sourceKey = sourceKey(for: export)
            state.sourceKey = export.sourceKey
            state.statusRaw = "collecting"
            state.checkpointData = try JSONEncoder().encode(export)
            state.updatedAt = .now
            try? legacyImportContext.save()
        }

        export.records.sort {
            "\($0.database)|\($0.zone.name)|\($0.recordType)|\($0.recordName)" <
                "\($1.database)|\($1.zone.name)|\($1.recordType)|\($1.recordName)"
        }
        export.claims.sort { $0.personRecordName < $1.personRecordName }
        export.sourceKey = sourceKey(for: export)
        state.sourceKey = export.sourceKey
        state.checkpointData = try JSONEncoder().encode(export)
        state.updatedAt = .now
        try? legacyImportContext.save()
        return export.records.isEmpty ? nil : export
    }

    func captureLegacyRecords(in zoneID: CKRecordZone.ID) async throws -> [LegacyImportRecord] {
        var token: CKServerChangeToken?
        var records: [LegacyImportRecord] = []
        var moreComing = true
        while moreComing {
            let changes = try await container.privateCloudDatabase.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                resultsLimit: 200
            )
            for result in changes.modificationResultsByID.values {
                guard case .success(let modification) = result else { continue }
                let record = modification.record
                guard ["BBPerson", "BBGroup", "BBExpense", "BBSplit", "BBExpenseSplit",
                       "BBSettlement", "BBActivity"]
                    .contains(record.recordType) else { continue }
                records.append(try makeLegacyRecord(record, zoneID: zoneID))
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return records
    }

    func makeLegacyRecord(_ record: CKRecord,
                          zoneID: CKRecordZone.ID) throws -> LegacyImportRecord {
        var fields: [String: LegacyJSONValue] = [:]
        for key in record.allKeys() {
            guard let value = record[key],
                  let jsonValue = legacyJSONValue(value) else { continue }
            fields[key] = jsonValue
        }
        if fields["id"] == nil {
            fields["id"] = .string(record.recordID.recordName)
        }
        return LegacyImportRecord(
            database: "private",
            zone: LegacyImportZone(name: zoneID.zoneName, ownerName: "__defaultOwner__"),
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            fields: fields
        )
    }

    func merge(_ newRecords: [LegacyImportRecord], into export: inout LegacyImportExport) {
        var byKey = Dictionary(uniqueKeysWithValues: export.records.map { record in
            ("\(record.database)|\(record.zone.name)|\(record.recordType)|\(record.recordName)", record)
        })
        for record in newRecords {
            let key = "\(record.database)|\(record.zone.name)|\(record.recordType)|\(record.recordName)"
            byKey[key] = record
        }
        export.records = Array(byKey.values)
    }

    func makeClaims(_ records: [LegacyImportRecord],
                    accountID: String,
                    ownerCloudUser: String) -> [LegacyImportClaim] {
        let currentPersonID = ((try? legacyImportContext.fetch(
            FetchDescriptor<Person>(predicate: #Predicate { $0.isCurrentUser })
        )) ?? []).first?.id.uuidString
        return records.filter { $0.recordType == "BBPerson" }.compactMap { record in
            let personRecordName = record.fields["id"]?.stringValue ?? record.recordName
            let cloudUser = record.fields["cloudUser"]?.stringValue
            let isOwner = cloudUser == ownerCloudUser || personRecordName == currentPersonID
            guard isOwner || cloudUser != nil else { return nil }
            return LegacyImportClaim(
                personRecordName: personRecordName,
                cloudKitRecordName: cloudUser ?? (isOwner ? ownerCloudUser : nil),
                accountId: isOwner ? accountID : nil
            )
        }
    }

    func sourceKey(for export: LegacyImportExport) -> String {
        let material = export.records.map {
            "\($0.database)|\($0.zone.name)|\($0.zone.ownerName)|\($0.recordType)|\($0.recordName)"
        }.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "billbandit-cloudkit-\(digest.prefix(48))"
    }

    func legacyJSONValue(_ value: Any) -> LegacyJSONValue? {
        if let value = value as? String { return .string(value) }
        if let value = value as? Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .string(formatter.string(from: value))
        }
        if let value = value as? Data,
           let object = try? JSONSerialization.jsonObject(with: value) {
            return legacyJSONValue(object)
        }
        if let value = value as? [String] {
            return .array(value.map { .string($0) })
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            }
            return .number(value.stringValue)
        }
        if let value = value as? [Any] {
            return .array(value.compactMap(legacyJSONValue))
        }
        if let value = value as? [String: Any] {
            return .object(value.compactMapValues(legacyJSONValue))
        }
        if let value = value as? CKRecord.Reference {
            return .string(value.recordID.recordName)
        }
        return nil
    }

    func submitLegacyExport(_ export: LegacyImportExport,
                            importID: String?) async throws -> LegacyImportResponse {
        let path = importID.map {
            "/api/mobile/migrations/cloudkit/\($0)"
        } ?? "/api/mobile/migrations/cloudkit"
        guard let url = URL(string: path, relativeTo: SettlementAPIConfiguration.baseURL)?.absoluteURL,
              let token = SettlementTokenStore.read(), !token.isEmpty else {
            throw LegacyImportError.noAPIAccount
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["export": export])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LegacyImportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message: String?
            if let payload = try? JSONDecoder().decode([String: String].self, from: data) {
                message = payload["error"]
            } else {
                message = nil
            }
            throw LegacyImportError.server(status: http.statusCode, message: message)
        }
        guard let result = try? JSONDecoder().decode(LegacyImportResponse.self, from: data) else {
            throw LegacyImportError.invalidResponse
        }
        return result
    }
}

private extension CKRecord {
    func string(_ key: String) -> String? { self[key] as? String }
    func date(_ key: String) -> Date? { self[key] as? Date }
}

// MARK: - Server-authoritative social catalog

struct ServerFriendProfile: Decodable, Equatable, Sendable {
    let id: String
    let username: String?
    let name: String?
    let preferredName: String?
    let image: String?

    var displayName: String {
        [username, preferredName, name]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.caseInsensitiveCompare("You") != .orderedSame else {
                    return nil
                }
                return trimmed
            }
            .first ?? "Friend"
    }
}

private struct ServerFriendsEnvelope: Decodable, Sendable {
    let friends: [ServerFriendProfile]
}

private struct ServerGroupCatalogEnvelope: Decodable, Sendable {
    let groups: [ServerGroupCatalogItem]
}

private struct ServerSyncTokenEnvelope: Decodable, Sendable {
    let token: String
}

private struct ServerRewardEventsEnvelope: Decodable, Sendable {
    let events: [ServerRewardEvent]
}

struct ServerRewardEvent: Decodable, Equatable, Sendable {
    let action: String
    let eventID: String

    private enum CodingKeys: String, CodingKey {
        case action
        case eventID = "eventId"
    }
}

enum SharedRewardReconciler {
    static func eventID(for serverEventID: String) -> UUID {
        if let uuid = UUID(uuidString: serverEventID) { return uuid }
        var bytes = Array(
            SHA256.hash(data: Data("BillBandit.reward:\(serverEventID)".utf8)).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    @MainActor
    @discardableResult
    static func apply(
        _ events: [ServerRewardEvent],
        context: ModelContext
    ) -> [RewardOutcome] {
        guard let current = ((try? context.fetch(
            FetchDescriptor<Person>(predicate: #Predicate { $0.isCurrentUser })
        )) ?? []).first else { return [] }

        var outcomes = [RewardOutcome]()
        var attempted = false
        for event in events {
            guard let action = RewardAction(rawValue: event.action) else { continue }
            attempted = true
            if let outcome = try? RewardEngine.award(
                action: action,
                eventID: eventID(for: event.eventID),
                personID: current.id,
                context: context
            ) {
                outcomes.append(outcome)
            }
        }
        if attempted { try? context.save() }
        return outcomes
    }
}

extension Notification.Name {
    static let billBanditServerCatalogDidRefresh = Notification.Name(
        "BillBanditServerCatalogDidRefresh"
    )
}

struct ServerGroupCatalogItem: Decodable, Equatable, Sendable {
    struct Member: Decodable, Equatable, Sendable {
        let userID: String
        let memberID: String?
        let role: String
        let user: ServerFriendProfile

        private enum CodingKeys: String, CodingKey {
            case userID = "userId"
            case memberID = "memberId"
            case role
            case user
        }
    }

    let id: String
    let name: String
    let category: String?
    let members: [Member]
    let createdAt: String?
}

enum ServerGroupCatalogProjection {
    @MainActor
    static func applyCurrentProfile(
        _ profile: UsernameIdentityService.RemoteUser,
        context: ModelContext
    ) {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard let current = people.first(where: \.isCurrentUser) else { return }
        current.serverAccountID = profile.id
        if let avatar = ProfileAvatar(serverImage: profile.image) {
            current.profileAvatar = avatar
        }
        try? context.save()
    }

    @MainActor
    @discardableResult
    static func applyFriends(
        _ profiles: [ServerFriendProfile],
        currentAccountID: String,
        context: ModelContext
    ) -> [Person] {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard let current = people.first(where: \.isCurrentUser) else { return [] }
        current.serverAccountID = currentAccountID
        for duplicate in people where
            !duplicate.isCurrentUser && duplicate.serverAccountID == currentAccountID {
            _ = ConnectedFriendIdentity.mergeLegacyFriend(
                duplicate,
                into: current,
                context: context
            )
        }

        let acceptedAccountIDs = Set(profiles.map(\.id))
        var result = [Person]()
        for profile in profiles where profile.id != currentAccountID {
            result.append(
                upsertFriend(
                    profile,
                    currentAccountID: currentAccountID,
                    context: context
                )
            )
        }

        let refreshedPeople = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        // CloudKit-only friend rows came from the retired social authority.
        // Keep them for ledger history, but do not show a stale or placeholder
        // profile beside the server-authoritative friend list.
        for person in refreshedPeople where
            !person.isCurrentUser && person.serverAccountID == nil &&
                person.cloudUserRecordName?.isEmpty == false {
            person.friendshipStateRaw = "legacy"
        }
        for person in refreshedPeople where
            !person.isCurrentUser && person.friendshipStateRaw == "accepted" {
            guard let accountID = person.serverAccountID else { continue }
            if !acceptedAccountIDs.contains(accountID) {
                person.friendshipStateRaw = nil
            }
        }
        ConnectedFriendIdentity.repairDuplicateAccounts(context: context)
        try? context.save()
        return ConnectedFriendIdentity.actualFriends(
            from: (try? context.fetch(FetchDescriptor<Person>())) ?? []
        )
    }

    @MainActor
    @discardableResult
    static func upsertFriend(
        _ profile: ServerFriendProfile,
        currentAccountID: String,
        context: ModelContext
    ) -> Person {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let current = people.first(where: \.isCurrentUser) ?? {
            let value = Person(name: "You", isCurrentUser: true)
            context.insert(value)
            return value
        }()
        current.serverAccountID = currentAccountID
        let friend = person(
            for: profile,
            current: current,
            people: people,
            context: context
        )
        _ = ConnectedFriendIdentity.normalizeIncomingFriend(
            friend,
            serverAccountID: profile.id
        )
        friend.name = profile.displayName
        if let avatar = ProfileAvatar(serverImage: profile.image) {
            friend.profileAvatar = avatar
        }
        try? context.save()
        return friend
    }

    @MainActor
    @discardableResult
    static func applyGroups(
        _ catalog: [ServerGroupCatalogItem],
        currentAccountID: String,
        context: ModelContext
    ) -> [Group] {
        let currentGroups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let remoteIDs = Set(catalog.map(\.id))

        for item in catalog {
            let matches = currentGroups.filter { $0.serverLedgerGroupID == item.id }
            let group = matches.first ?? {
                let created = Group(
                    name: item.name,
                    icon: icon(for: item.category),
                    createdAt: date(item.createdAt) ?? .now,
                    serverGroupId: item.id,
                    serverAccountId: currentAccountID
                )
                context.insert(created)
                return created
            }()
            group.name = item.name
            group.serverGroupId = item.id
            group.serverAccountId = currentAccountID

            let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
            let current = people.first(where: \.isCurrentUser)
            var members = [Person]()
            var seen = Set<UUID>()
            for member in item.members {
                let accountID = member.userID.isEmpty ? member.user.id : member.userID
                let person: Person
                if accountID == currentAccountID, let current {
                    current.serverAccountID = currentAccountID
                    if let avatar = ProfileAvatar(serverImage: member.user.image) {
                        current.profileAvatar = avatar
                    }
                    person = current
                } else if let existing = people.first(where: {
                    !$0.isCurrentUser && $0.serverAccountID == accountID
                }) {
                    // The friend catalog owns accepted-friend profile names.
                    // A group projection must not replace that name with an
                    // older participant snapshot from the ledger.
                    if existing.friendshipStateRaw != "accepted" ||
                        existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        existing.name.caseInsensitiveCompare("Unknown member") == .orderedSame {
                        existing.name = member.user.displayName
                    }
                    if let avatar = ProfileAvatar(serverImage: member.user.image) {
                        existing.profileAvatar = avatar
                    }
                    person = existing
                } else {
                    let created = Person(name: member.user.displayName)
                    created.serverAccountID = accountID
                    if let avatar = ProfileAvatar(serverImage: member.user.image) {
                        created.profileAvatar = avatar
                    }
                    context.insert(created)
                    person = created
                }
                if seen.insert(person.id).inserted { members.append(person) }
            }
            if let current, !members.contains(where: { $0.id == current.id }) {
                members.insert(current, at: 0)
            }
            group.members = members

            // Server-backed groups do not store a second local ledger. Extra
            // routing rows from an older sync can be removed safely.
            for duplicate in matches.dropFirst()
            where duplicate.expenses.isEmpty && duplicate.settlements.isEmpty {
                context.delete(duplicate)
            }
        }

        for group in currentGroups where
            group.serverLedgerGroupID != nil &&
                group.serverAccountId == currentAccountID {
            guard let serverID = group.serverLedgerGroupID else { continue }
            if !remoteIDs.contains(serverID) {
                if group.expenses.isEmpty && group.settlements.isEmpty {
                    context.delete(group)
                } else {
                    // Keep old local history for repair or export, but remove
                    // the account scope so an archived server group cannot
                    // remain visible as a live shared group.
                    group.serverAccountId = nil
                }
            }
        }
        ConnectedFriendIdentity.repairDuplicateAccounts(context: context)
        try? context.save()
        return ((try? context.fetch(FetchDescriptor<Group>())) ?? [])
            .filter {
                $0.serverLedgerGroupID != nil &&
                    $0.serverAccountId == currentAccountID
            }
    }

    @MainActor
    static func removeFriendLocally(_ friend: Person, context: ModelContext) {
        friend.friendshipStateRaw = "removed"
        // Keep the Person row and its API identity. Existing groups, expenses,
        // splits, and settlements must keep their historical member links.
        try? context.save()
    }

    @MainActor
    private static func person(
        for profile: ServerFriendProfile,
        current: Person,
        people: [Person],
        context: ModelContext
    ) -> Person {
        if let existing = people.first(where: {
            $0.id != current.id && $0.serverAccountID == profile.id
        }) {
            return existing
        }

        let normalizedName = ConnectedFriendIdentity.normalizedName(profile.displayName)
        let legacyMatches = people.filter {
            $0.id != current.id && !$0.isCurrentUser && $0.serverAccountID == nil &&
                $0.appleUserIdentifier?.isEmpty != false &&
                ConnectedFriendIdentity.normalizedName($0.name) == normalizedName
        }
        if legacyMatches.count == 1, let legacy = legacyMatches.first { return legacy }

        let created = Person(name: profile.displayName)
        context.insert(created)
        return created
    }

    private static func icon(for category: String?) -> GroupIcon {
        switch category?.uppercased() {
        case "HOME": return .house
        case "TRIP": return .plane
        case "COUPLE": return .users
        case "WORK": return .coffee
        default: return .users
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

@MainActor
final class ServerSocialSyncService: ObservableObject {
    static let shared = ServerSocialSyncService()

    @Published private(set) var lastError: String?
    private let api = APIClient.live()
    private var refreshTask: Task<Void, Never>?
    private var activeAccountID: String?
    private var activeRemoteUser: UsernameIdentityService.RemoteUser?
    private var lastSyncToken: String?
    private var pollFailureCount = 0
    private var accountGeneration = 0

    private init() {}

    func accountDidAuthenticate(_ remoteUser: UsernameIdentityService.RemoteUser) {
        let accountChanged = activeAccountID != remoteUser.id
        if accountChanged {
            accountGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            lastSyncToken = nil
            pollFailureCount = 0
        }
        activeAccountID = remoteUser.id
        activeRemoteUser = remoteUser
        ServerGroupCatalogProjection.applyCurrentProfile(
            remoteUser,
            context: AppStore.container.mainContext
        )
        if accountChanged {
            _ = ServerGroupCatalogProjection.applyFriends(
                [],
                currentAccountID: remoteUser.id,
                context: AppStore.container.mainContext
            )
        }
    }

    func accountDidSignOut() {
        accountGeneration &+= 1
        activeAccountID = nil
        activeRemoteUser = nil
        lastSyncToken = nil
        pollFailureCount = 0
        refreshTask?.cancel()
        refreshTask = nil
        lastError = nil
        hideFriendsUntilCatalogRefresh()
    }

    func refresh() async {
        guard UsernameIdentityService.hasStoredSession else { return }
        do {
            let remoteUser = try await UsernameIdentityService.currentUser()
            await refresh(remoteUser: remoteUser)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Polls one small account fingerprint. A full catalog and ledger refresh
    /// runs only when server state changes. Four failed token polls fall back
    /// to the full path for compatibility during a staged server rollout.
    func pollForChanges() async {
        guard UsernameIdentityService.hasStoredSession else { return }
        do {
            let remoteUser: UsernameIdentityService.RemoteUser
            if let activeRemoteUser {
                remoteUser = activeRemoteUser
            } else {
                remoteUser = try await UsernameIdentityService.currentUser()
                accountDidAuthenticate(remoteUser)
            }
            let generation = accountGeneration
            let response: ServerSyncTokenEnvelope = try await api.get(
                "/api/mobile/sync-token"
            )
            guard generation == accountGeneration,
                  activeAccountID == remoteUser.id else { return }
            let token = response.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw SettlementAPIError.invalidResponse }
            pollFailureCount = 0
            if lastSyncToken == token {
                lastError = nil
                return
            }
            await refresh(remoteUser: remoteUser, observedSyncToken: token)
        } catch {
            guard !Task.isCancelled else { return }
            pollFailureCount += 1
            lastError = error.localizedDescription
            if pollFailureCount.isMultiple(of: 4) {
                await refresh()
            }
        }
    }

    func refresh(
        remoteUser: UsernameIdentityService.RemoteUser,
        observedSyncToken: String? = nil
    ) async {
        guard ServerLedgerAccountLifecycle.shared.activeAccountID == remoteUser.id else {
            return
        }
        if activeAccountID != remoteUser.id {
            accountGeneration &+= 1
            activeAccountID = remoteUser.id
            activeRemoteUser = remoteUser
            lastSyncToken = nil
            refreshTask?.cancel()
            refreshTask = nil
        } else {
            activeRemoteUser = remoteUser
        }
        if let refreshTask {
            await refreshTask.value
            guard activeAccountID == remoteUser.id else { return }
            if observedSyncToken == nil || lastSyncToken == observedSyncToken {
                return
            }
        }
        let generation = accountGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshWorker(
                remoteUser: remoteUser,
                generation: generation,
                observedSyncToken: observedSyncToken
            )
        }
        refreshTask = task
        await task.value
        if generation == accountGeneration {
            refreshTask = nil
        }
    }

    func remove(friend: Person) async throws {
        let context = AppStore.container.mainContext
        let generation = accountGeneration
        let accountIDAtStart = activeAccountID
        if let accountID = friend.serverAccountID, !accountID.isEmpty {
            let encoded = Self.pathComponent(accountID)
            let _: ServerFriendRemovalResponse = try await api.delete(
                "/api/mobile/friends/\(encoded)"
            )
        }
        guard generation == accountGeneration,
              activeAccountID == accountIDAtStart,
              ServerLedgerAccountLifecycle.shared.activeAccountID == accountIDAtStart else {
            return
        }
        ServerGroupCatalogProjection.removeFriendLocally(friend, context: context)
        await refresh()
    }

    private func refreshWorker(
        remoteUser: UsernameIdentityService.RemoteUser,
        generation: Int,
        observedSyncToken: String?
    ) async {
        do {
            let friends: ServerFriendsEnvelope = try await api.get("/api/mobile/friends")
            guard generation == accountGeneration,
                  activeAccountID == remoteUser.id,
                  !Task.isCancelled else { return }
            let context = AppStore.container.mainContext
            _ = ServerGroupCatalogProjection.applyFriends(
                friends.friends,
                currentAccountID: remoteUser.id,
                context: context
            )

            let groups: ServerGroupCatalogEnvelope = try await api.get("/api/mobile/groups")
            guard generation == accountGeneration,
                  activeAccountID == remoteUser.id,
                  !Task.isCancelled else { return }
            let localGroups = ServerGroupCatalogProjection.applyGroups(
                groups.groups,
                currentAccountID: remoteUser.id,
                context: context
            )
            await ServerLedgerSurfaceStore.shared.refresh(groups: localGroups)
            if let rewards: ServerRewardEventsEnvelope = try? await api.get(
                "/api/mobile/rewards"
            ) {
                _ = SharedRewardReconciler.apply(rewards.events, context: context)
            }
            lastSyncToken = observedSyncToken ?? lastSyncToken
            pollFailureCount = 0
            lastError = nil
            NotificationCenter.default.post(
                name: .billBanditServerCatalogDidRefresh,
                object: nil,
                userInfo: [
                    "accountID": remoteUser.id,
                    "groupIDs": localGroups.compactMap(\.serverLedgerGroupID),
                ]
            )
        } catch {
            guard generation == accountGeneration,
                  activeAccountID == remoteUser.id,
                  !Task.isCancelled else { return }
            lastError = error.localizedDescription
        }
    }

    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "/")
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func hideFriendsUntilCatalogRefresh() {
        let context = AppStore.container.mainContext
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        for person in people where
            !person.isCurrentUser && person.friendshipStateRaw == "accepted" {
            person.friendshipStateRaw = nil
        }
        try? context.save()
    }
}

private struct ServerFriendRemovalResponse: Decodable {
    let removed: Bool
}

// MARK: - Account-to-account friend invitations

enum FriendInviteCode {
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    static func normalize(_ value: String) -> String {
        value.uppercased().filter { alphabet.contains($0) }
    }

    static func isValid(_ value: String) -> Bool {
        normalize(value).count == 5
    }

    static func generate() -> String {
        String((0..<5).compactMap { _ in alphabet.randomElement() })
    }

    static func formatted(_ value: String) -> String {
        normalize(value)
    }
}

struct OutboundFriendInvite: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, accepted, expired }

    let code: String
    let createdAt: Date
    let expiresAt: Date
    var status: Status
    var acceptedFriendName: String?

    var id: String { code }
    var isUsable: Bool { status == .pending && expiresAt > .now }
}

private struct ServerFriendInviteEnvelope: Decodable {
    struct Invitation: Decodable {
        let code: String
        let createdAt: String
        let expiresAt: String
        let status: String
    }

    let invitation: Invitation
}

private struct ServerFriendClaimEnvelope: Decodable {
    let friend: ServerFriendProfile
}

private struct ServerFriendInviteRequest: Encodable {}

@MainActor
final class FriendInvitationService: ObservableObject {
    static let shared = FriendInvitationService()

    static let testFlightURL = URL(string: "https://testflight.apple.com/join/JR7WttFq")!
    private static let storageKey = "friendInvitations.outbound.v2"
    private static let legacyStorageKey = "friendInvitations.outbound.v1"

    @Published private(set) var outboundInvites: [OutboundFriendInvite] = []
    @Published private(set) var isWorking = false
    @Published var message: String?
    @Published var incomingCode = ""
    @Published var shouldPresentInviteSheet = false

    private let api = APIClient.live()
    private var sessionGeneration = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([OutboundFriendInvite].self, from: data) {
            outboundInvites = saved
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
        expireOldInvites()
    }

    var currentUsableInvite: OutboundFriendInvite? {
        outboundInvites.first(where: \.isUsable)
    }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "billbandit",
              url.host?.lowercased() == "friend",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawCode = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return
        }
        let code = FriendInviteCode.normalize(rawCode)
        guard FriendInviteCode.isValid(code) else { return }
        incomingCode = code
        shouldPresentInviteSheet = true
    }

    func createInvite() async -> OutboundFriendInvite? {
        if ProcessInfo.processInfo.arguments.contains("-friendInvitePreview") {
            let preview = OutboundFriendInvite(code: "B4NDT", createdAt: .now,
                                               expiresAt: .now.addingTimeInterval(7 * 86_400),
                                               status: .pending)
            outboundInvites = [preview]
            persist()
            return preview
        }

        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            guard UsernameIdentityService.hasStoredSession else {
                throw FriendInviteError.authenticationRequired
            }
            let remoteUser = try await UsernameIdentityService.currentUser()
            let generation = sessionGeneration
            let response: ServerFriendInviteEnvelope = try await api.post(
                "/api/mobile/friends/invitations",
                body: ServerFriendInviteRequest()
            )
            guard generation == sessionGeneration,
                  UsernameIdentityService.hasStoredSession,
                  ServerLedgerAccountLifecycle.shared.activeAccountID == remoteUser.id else {
                return nil
            }
            let code = FriendInviteCode.normalize(response.invitation.code)
            guard FriendInviteCode.isValid(code),
                  let createdAt = Self.date(response.invitation.createdAt),
                  let expiresAt = Self.date(response.invitation.expiresAt) else {
                throw FriendInviteError.invalid
            }
            let status = OutboundFriendInvite.Status(
                rawValue: response.invitation.status.lowercased()
            ) ?? .pending
            let invite = OutboundFriendInvite(
                code: code,
                createdAt: createdAt,
                expiresAt: expiresAt,
                status: status
            )
            outboundInvites = [invite]
            persist()
            return invite
        } catch {
            message = Self.readable(error)
            return nil
        }
    }

    func accept(code rawCode: String) async -> Person? {
        let code = FriendInviteCode.normalize(rawCode)
        guard FriendInviteCode.isValid(code) else {
            message = "Enter the complete 5-character invite code."
            return nil
        }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let remoteUser = try await UsernameIdentityService.currentUser()
            let generation = sessionGeneration
            let encoded = code.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? code
            let response: ServerFriendClaimEnvelope = try await api.post(
                "/api/mobile/friends/invitations/\(encoded)/claim",
                body: ServerFriendInviteRequest()
            )
            guard generation == sessionGeneration,
                  UsernameIdentityService.hasStoredSession,
                  ServerLedgerAccountLifecycle.shared.activeAccountID == remoteUser.id else {
                return nil
            }
            let friend = ServerGroupCatalogProjection.upsertFriend(
                response.friend,
                currentAccountID: remoteUser.id,
                context: AppStore.container.mainContext
            )
            await ServerSocialSyncService.shared.refresh(remoteUser: remoteUser)
            incomingCode = ""
            message = "\(friend.name) is now in your crew."
            return friend
        } catch {
            message = Self.readable(error)
            return nil
        }
    }

    func refreshAcceptedInvites() async {
        expireOldInvites()
        await ServerSocialSyncService.shared.refresh()
    }

    func shareText(for invite: OutboundFriendInvite) -> String {
        "Join my BillBandit crew. Install the beta: \(Self.testFlightURL.absoluteString)\n" +
        "Invite code: \(FriendInviteCode.formatted(invite.code))\n" +
        "Already installed? billbandit://friend?code=\(invite.code)\n" +
        "This invitation expires in 7 days."
    }

    private func expireOldInvites() {
        var changed = false
        for index in outboundInvites.indices
        where outboundInvites[index].status == .pending && outboundInvites[index].expiresAt <= .now {
            outboundInvites[index].status = .expired
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(outboundInvites) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Server account deletion removes server invitations. This only clears
    /// the device cache so no code from the deleted session remains visible.
    func resetLocalState() {
        sessionGeneration &+= 1
        outboundInvites = []
        incomingCode = ""
        shouldPresentInviteSheet = false
        message = nil
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    func deleteAccountData() async {
        resetLocalState()
    }

    private static func readable(_ error: Error) -> String {
        if let invitationError = error as? FriendInviteError {
            return invitationError.localizedDescription
        }
        switch error {
        case SettlementAPIError.unauthorized:
            return "Reconnect your Apple account before inviting friends."
        case SettlementAPIError.offline:
            return "Connect to the internet and try again."
        case let SettlementAPIError.structured(code, _, body):
            if let body,
               let response = try? JSONDecoder().decode(ServerFriendErrorResponse.self, from: body),
               !response.error.isEmpty {
                return response.error
            }
            return code
        case let SettlementAPIError.server(message):
            return message
        default:
            return error.localizedDescription
        }
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct ServerFriendErrorResponse: Decodable {
    let error: String
}

private enum FriendInviteError: LocalizedError {
    case authenticationRequired, invalid

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Reconnect your Apple account before inviting friends."
        case .invalid: return "That invitation is incomplete. Ask your friend to create a new one."
        }
    }
}
