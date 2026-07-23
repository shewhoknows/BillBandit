import CloudKit
import CoreTransferable
import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Stable, testable routing for the public invitation envelope that carries a
/// private CKShare URL to an already-connected BillBandit friend. The URL alone
/// cannot open the private share: CloudKit also verifies the invited participant.
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

/// Keeps legacy name-only friends from winning over the same person's connected
/// CloudKit identity. This matters after upgrading from BillBandit's original
/// local Add Friend flow: both rows can otherwise look identical in New Group.
enum ConnectedFriendIdentity {
    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter(\.isLetter)
    }

    static func preferredPerson(for person: Person, among people: [Person]) -> Person {
        guard !person.isCurrentUser, person.cloudUserRecordName == nil else { return person }
        let normalized = normalizedName(person.name)
        let connected = people.filter {
            !$0.isCurrentUser && $0.cloudUserRecordName != nil &&
                normalizedName($0.name) == normalized
        }
        return connected.count == 1 ? connected[0] : person
    }

    static func canonicalPeople(from people: [Person]) -> [Person] {
        var seen = Set<UUID>()
        return people.compactMap { person in
            let preferred = preferredPerson(for: person, among: people)
            return seen.insert(preferred.id).inserted ? preferred : nil
        }
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
}

/// CloudKit collaboration deliberately sits beside SwiftData instead of asking
/// SwiftData to mirror its store. SwiftData's automatic CloudKit integration is
/// private-database only, while BillBandit groups need owner/participant shares.
/// Each group therefore owns one custom record zone that can be shared as a unit.
@MainActor
final class CloudCollaborationService: ObservableObject {
    static let shared = CloudCollaborationService()

    nonisolated static let containerIdentifier = "iCloud.com.billbandit.app"
    private static let zonePrefix = "BillBandit.Group."

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
    private var isSynchronizing = false
    private var isUploading = false
    private var synchronizeRequested = false
    private var fullSynchronizationRequested = false
    private var pendingUploadGroupIDs: Set<UUID> = []
    private var uploadAttempts: [UUID: Int] = [:]
    private var uploadRetryAfter: [UUID: Date] = [:]
    private var uploadWorker: Task<Void, Never>?
    private var foregroundSyncWorker: Task<Void, Never>?
    private var invitationAttempts: [CKRecord.ID: Int] = [:]
    private var invitationRetryAfter: [CKRecord.ID: Date] = [:]
    private var subscribedZoneKeys: Set<String> = []

    private init() {
        self.container = CKContainer(identifier: Self.containerIdentifier)
    }

    func prepare() async {
        guard !isSynchronizing else { return }
        state = .checking
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                state = .unavailable(Self.message(for: accountStatus))
                return
            }
            currentUserRecordName = try await container.userRecordID().recordName
            linkCurrentPerson()
            await subscribeToAutomaticGroupInvitations()
            await subscribeToDatabaseChanges()
            await synchronize(promoteLocalChanges: true)
        } catch {
            state = .unavailable(Self.readable(error))
            lastIssue = Self.readable(error)
        }
    }

    func startForegroundSync() {
        guard foregroundSyncWorker == nil else { return }
        foregroundSyncWorker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.synchronize()
            }
        }
    }

    func stopForegroundSync() {
        foregroundSyncWorker?.cancel()
        foregroundSyncWorker = nil
    }

    func synchronize(promoteLocalChanges: Bool = false) async {
        guard !isSynchronizing, !isUploading else {
            synchronizeRequested = true
            fullSynchronizationRequested = fullSynchronizationRequested || promoteLocalChanges
            return
        }
        guard currentUserRecordName != nil else {
            await prepare()
            return
        }
        isSynchronizing = true
        state = .syncing

        var issues = await acceptPendingAutomaticGroupInvitations()
        issues.append(contentsOf: await pull(database: container.privateCloudDatabase,
                                             scope: .private))
        issues.append(contentsOf: await pull(database: container.sharedCloudDatabase,
                                             scope: .shared))
        resolveMembershipClaims()
        if promoteLocalChanges {
            issues.append(contentsOf: await promoteLocalGroups())
        }
        lastSync = .now
        if let issue = issues.first {
            lastIssue = Self.readable(issue)
        } else if pendingUploadGroupIDs.isEmpty {
            lastIssue = nil
        }
        state = .ready
        isSynchronizing = false
        startUploadWorkerIfNeeded()

        if synchronizeRequested {
            let needsFullSync = fullSynchronizationRequested
            synchronizeRequested = false
            fullSynchronizationRequested = false
            await synchronize(promoteLocalChanges: needsFullSync)
        }
    }

    /// Save locally immediately, then keep retrying the cloud mirror until it
    /// succeeds. A temporary account/network/share error must never drop a group.
    func groupDidChange(_ group: Group) {
        pendingUploadGroupIDs.insert(group.id)
        startUploadWorkerIfNeeded()
    }

    func expenseWasDeleted(_ expenseID: UUID, from group: Group) {
        deleteRecord(prefix: RecordPrefix.expense, id: expenseID, from: group)
        groupDidChange(group)
    }

    func groupWasDeleted(_ group: Group) {
        guard let zoneID = zoneID(for: group) else { return }
        let database = database(for: scope(for: group))
        Task {
            do {
                _ = try await database.deleteRecordZone(withID: zoneID)
            } catch {
                // The local delete remains authoritative. Missing/offline zones
                // are retried by the next explicit delete workflow.
            }
        }
    }

    func currentPersonDidChange() {
        linkCurrentPerson()
        let context = AppStore.container.mainContext
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        for group in groups where group.members.contains(where: \.isCurrentUser) {
            groupDidChange(group)
        }
    }

    func prepareShare(for group: Group) async throws -> CKShare {
        if currentUserRecordName == nil {
            await prepare()
        }
        guard currentUserRecordName != nil else { throw CollaborationError.iCloudUnavailable }

        if scope(for: group) == .shared { throw CollaborationError.participantCannotReshare }
        try await uploadGroup(withID: group.id)
        guard let zoneID = zoneID(for: group) else { throw CollaborationError.groupNotUploaded }

        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await database.record(for: shareID) as? CKShare {
            return existing
        }

        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = group.name as CKRecordValue
        let outcome = try await database.modifyRecords(
            saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        guard case .success(let saved)? = outcome.saveResults[share.recordID],
              let savedShare = saved as? CKShare else {
            if case .failure(let error)? = outcome.saveResults[share.recordID] { throw error }
            throw CollaborationError.shareNotSaved
        }
        return savedShare
    }

    func prepareShare(withID groupID: UUID) async throws -> CKShare {
        let context = AppStore.container.mainContext
        guard let group = ((try? context.fetch(FetchDescriptor<Group>())) ?? [])
            .first(where: { $0.id == groupID }) else {
            throw CollaborationError.groupNotUploaded
        }
        return try await prepareShare(for: group)
    }

    func accept(_ metadata: CKShare.Metadata) async {
        state = .syncing
        do {
            _ = try await container.accept(metadata)
            currentUserRecordName = try await container.userRecordID().recordName
            let issues = await pull(database: container.sharedCloudDatabase, scope: .shared)
            resolveMembershipClaims()
            let promotionIssues = await promoteLocalGroups()
            lastSync = .now
            lastIssue = (issues + promotionIssues).first.map(Self.readable)
            state = .ready
        } catch {
            state = .unavailable(Self.readable(error))
            lastIssue = Self.readable(error)
        }
    }

    // MARK: Upload

    private func promoteLocalGroups() async -> [Error] {
        let context = AppStore.container.mainContext
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        var issues: [Error] = []
        for group in groups {
            do {
                try await uploadGroup(withID: group.id)
                pendingUploadGroupIDs.remove(group.id)
                uploadAttempts[group.id] = nil
                uploadRetryAfter[group.id] = nil
            } catch {
                pendingUploadGroupIDs.insert(group.id)
                issues.append(error)
            }
        }
        return issues
    }

    private func startUploadWorkerIfNeeded() {
        guard uploadWorker == nil, !pendingUploadGroupIDs.isEmpty else { return }
        uploadWorker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingUploadGroupIDs.isEmpty {
                if self.isSynchronizing || self.isUploading {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let now = Date.now
                guard let groupID = self.pendingUploadGroupIDs.first(where: {
                    self.uploadRetryAfter[$0, default: .distantPast] <= now
                }) else {
                    let nextRetry = self.pendingUploadGroupIDs.compactMap {
                        self.uploadRetryAfter[$0]
                    }.min() ?? now.addingTimeInterval(1)
                    let wait = max(0.25, min(nextRetry.timeIntervalSince(now), 5))
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }

                self.pendingUploadGroupIDs.remove(groupID)
                self.isUploading = true
                do {
                    if self.currentUserRecordName == nil {
                        await self.prepare()
                    }
                    try await self.uploadGroup(withID: groupID)
                    self.uploadAttempts[groupID] = nil
                    self.uploadRetryAfter[groupID] = nil
                    self.lastSync = .now
                    if self.pendingUploadGroupIDs.isEmpty {
                        self.lastIssue = nil
                    }
                    self.state = .ready
                } catch {
                    let attempt = self.uploadAttempts[groupID, default: 0] + 1
                    self.uploadAttempts[groupID] = attempt
                    self.uploadRetryAfter[groupID] = Date.now.addingTimeInterval(
                        CollaborationRetryPolicy.delay(after: attempt)
                    )
                    self.pendingUploadGroupIDs.insert(groupID)
                    self.lastIssue = Self.readable(error)
                }
                self.isUploading = false
            }
            self.uploadWorker = nil
            if !self.pendingUploadGroupIDs.isEmpty {
                self.startUploadWorkerIfNeeded()
            }
            if self.synchronizeRequested {
                let needsFullSync = self.fullSynchronizationRequested
                self.synchronizeRequested = false
                self.fullSynchronizationRequested = false
                await self.synchronize(promoteLocalChanges: needsFullSync)
            }
        }
    }

    private func uploadGroup(withID groupID: UUID) async throws {
        guard currentUserRecordName != nil else { throw CollaborationError.iCloudUnavailable }
        let context = AppStore.container.mainContext
        guard let group = ((try? context.fetch(FetchDescriptor<Group>())) ?? [])
            .first(where: { $0.id == groupID }) else { return }

        let resolvedScope = scope(for: group)
        if group.cloudZoneName == nil {
            group.cloudZoneName = Self.zonePrefix + group.id.uuidString
            group.cloudZoneOwnerName = CKCurrentUserDefaultName
            group.cloudDatabaseScopeRaw = DatabaseScope.private.rawValue
            try? context.save()
        }
        guard let zoneID = zoneID(for: group) else { throw CollaborationError.groupNotUploaded }
        let database = database(for: resolvedScope)
        if resolvedScope == .private {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
        await subscribe(to: zoneID, in: database, scope: resolvedScope)

        let activity = ((try? context.fetch(FetchDescriptor<ActivityItem>())) ?? [])
            .filter { $0.groupID == group.id }
        let records = records(for: group, activity: activity, zoneID: zoneID)
        let outcome = try await database.modifyRecords(
            saving: records, deleting: [], savePolicy: .allKeys, atomically: false
        )
        if let failure = outcome.saveResults.values.compactMap({ result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }).first {
            throw failure
        }
        if resolvedScope == .private {
            try await ensureAutomaticShare(for: group, zoneID: zoneID)
        }
    }

    private func records(for group: Group, activity: [ActivityItem],
                         zoneID: CKRecordZone.ID) -> [CKRecord] {
        var records: [CKRecord] = []
        let groupRecord = CKRecord(recordType: RecordType.group,
                                   recordID: recordID(prefix: .group, id: group.id, zoneID: zoneID))
        groupRecord[Field.id] = group.id.uuidString as CKRecordValue
        groupRecord[Field.name] = group.name as CKRecordValue
        groupRecord[Field.icon] = group.iconRaw as CKRecordValue
        groupRecord[Field.simplifyDebts] = NSNumber(value: group.simplifyDebts)
        groupRecord[Field.createdAt] = group.createdAt as CKRecordValue
        groupRecord[Field.memberIDs] = group.members.map { $0.id.uuidString } as CKRecordValue
        groupRecord[Field.expenseIDs] = group.expenses.map { $0.id.uuidString } as CKRecordValue
        groupRecord[Field.settlementIDs] = group.settlements.map { $0.id.uuidString } as CKRecordValue
        groupRecord[Field.activityIDs] = activity.map { $0.id.uuidString } as CKRecordValue
        records.append(groupRecord)

        for person in group.members {
            let record = CKRecord(recordType: RecordType.person,
                                  recordID: recordID(prefix: .person, id: person.id, zoneID: zoneID))
            record[Field.id] = person.id.uuidString as CKRecordValue
            record[Field.name] = person.name as CKRecordValue
            record[Field.avatar] = person.avatarRaw as CKRecordValue?
            record[Field.cloudUser] = person.cloudUserRecordName as CKRecordValue?
            records.append(record)
        }

        for expense in group.expenses {
            let record = CKRecord(recordType: RecordType.expense,
                                  recordID: recordID(prefix: .expense, id: expense.id, zoneID: zoneID))
            record[Field.id] = expense.id.uuidString as CKRecordValue
            record[Field.groupID] = group.id.uuidString as CKRecordValue
            record[Field.title] = expense.title as CKRecordValue
            record[Field.amount] = decimalString(expense.amount) as CKRecordValue
            record[Field.date] = expense.date as CKRecordValue
            record[Field.category] = expense.categoryRaw as CKRecordValue
            record[Field.notes] = expense.notes as CKRecordValue
            record[Field.paidByID] = expense.paidBy?.id.uuidString as CKRecordValue?
            record[Field.splits] = try? JSONEncoder().encode(expense.splits.compactMap(SplitCloudValue.init)) as CKRecordValue
            records.append(record)
        }

        for settlement in group.settlements {
            let record = CKRecord(recordType: RecordType.settlement,
                                  recordID: recordID(prefix: .settlement, id: settlement.id, zoneID: zoneID))
            record[Field.id] = settlement.id.uuidString as CKRecordValue
            record[Field.groupID] = group.id.uuidString as CKRecordValue
            record[Field.amount] = decimalString(settlement.amount) as CKRecordValue
            record[Field.date] = settlement.date as CKRecordValue
            record[Field.fromID] = settlement.from?.id.uuidString as CKRecordValue?
            record[Field.toID] = settlement.to?.id.uuidString as CKRecordValue?
            records.append(record)
        }

        for item in activity {
            let record = CKRecord(recordType: RecordType.activity,
                                  recordID: recordID(prefix: .activity, id: item.id, zoneID: zoneID))
            record[Field.id] = item.id.uuidString as CKRecordValue
            record[Field.kind] = item.kindRaw as CKRecordValue
            record[Field.summary] = item.summary as CKRecordValue
            record[Field.timestamp] = item.timestamp as CKRecordValue
            record[Field.refID] = item.refID?.uuidString as CKRecordValue?
            record[Field.actorID] = item.actorID?.uuidString as CKRecordValue?
            record[Field.groupID] = item.groupID?.uuidString as CKRecordValue?
            record[Field.groupName] = item.groupName as CKRecordValue?
            records.append(record)
        }
        return records
    }

    // MARK: Automatic friend sharing

    /// A connected friend already carries their CloudKit user-record ID. Group
    /// creation uses that identity to add them directly to the zone-wide share,
    /// then publishes a small public envelope containing the private share URL.
    /// CloudKit still verifies that the accepting iCloud account is the invited
    /// participant; the URL is not sufficient to join this private share.
    private func ensureAutomaticShare(for group: Group,
                                      zoneID: CKRecordZone.ID) async throws {
        guard let currentUserRecordName else { throw CollaborationError.iCloudUnavailable }
        let disconnectedMembers = group.members.filter {
            !$0.isCurrentUser && ($0.cloudUserRecordName?.isEmpty != false)
        }
        guard disconnectedMembers.isEmpty else {
            throw CollaborationError.friendIdentityUnavailable
        }
        let recipients = AutomaticGroupShareRouting.recipients(
            from: group.members.map(\.cloudUserRecordName),
            currentUser: currentUserRecordName
        )
        guard !recipients.isEmpty else { return }

        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let existingShare = try? await database.record(for: shareID) as? CKShare
        let share = existingShare ?? CKShare(recordZoneID: zoneID)
        share.publicPermission = .none

        let oldTitle = share[CKShare.SystemFieldKey.title] as? String
        let titleChanged = oldTitle != group.name
        if titleChanged {
            share[CKShare.SystemFieldKey.title] = group.name as CKRecordValue
        }

        var participantCloudUsers = Set(
            share.participants.compactMap { $0.userIdentity.userRecordID?.recordName }
        )
        let missingRecipients = recipients.filter { !participantCloudUsers.contains($0) }
        var firstParticipantError: Error?
        var addedParticipant = false

        if !missingRecipients.isEmpty {
            let recordIDs = missingRecipients.map(CKRecord.ID.init(recordName:))
            let participantResults = try await container.shareParticipants(
                forUserRecordIDs: recordIDs
            )
            for recordID in recordIDs {
                switch participantResults[recordID] {
                case .success(let participant):
                    participant.permission = .readWrite
                    share.addParticipant(participant)
                    participantCloudUsers.insert(recordID.recordName)
                    addedParticipant = true
                case .failure(let error):
                    if firstParticipantError == nil { firstParticipantError = error }
                case nil:
                    if firstParticipantError == nil {
                        firstParticipantError = CollaborationError.friendIdentityUnavailable
                    }
                }
            }
        }

        let shouldSaveShare = existingShare == nil || titleChanged || addedParticipant
        let savedShare: CKShare
        if shouldSaveShare {
            let outcome = try await database.modifyRecords(
                saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard case .success(let saved)? = outcome.saveResults[share.recordID],
                  let value = saved as? CKShare else {
                if case .failure(let error)? = outcome.saveResults[share.recordID] { throw error }
                throw CollaborationError.shareNotSaved
            }
            savedShare = value
        } else {
            savedShare = share
        }

        guard let shareURL = savedShare.url else { throw CollaborationError.shareNotSaved }
        let invitedRecipients = recipients.filter { participantCloudUsers.contains($0) }
        try await publishAutomaticGroupInvitations(
            groupID: group.id,
            shareURL: shareURL,
            recipients: invitedRecipients,
            senderCloudUser: currentUserRecordName
        )
        if let firstParticipantError { throw firstParticipantError }
    }

    private func publishAutomaticGroupInvitations(groupID: UUID,
                                                  shareURL: URL,
                                                  recipients: [String],
                                                  senderCloudUser: String) async throws {
        let database = container.publicCloudDatabase
        for recipient in recipients {
            let recordID = CKRecord.ID(recordName: AutomaticGroupShareRouting.recordName(
                groupID: groupID,
                recipientCloudUser: recipient
            ))
            let record = (try? await database.record(for: recordID)) ??
                CKRecord(recordType: AutomaticGroupShareRouting.recordType, recordID: recordID)
            record[AutomaticInvitationField.groupID] = groupID.uuidString as CKRecordValue
            record[AutomaticInvitationField.recipientCloudUser] = recipient as CKRecordValue
            record[AutomaticInvitationField.senderCloudUser] = senderCloudUser as CKRecordValue
            record[AutomaticInvitationField.shareURL] = shareURL.absoluteString as CKRecordValue
            if record[AutomaticInvitationField.createdAt] == nil {
                record[AutomaticInvitationField.createdAt] = Date.now as CKRecordValue
            }
            record[AutomaticInvitationField.updatedAt] = Date.now as CKRecordValue
            _ = try await database.save(record)
        }
    }

    /// The recipient app polls this query on launch/foreground and receives a
    /// silent push for new envelopes. Acceptance is automatic because the user
    /// already explicitly connected this account as a BillBandit friend.
    private func acceptPendingAutomaticGroupInvitations() async -> [Error] {
        guard let currentUserRecordName else { return [CollaborationError.iCloudUnavailable] }
        let predicate = NSPredicate(
            format: "%K == %@",
            AutomaticInvitationField.recipientCloudUser,
            currentUserRecordName
        )
        let query = CKQuery(recordType: AutomaticGroupShareRouting.recordType,
                            predicate: predicate)
        let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                   queryCursor: CKQueryOperation.Cursor?)
        do {
            page = try await container.publicCloudDatabase.records(
                matching: query,
                desiredKeys: [AutomaticInvitationField.groupID, AutomaticInvitationField.shareURL],
                resultsLimit: 200
            )
        } catch {
            return [error]
        }
        let context = AppStore.container.mainContext
        let localGroups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let sharedGroupIDs = Set(localGroups.filter { scope(for: $0) == .shared }.map(\.id))
        var issues: [Error] = []

        for (recordID, result) in page.matchResults {
            guard invitationRetryAfter[recordID, default: .distantPast] <= .now else { continue }
            guard case .success(let record) = result else {
                if case .failure(let error) = result { issues.append(error) }
                continue
            }
            guard let groupID = record.uuid(AutomaticInvitationField.groupID),
                  !sharedGroupIDs.contains(groupID),
                  let rawURL = record.string(AutomaticInvitationField.shareURL),
                  let shareURL = URL(string: rawURL) else { continue }

            do {
                let metadataResults = try await container.shareMetadatas(for: [shareURL])
                guard case .success(let metadata)? = metadataResults[shareURL] else {
                    if case .failure(let error)? = metadataResults[shareURL] { throw error }
                    throw CollaborationError.shareMetadataUnavailable
                }
                _ = try await container.accept(metadata)
                invitationAttempts[recordID] = nil
                invitationRetryAfter[recordID] = nil
            } catch {
                // A stale or temporarily unavailable share must not prevent other
                // groups (or already-shared expenses) from syncing in this pass.
                let attempt = invitationAttempts[recordID, default: 0] + 1
                invitationAttempts[recordID] = attempt
                invitationRetryAfter[recordID] = Date.now.addingTimeInterval(
                    CollaborationRetryPolicy.delay(after: attempt)
                )
                issues.append(error)
            }
        }
        return issues
    }

    private func subscribeToAutomaticGroupInvitations() async {
        guard let currentUserRecordName else { return }
        let database = container.publicCloudDatabase
        let subscriptionID = AutomaticGroupShareRouting.subscriptionID(
            for: currentUserRecordName
        )
        if (try? await database.subscription(for: subscriptionID)) != nil { return }

        let predicate = NSPredicate(
            format: "%K == %@",
            AutomaticInvitationField.recipientCloudUser,
            currentUserRecordName
        )
        let subscription = CKQuerySubscription(
            recordType: AutomaticGroupShareRouting.recordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification
        _ = try? await database.save(subscription)
    }

    /// A database subscription is the recommended CloudKit safety net for the
    /// shared database because new accepted zones are not known in advance.
    private func subscribeToDatabaseChanges() async {
        for (scope, database) in [
            (DatabaseScope.private, container.privateCloudDatabase),
            (DatabaseScope.shared, container.sharedCloudDatabase),
        ] {
            let subscriptionID = "BillBandit.Database.\(scope.rawValue)"
            if (try? await database.subscription(for: subscriptionID)) != nil { continue }
            let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
            let notification = CKSubscription.NotificationInfo()
            notification.shouldSendContentAvailable = true
            subscription.notificationInfo = notification
            do {
                _ = try await database.save(subscription)
            } catch {
                lastIssue = Self.readable(error)
            }
        }
    }

    private func deleteRecord(prefix: RecordPrefix, id: UUID, from group: Group) {
        guard let zoneID = zoneID(for: group) else { return }
        let database = database(for: scope(for: group))
        let id = recordID(prefix: prefix, id: id, zoneID: zoneID)
        Task { try? await database.deleteRecord(withID: id) }
    }

    // MARK: Pull

    private func pull(database: CKDatabase, scope: DatabaseScope) async -> [Error] {
        let zones: [CKRecordZone]
        do {
            zones = try await database.allRecordZones()
                .filter { $0.zoneID.zoneName.hasPrefix(Self.zonePrefix) }
        } catch {
            return [error]
        }
        var issues: [Error] = []
        for zone in zones {
            await subscribe(to: zone.zoneID, in: database, scope: scope)
            do {
                try await pull(zoneID: zone.zoneID, database: database, scope: scope)
            } catch {
                // One damaged/deleted/busy zone must not block every other group.
                issues.append(error)
            }
        }
        return issues
    }

    private func pull(zoneID: CKRecordZone.ID, database: CKDatabase,
                      scope: DatabaseScope) async throws {
        var token = loadToken(scope: scope, zoneID: zoneID)
        var moreComing = true
        var pendingRecords: [CKRecord] = []
        var pendingDeletions: [CKDatabase.RecordZoneChange.Deletion] = []
        while moreComing {
            do {
                let changes = try await database.recordZoneChanges(
                    inZoneWith: zoneID, since: token, resultsLimit: 200
                )
                let records = changes.modificationResultsByID.values.compactMap { result -> CKRecord? in
                    guard case .success(let modification) = result else { return nil }
                    return modification.record
                }
                pendingRecords.append(contentsOf: records)
                pendingDeletions.append(contentsOf: changes.deletions)
                token = changes.changeToken
                moreComing = changes.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                pendingRecords.removeAll()
                pendingDeletions.removeAll()
                clearToken(scope: scope, zoneID: zoneID)
            }
        }
        apply(records: pendingRecords, deletions: pendingDeletions,
              scope: scope, zoneID: zoneID)
        if let token { saveToken(token, scope: scope, zoneID: zoneID) }
    }

    private func apply(records: [CKRecord],
                       deletions: [CKDatabase.RecordZoneChange.Deletion],
                       scope: DatabaseScope, zoneID: CKRecordZone.ID) {
        let context = AppStore.container.mainContext
        var people = ((try? context.fetch(FetchDescriptor<Person>())) ?? [])
        var groups = ((try? context.fetch(FetchDescriptor<Group>())) ?? [])
        var expenses = ((try? context.fetch(FetchDescriptor<Expense>())) ?? [])
        var settlements = ((try? context.fetch(FetchDescriptor<Settlement>())) ?? [])
        var activities = ((try? context.fetch(FetchDescriptor<ActivityItem>())) ?? [])
        var manifests: [UUID: Manifest] = [:]
        var remotePeople: [UUID: Person] = [:]

        func localPerson(for remoteID: UUID?) -> Person? {
            guard let remoteID else { return nil }
            return remotePeople[remoteID] ?? people.first { $0.id == remoteID }
        }

        let ordered = records.sorted { recordRank($0.recordType) < recordRank($1.recordType) }
        for record in ordered {
            switch record.recordType {
            case RecordType.person:
                guard let remoteID = record.uuid(Field.id) else { continue }
                let cloudUser = record.string(Field.cloudUser)
                let person: Person
                if cloudUser == currentUserRecordName,
                   let current = people.first(where: \.isCurrentUser) {
                    person = current
                } else if let cloudUser,
                          let connected = people.first(where: {
                              $0.cloudUserRecordName == cloudUser
                          }) {
                    person = connected
                } else if let existing = people.first(where: { $0.id == remoteID }) {
                    person = existing
                } else {
                    person = Person(id: remoteID,
                                    name: record.string(Field.name) ?? "Member")
                    context.insert(person)
                    people.append(person)
                }
                person.name = record.string(Field.name) ?? person.name
                person.avatarRaw = record.string(Field.avatar)
                person.cloudUserRecordName = cloudUser
                if cloudUser == currentUserRecordName { person.isCurrentUser = true }
                remotePeople[remoteID] = person

            case RecordType.group:
                guard let id = record.uuid(Field.id) else { continue }
                let group = groups.first(where: { $0.id == id }) ?? Group(id: id, name: record.string(Field.name) ?? "Shared group")
                if !groups.contains(where: { $0.id == id }) { context.insert(group); groups.append(group) }
                group.name = record.string(Field.name) ?? group.name
                group.iconRaw = record.string(Field.icon) ?? group.iconRaw
                group.simplifyDebts = record.bool(Field.simplifyDebts) ?? group.simplifyDebts
                group.createdAt = record.date(Field.createdAt) ?? group.createdAt
                group.cloudZoneName = zoneID.zoneName
                group.cloudZoneOwnerName = zoneID.ownerName
                group.cloudDatabaseScopeRaw = scope.rawValue
                let memberIDs = Set(record.uuids(Field.memberIDs))
                var seenMemberIDs = Set<UUID>()
                group.members = memberIDs.compactMap { remoteID in
                    guard let person = localPerson(for: remoteID),
                          seenMemberIDs.insert(person.id).inserted else { return nil }
                    return person
                }
                let manifest = Manifest(expenses: Set(record.uuids(Field.expenseIDs)),
                                        settlements: Set(record.uuids(Field.settlementIDs)),
                                        activities: Set(record.uuids(Field.activityIDs)))
                manifests[id] = manifest
                for expense in group.expenses where !manifest.expenses.contains(expense.id) { context.delete(expense) }
                for settlement in group.settlements where !manifest.settlements.contains(settlement.id) { context.delete(settlement) }

            case RecordType.expense:
                guard let id = record.uuid(Field.id), let groupID = record.uuid(Field.groupID),
                      manifests[groupID]?.expenses.contains(id) != false,
                      let group = groups.first(where: { $0.id == groupID }) else { continue }
                let expense = expenses.first(where: { $0.id == id }) ?? Expense(
                    id: id, title: record.string(Field.title) ?? "Expense", amount: 0
                )
                if !expenses.contains(where: { $0.id == id }) { context.insert(expense); expenses.append(expense) }
                expense.title = record.string(Field.title) ?? expense.title
                expense.amount = record.decimal(Field.amount) ?? expense.amount
                expense.date = record.date(Field.date) ?? expense.date
                expense.categoryRaw = record.string(Field.category) ?? expense.categoryRaw
                expense.notes = record.string(Field.notes) ?? expense.notes
                expense.group = group
                expense.paidBy = localPerson(for: record.uuid(Field.paidByID))
                let oldSplits = expense.splits
                expense.splits.removeAll()
                for split in oldSplits { context.delete(split) }
                let cloudSplits = record.data(Field.splits).flatMap { try? JSONDecoder().decode([SplitCloudValue].self, from: $0) } ?? []
                for value in cloudSplits {
                    guard let person = localPerson(for: value.personID) else { continue }
                    let split = Split(mode: SplitMode(rawValue: value.modeRaw) ?? .equal,
                                      value: value.value, computedAmount: value.computedAmount,
                                      person: person, expense: expense)
                    context.insert(split)
                    expense.splits.append(split)
                }
                if !group.expenses.contains(where: { $0.id == id }) { group.expenses.append(expense) }

            case RecordType.settlement:
                guard let id = record.uuid(Field.id), let groupID = record.uuid(Field.groupID),
                      manifests[groupID]?.settlements.contains(id) != false,
                      let group = groups.first(where: { $0.id == groupID }) else { continue }
                let settlement = settlements.first(where: { $0.id == id }) ?? Settlement(id: id, amount: record.decimal(Field.amount) ?? 0)
                if !settlements.contains(where: { $0.id == id }) { context.insert(settlement); settlements.append(settlement) }
                settlement.amount = record.decimal(Field.amount) ?? settlement.amount
                settlement.date = record.date(Field.date) ?? settlement.date
                settlement.from = localPerson(for: record.uuid(Field.fromID))
                settlement.to = localPerson(for: record.uuid(Field.toID))
                settlement.group = group
                if !group.settlements.contains(where: { $0.id == id }) { group.settlements.append(settlement) }

            case RecordType.activity:
                guard let id = record.uuid(Field.id),
                      let groupID = record.uuid(Field.groupID),
                      manifests[groupID]?.activities.contains(id) != false else { continue }
                let item = activities.first(where: { $0.id == id }) ?? ActivityItem(
                    id: id,
                    kind: ActivityKind(rawValue: record.string(Field.kind) ?? "") ?? .expenseAdded,
                    summary: record.string(Field.summary) ?? "Group updated"
                )
                if !activities.contains(where: { $0.id == id }) { context.insert(item); activities.append(item) }
                item.kindRaw = record.string(Field.kind) ?? item.kindRaw
                item.summary = record.string(Field.summary) ?? item.summary
                item.timestamp = record.date(Field.timestamp) ?? item.timestamp
                item.refID = record.uuid(Field.refID)
                let remoteActorID = record.uuid(Field.actorID)
                item.actorID = localPerson(for: remoteActorID)?.id ?? remoteActorID
                item.groupID = groupID
                item.groupName = record.string(Field.groupName)
            default:
                continue
            }
        }

        for deletion in deletions {
            guard let id = uuid(from: deletion.recordID.recordName) else { continue }
            switch deletion.recordType {
            case RecordType.expense:
                if let value = expenses.first(where: { $0.id == id }) { context.delete(value) }
            case RecordType.settlement:
                if let value = settlements.first(where: { $0.id == id }) { context.delete(value) }
            case RecordType.activity:
                if let value = activities.first(where: { $0.id == id }) { context.delete(value) }
            case RecordType.group:
                if let value = groups.first(where: { $0.id == id }) { context.delete(value) }
            default:
                break
            }
        }
        try? context.save()
    }

    // MARK: Helpers

    private func linkCurrentPerson() {
        guard let recordName = currentUserRecordName else { return }
        let context = AppStore.container.mainContext
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard let current = people.first(where: \.isCurrentUser) else { return }
        current.cloudUserRecordName = recordName
        try? context.save()
    }

    /// CloudKit invitations identify an Apple account, while a BillBandit invoice
    /// identifies people by the names chosen by its owner. Exact name matches are
    /// claimed automatically; ambiguous groups pause for one explicit choice.
    private func resolveMembershipClaims() {
        guard let recordName = currentUserRecordName else { return }
        let context = AppStore.container.mainContext
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        guard let current = people.first(where: \.isCurrentUser) else { return }
        current.cloudUserRecordName = recordName

        pendingMemberClaimGroupID = nil
        for group in groups where scope(for: group) == .shared {
            if group.members.contains(where: { $0.cloudUserRecordName == recordName || $0.id == current.id }) {
                continue
            }
            let available = group.members.filter { $0.cloudUserRecordName == nil }
            let matches = available.filter {
                ConnectedFriendIdentity.normalizedName($0.name) ==
                    ConnectedFriendIdentity.normalizedName(current.name)
            }
            if matches.count == 1, let match = matches.first {
                replaceMember(match, with: current, in: group)
            } else if pendingMemberClaimGroupID == nil {
                pendingMemberClaimGroupID = group.id
            }
        }
        try? context.save()
    }

    func claimCurrentUser(in groupID: UUID, as memberID: UUID?) {
        guard let recordName = currentUserRecordName else { return }
        let context = AppStore.container.mainContext
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        guard let current = people.first(where: \.isCurrentUser),
              let group = groups.first(where: { $0.id == groupID }) else { return }

        current.cloudUserRecordName = recordName
        if let memberID, let member = group.members.first(where: { $0.id == memberID }) {
            replaceMember(member, with: current, in: group)
        } else if !group.members.contains(where: { $0.id == current.id }) {
            group.members.append(current)
        }
        try? context.save()
        pendingMemberClaimGroupID = nil
        groupDidChange(group)
        resolveMembershipClaims()
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
        let context = AppStore.container.mainContext
        let activities = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        for item in activities where item.groupID == group.id && item.actorID == member.id {
            item.actorID = current.id
        }
        current.cloudUserRecordName = currentUserRecordName
    }

    private func scope(for group: Group) -> DatabaseScope {
        DatabaseScope(rawValue: group.cloudDatabaseScopeRaw ?? "") ?? .private
    }

    private func database(for scope: DatabaseScope) -> CKDatabase {
        scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for group: Group) -> CKRecordZone.ID? {
        guard let zoneName = group.cloudZoneName else { return nil }
        return CKRecordZone.ID(zoneName: zoneName,
                               ownerName: group.cloudZoneOwnerName ?? CKCurrentUserDefaultName)
    }

    private func recordID(prefix: RecordPrefix, id: UUID,
                          zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(prefix.rawValue)-\(id.uuidString)", zoneID: zoneID)
    }

    private func uuid(from recordName: String) -> UUID? {
        guard let dash = recordName.firstIndex(of: "-") else { return nil }
        return UUID(uuidString: String(recordName[recordName.index(after: dash)...]))
    }

    private func recordRank(_ type: String) -> Int {
        switch type {
        case RecordType.person: return 0
        case RecordType.group: return 1
        case RecordType.expense: return 2
        case RecordType.settlement: return 3
        case RecordType.activity: return 4
        default: return 5
        }
    }

    private func tokenKey(scope: DatabaseScope, zoneID: CKRecordZone.ID) -> String {
        "cloudToken.\(scope.rawValue).\(zoneID.ownerName).\(zoneID.zoneName)"
    }

    private func subscribe(to zoneID: CKRecordZone.ID, in database: CKDatabase,
                           scope: DatabaseScope) async {
        let rawID = "BillBandit.\(scope.rawValue).\(zoneID.ownerName).\(zoneID.zoneName)"
        let subscriptionID = String(rawID.prefix(255))
        guard subscribedZoneKeys.insert(subscriptionID).inserted else { return }
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification
        do {
            _ = try await database.save(subscription)
        } catch {
            subscribedZoneKeys.remove(subscriptionID)
        }
    }

    private func loadToken(scope: DatabaseScope, zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey(scope: scope, zoneID: zoneID)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveToken(_ token: CKServerChangeToken, scope: DatabaseScope,
                           zoneID: CKRecordZone.ID) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                           requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: tokenKey(scope: scope, zoneID: zoneID))
    }

    private func clearToken(scope: DatabaseScope, zoneID: CKRecordZone.ID) {
        UserDefaults.standard.removeObject(forKey: tokenKey(scope: scope, zoneID: zoneID))
    }

    private static func message(for status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return "Sign in to iCloud in Settings to share groups."
        case .restricted: return "iCloud access is restricted on this device."
        case .couldNotDetermine: return "BillBandit could not check iCloud right now."
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable."
        case .available: return ""
        @unknown default: return "iCloud is unavailable."
        }
    }

    private static func readable(_ error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to share groups."
            case .networkFailure, .networkUnavailable: return "Cloud sync will retry when you're online."
            case .quotaExceeded: return "Your iCloud storage is full."
            case .permissionFailure: return "BillBandit needs iCloud permission to share groups."
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Account-to-account friend invitations

/// Friend discovery is deliberately invitation-only. BillBandit never exposes a
/// searchable Apple-account directory: the recipient must know a short-lived,
/// high-entropy code (or scan its QR code) before either profile is revealed.
enum FriendInviteCode {
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    static func normalize(_ value: String) -> String {
        value.uppercased().filter { alphabet.contains($0) }
    }

    static func isValid(_ value: String) -> Bool {
        normalize(value).count == 10
    }

    static func generate() -> String {
        String((0..<10).compactMap { _ in alphabet.randomElement() })
    }

    static func formatted(_ value: String) -> String {
        let code = normalize(value)
        guard code.count > 5 else { return code }
        let split = code.index(code.startIndex, offsetBy: 5)
        return "\(code[..<split])-\(code[split...])"
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

@MainActor
final class FriendInvitationService: ObservableObject {
    static let shared = FriendInvitationService()

    static let testFlightURL = URL(string: "https://testflight.apple.com/join/JR7WttFq")!
    private static let inviteRecordType = "BBFriendInvite"
    private static let acceptanceRecordType = "BBFriendAcceptance"
    private static let inviteRecordPrefix = "BBFriendInvite-"
    private static let acceptanceRecordPrefix = "BBFriendAcceptance-"
    private static let storageKey = "friendInvitations.outbound.v1"

    @Published private(set) var outboundInvites: [OutboundFriendInvite] = []
    @Published private(set) var isWorking = false
    @Published var message: String?
    @Published var incomingCode = ""
    @Published var shouldPresentInviteSheet = false

    private let container = CKContainer(identifier: CloudCollaborationService.containerIdentifier)
    private var database: CKDatabase { container.publicCloudDatabase }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([OutboundFriendInvite].self, from: data) {
            outboundInvites = saved
        }
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
            let preview = OutboundFriendInvite(code: "B4NDTCREW2", createdAt: .now,
                                               expiresAt: .now.addingTimeInterval(7 * 86_400),
                                               status: .pending)
            outboundInvites = [preview]
            persist()
            return preview
        }
        guard let profile = currentProfile else {
            message = "Finish your profile before inviting a friend."
            return nil
        }
        if let currentUsableInvite { return currentUsableInvite }

        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else { throw FriendInviteError.iCloudUnavailable }
            let cloudUser = try await container.userRecordID().recordName
            var invite: OutboundFriendInvite?
            for _ in 0..<4 {
                let code = FriendInviteCode.generate()
                let createdAt = Date.now
                let expiresAt = createdAt.addingTimeInterval(7 * 86_400)
                let record = CKRecord(recordType: Self.inviteRecordType,
                                      recordID: inviteRecordID(code))
                record["code"] = code as CKRecordValue
                record["inviterCloudUser"] = cloudUser as CKRecordValue
                record["inviterName"] = profile.name as CKRecordValue
                record["inviterAvatar"] = profile.profileAvatar.rawValue as CKRecordValue
                record["createdAt"] = createdAt as CKRecordValue
                record["expiresAt"] = expiresAt as CKRecordValue
                do {
                    _ = try await database.save(record)
                    invite = OutboundFriendInvite(code: code, createdAt: createdAt,
                                                  expiresAt: expiresAt, status: .pending)
                    break
                } catch let error as CKError where error.code == .serverRecordChanged ||
                                                       error.code == .constraintViolation {
                    continue
                }
            }
            guard let invite else { throw FriendInviteError.couldNotCreateCode }
            outboundInvites.insert(invite, at: 0)
            persist()
            return invite
        } catch {
            message = Self.readable(error)
            return nil
        }
    }

    func accept(code rawCode: String) async -> Person? {
        guard let profile = currentProfile else {
            message = "Finish your profile before accepting an invitation."
            return nil
        }
        let code = FriendInviteCode.normalize(rawCode)
        guard FriendInviteCode.isValid(code) else {
            message = "Enter the complete 10-character invite code."
            return nil
        }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else { throw FriendInviteError.iCloudUnavailable }
            let cloudUser = try await container.userRecordID().recordName
            let invite = try await database.record(for: inviteRecordID(code))
            guard let expiresAt = invite["expiresAt"] as? Date, expiresAt > .now else {
                throw FriendInviteError.expired
            }
            guard let inviterCloudUser = invite["inviterCloudUser"] as? String,
                  let inviterName = invite["inviterName"] as? String else {
                throw FriendInviteError.invalid
            }
            guard inviterCloudUser != cloudUser else { throw FriendInviteError.ownInvite }

            let acceptanceID = acceptanceRecordID(code)
            if let existing = try? await database.record(for: acceptanceID) {
                guard existing["accepterCloudUser"] as? String == cloudUser else {
                    throw FriendInviteError.alreadyAccepted
                }
            } else {
                let record = CKRecord(recordType: Self.acceptanceRecordType,
                                      recordID: acceptanceID)
                record["inviteCode"] = code as CKRecordValue
                record["accepterCloudUser"] = cloudUser as CKRecordValue
                record["accepterName"] = profile.name as CKRecordValue
                record["accepterAvatar"] = profile.profileAvatar.rawValue as CKRecordValue
                record["acceptedAt"] = Date.now as CKRecordValue
                do {
                    _ = try await database.save(record)
                } catch {
                    guard let existing = try? await database.record(for: acceptanceID),
                          existing["accepterCloudUser"] as? String == cloudUser else {
                        throw FriendInviteError.alreadyAccepted
                    }
                }
            }

            let avatarRaw = invite["inviterAvatar"] as? String
            let friend = linkFriend(name: inviterName, avatarRaw: avatarRaw,
                                    cloudUser: inviterCloudUser)
            incomingCode = ""
            message = "\(friend.name) is now in your crew."
            return friend
        } catch let error as CKError where error.code == .unknownItem {
            message = FriendInviteError.notFound.localizedDescription
            return nil
        } catch {
            message = Self.readable(error)
            return nil
        }
    }

    func refreshAcceptedInvites() async {
        expireOldInvites()
        // Accepted invitations are deliberately re-read too. This repairs stores
        // upgraded from the old name-only friend flow, where a legacy duplicate
        // may still be attached to groups even though the connected row exists.
        let refreshable = outboundInvites.filter { $0.status != .expired }
        guard !refreshable.isEmpty else { return }
        guard (try? await container.accountStatus()) == .available else { return }

        var changed = false
        for invite in refreshable {
            guard let record = try? await database.record(for: acceptanceRecordID(invite.code)),
                  let cloudUser = record["accepterCloudUser"] as? String,
                  let name = record["accepterName"] as? String else { continue }
            let avatarRaw = record["accepterAvatar"] as? String
            let friend = linkFriend(name: name, avatarRaw: avatarRaw, cloudUser: cloudUser)
            if let index = outboundInvites.firstIndex(where: { $0.code == invite.code }) {
                outboundInvites[index].status = .accepted
                outboundInvites[index].acceptedFriendName = friend.name
                changed = true
            }
        }
        if changed { persist() }
    }

    func shareText(for invite: OutboundFriendInvite) -> String {
        "Join my BillBandit crew. Install the beta: \(Self.testFlightURL.absoluteString)\n" +
        "Invite code: \(FriendInviteCode.formatted(invite.code))\n" +
        "Already installed? billbandit://friend?code=\(invite.code)\n" +
        "This invitation expires in 7 days."
    }

    private var currentProfile: Person? {
        let context = AppStore.container.mainContext
        return ((try? context.fetch(FetchDescriptor<Person>())) ?? []).first(where: \.isCurrentUser)
    }

    @discardableResult
    private func linkFriend(name: String, avatarRaw: String?, cloudUser: String) -> Person {
        let context = AppStore.container.mainContext
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        if let existing = people.first(where: { $0.cloudUserRecordName == cloudUser }) {
            existing.name = name
            existing.avatarRaw = avatarRaw
            let legacyMatches = people.filter {
                !$0.isCurrentUser && $0.cloudUserRecordName == nil &&
                    ConnectedFriendIdentity.normalizedName($0.name) ==
                    ConnectedFriendIdentity.normalizedName(name)
            }
            if legacyMatches.count == 1, let legacy = legacyMatches.first {
                ConnectedFriendIdentity.mergeLegacyFriend(legacy, into: existing,
                                                           context: context)
            }
            try? context.save()
            queueGroupsContaining(existing)
            return existing
        }

        let legacyMatches = people.filter {
            !$0.isCurrentUser && $0.cloudUserRecordName == nil &&
                ConnectedFriendIdentity.normalizedName($0.name) ==
                ConnectedFriendIdentity.normalizedName(name)
        }
        let friend = legacyMatches.count == 1 ? legacyMatches[0] : Person(
            name: name.capitalizingFirstLetter,
            avatar: avatarRaw.flatMap(ProfileAvatar.init(rawValue:))
        )
        friend.name = name.capitalizingFirstLetter
        friend.avatarRaw = avatarRaw
        friend.cloudUserRecordName = cloudUser
        if legacyMatches.count != 1 { context.insert(friend) }
        if let actor = people.first(where: \.isCurrentUser) {
            context.insert(ActivityItem(kind: .friendAdded,
                                        summary: "\(actor.name) added \(friend.name)",
                                        refID: friend.id, actorID: actor.id))
            _ = try? AchievementEngine.unlock(.partnerInCrime, personID: actor.id, context: context)
        }
        try? context.save()
        queueGroupsContaining(friend)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return friend
    }

    private func queueGroupsContaining(_ friend: Person) {
        let context = AppStore.container.mainContext
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        for group in groups where group.members.contains(where: { $0.id == friend.id }) {
            CloudCollaborationService.shared.groupDidChange(group)
        }
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

    private func inviteRecordID(_ code: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.inviteRecordPrefix + code)
    }

    private func acceptanceRecordID(_ code: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.acceptanceRecordPrefix + code)
    }

    private static func readable(_ error: Error) -> String {
        if let invitationError = error as? FriendInviteError {
            return invitationError.localizedDescription
        }
        if let cloudError = error as? CKError {
            switch cloudError.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to invite friends."
            case .networkFailure, .networkUnavailable: return "Connect to the internet and try again."
            case .quotaExceeded: return "Your iCloud storage is full."
            case .permissionFailure, .serverRejectedRequest:
                return "Invitations are temporarily unavailable. Please try again shortly."
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "Invitations are busy right now. Please try again in a moment."
            default: return "BillBandit couldn't reach invitations. Please try again."
            }
        }
        return error.localizedDescription
    }
}

private enum FriendInviteError: LocalizedError {
    case iCloudUnavailable, couldNotCreateCode, notFound, expired, invalid, ownInvite, alreadyAccepted

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable: return "Sign in to iCloud in Settings to invite friends."
        case .couldNotCreateCode: return "BillBandit could not create a unique invite code. Try again."
        case .notFound: return "That invitation was not found. Check the code and try again."
        case .expired: return "That invitation has expired. Ask your friend for a new one."
        case .invalid: return "That invitation is incomplete. Ask your friend to create a new one."
        case .ownInvite: return "This is your own invitation. Share it with a friend instead."
        case .alreadyAccepted: return "That invitation has already been accepted."
        }
    }
}

// MARK: - Cloud sharing presentation

struct CloudGroupShareItem: Transferable, Sendable {
    let groupID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let container = CKContainer(identifier: CloudCollaborationService.containerIdentifier)
            let options = CKAllowedSharingOptions(
                allowedParticipantPermissionOptions: .readWrite,
                allowedParticipantAccessOptions: .specifiedRecipientsOnly
            )
            return .prepareShare(container: container, allowedSharingOptions: options) {
                try await CloudCollaborationService.shared.prepareShare(withID: item.groupID)
            }
        }
    }
}

final class CloudShareAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await CloudCollaborationService.shared.synchronize()
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in
            await CloudCollaborationService.shared.accept(cloudKitShareMetadata)
        }
    }
}

// MARK: - Record schema

private enum RecordType {
    static let group = "BBGroup"
    static let person = "BBPerson"
    static let expense = "BBExpense"
    static let settlement = "BBSettlement"
    static let activity = "BBActivity"
}

private enum RecordPrefix: String {
    case group, person, expense, settlement, activity
}

private enum Field {
    static let id = "id"
    static let name = "name"
    static let icon = "icon"
    static let avatar = "avatar"
    static let cloudUser = "cloudUser"
    static let simplifyDebts = "simplifyDebts"
    static let createdAt = "createdAt"
    static let memberIDs = "memberIDs"
    static let expenseIDs = "expenseIDs"
    static let settlementIDs = "settlementIDs"
    static let activityIDs = "activityIDs"
    static let groupID = "groupID"
    static let title = "title"
    static let amount = "amount"
    static let date = "date"
    static let category = "category"
    static let notes = "notes"
    static let paidByID = "paidByID"
    static let splits = "splits"
    static let fromID = "fromID"
    static let toID = "toID"
    static let kind = "kind"
    static let summary = "summary"
    static let timestamp = "timestamp"
    static let refID = "refID"
    static let actorID = "actorID"
    static let groupName = "groupName"
}

private enum AutomaticInvitationField {
    static let groupID = "groupID"
    static let recipientCloudUser = "recipientCloudUser"
    static let senderCloudUser = "senderCloudUser"
    static let shareURL = "shareURL"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
}

private struct Manifest {
    let expenses: Set<UUID>
    let settlements: Set<UUID>
    let activities: Set<UUID>
}

private struct SplitCloudValue: Codable {
    let personID: UUID
    let modeRaw: String
    let valueString: String
    let computedAmountString: String

    init?(_ split: Split) {
        guard let personID = split.person?.id else { return nil }
        self.personID = personID
        self.modeRaw = split.modeRaw
        self.valueString = decimalString(split.value)
        self.computedAmountString = decimalString(split.computedAmount)
    }

    var value: Decimal { Decimal(string: valueString) ?? 0 }
    var computedAmount: Decimal { Decimal(string: computedAmountString) ?? 0 }
}

private enum CollaborationError: LocalizedError {
    case iCloudUnavailable
    case groupNotUploaded
    case participantCannotReshare
    case shareNotSaved
    case friendIdentityUnavailable
    case shareMetadataUnavailable

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable: return "iCloud is not available for group sharing."
        case .groupNotUploaded: return "This group has not finished syncing yet."
        case .participantCannotReshare: return "Only the group owner can manage invitations."
        case .shareNotSaved: return "BillBandit could not create the group invitation."
        case .friendIdentityUnavailable: return "BillBandit could not connect one group member to iCloud yet. It will retry automatically."
        case .shareMetadataUnavailable: return "The shared group is still preparing. BillBandit will retry automatically."
        }
    }
}

private func decimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}

private extension CKRecord {
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    func date(_ key: String) -> Date? { self[key] as? Date }
    func data(_ key: String) -> Data? { self[key] as? Data }
    func uuid(_ key: String) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }
    func uuids(_ key: String) -> [UUID] {
        (self[key] as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }
    func decimal(_ key: String) -> Decimal? { string(key).flatMap { Decimal(string: $0) } }
}
