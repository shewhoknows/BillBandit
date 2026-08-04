import Foundation
import SwiftData
import UserNotifications

/// One-way cleanup for reminder controls removed from the product. Keep this
/// launch-safe and idempotent so installs upgrading from an earlier test build
/// cannot retain old scheduled or delivered reminder notifications.
enum LegacyReminderCleanup {
    private static let center = UNUserNotificationCenter.current()
    private static let identifiers = [
        "billbandit.reminder.pay",
        "billbandit.reminder.settle",
        "billbandit.reminder.dues",
    ]
    private static let preferenceKeys = [
        "reminder.pay",
        "reminder.settle",
        "reminder.dues",
    ]

    static func retire() {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        let defaults = UserDefaults.standard
        preferenceKeys.forEach { defaults.removeObject(forKey: $0) }
    }
}

/// App-wide SwiftData container + DEBUG seed data mirroring the mockup board.
enum AppStore {

    @MainActor private static var didPrepareStore = false

    static let schema = Schema([
        Person.self, Group.self, Expense.self, Split.self, Settlement.self, ActivityItem.self,
        UserProgress.self, ProcessedRewardEvent.self, AchievementUnlock.self,
        CachedLedgerSnapshot.self, PendingLedgerOperation.self, CloudKitLedgerImportState.self,
    ])

    static let container: ModelContainer = {
        do {
            // Ledger cache, queue, and migration checkpoints are local SwiftData
            // records. CloudKit is intentionally not a SwiftData ledger store.
            let config = ModelConfiguration(cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }()

    static let previewContainer: ModelContainer = {
        do {
            let config = ModelConfiguration(
                "BillBanditPreview", schema: schema, isStoredInMemoryOnly: true,
                groupContainer: .none, cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Preview container failed: \(error)")
        }
    }()

    /// The one production cache/queue store used by every API-ledger surface
    /// and mutation path. Sharing this instance prevents separate SwiftData
    /// containers from presenting different cached revisions.
    @MainActor
    static let serverLedgerStore = ServerLedgerStore(context: container.mainContext)

    /// Store preparation runs once per launch. Demo fixtures are available only
    /// to explicit UI-test launches; ordinary debug and release builds never
    /// seed friends or ledgers.
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        guard !didPrepareStore else { return }
        didPrepareStore = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetDemoData") {
            SeedData.reset(context: context)
            SeedData.seedIfEmpty(context: context)
        } else {
            DemoDataIntegrity.retireFixtures(context: context)
        }
        #else
        DemoDataIntegrity.retireFixtures(context: context)
        #endif
        DemoDataIntegrity.repairDuplicateGroups(context: context)
        DemoDataIntegrity.repairDuplicatePeople(context: context)
        LedgerIntegrity.repairEmptyGroups(context: context)
        ActivityData.enrichGroupContextIfNeeded(context: context)
        if let appleUserIdentifier = UserDefaults.standard.string(forKey: "appleUserIdentifier"),
           !appleUserIdentifier.isEmpty {
            AccountProfileIntegrity.canonicalize(
                appleUserIdentifier: appleUserIdentifier,
                cloudUserRecordName: nil,
                context: context
            )
        }
        ConnectedFriendIdentity.repairDuplicateAccounts(context: context)
    }
}

enum ServerLedgerLifecycleTrigger: String, Sendable {
    case startup
    case foreground
    case reconnect
}

/// Owns the production cache and queue lifecycle. The API account ID is the
/// only identity accepted here; Apple and CloudKit identities never scope a
/// `ServerLedgerSnapshot` or `PendingLedgerOperation`.
@MainActor
final class ServerLedgerAccountLifecycle {
    static let shared = ServerLedgerAccountLifecycle()

    private static let persistedAccountIDKey = "serverLedger.authoritativeAccountID"

    private let store: ServerLedgerStore
    private let sync: ServerLedgerSync
    private(set) var activeAccountID: String?
    private(set) var cachedCanonicalSnapshots: [ServerLedgerSnapshot] = []
    private(set) var lastError: String?
    private var lifecycleGeneration = 0
    private var isReconciling = false
    private var reconciliationGeneration = 0

    private init() {
        let store = AppStore.serverLedgerStore
        self.store = store
        self.sync = ServerLedgerSync(store: store, apiClient: URLSessionServerLedgerAPIClient.live())
    }

    func activate(accountID rawAccountID: String) throws {
        let accountID = rawAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw ServerLedgerSyncError.accountScopeRequired
        }

        let persistedAccount = UserDefaults.standard.string(forKey: Self.persistedAccountIDKey)
        let previousAccount = activeAccountID ?? persistedAccount
        let accountChanged = previousAccount != accountID || activeAccountID == nil
        if let previousAccount, previousAccount != accountID {
            invalidateReconciliation()
            try store.clear(accountID: previousAccount)
        }
        if sync.activeAccountID != accountID {
            try sync.activate(accountID: accountID)
        }
        activeAccountID = accountID
        UserDefaults.standard.set(accountID, forKey: Self.persistedAccountIDKey)
        cachedCanonicalSnapshots = (try? store.cachedSnapshots(for: accountID)) ?? []
        lastError = nil
        if accountChanged { lifecycleGeneration &+= 1 }
    }

    func signOut(accountID rawAccountID: String? = nil) {
        invalidateReconciliation()
        let persistedAccount = UserDefaults.standard.string(forKey: Self.persistedAccountIDKey)
        let accounts = Set([
            rawAccountID,
            activeAccountID,
            persistedAccount,
            sync.activeAccountID,
        ].compactMap { $0 })
        if let syncAccount = sync.activeAccountID {
            try? sync.signOut(accountID: syncAccount)
        }
        for accountID in accounts {
            try? store.clear(accountID: accountID)
        }
        activeAccountID = nil
        cachedCanonicalSnapshots = []
        lastError = nil
        lifecycleGeneration &+= 1
        UserDefaults.standard.removeObject(forKey: Self.persistedAccountIDKey)
    }

    /// Loads the current account's cache first, drains only due operations for
    /// that same account, then refreshes every API-backed local group.
    func reconcile(trigger: ServerLedgerLifecycleTrigger) async {
        guard let accountID = activeAccountID else { return }
        guard !isReconciling else { return }
        isReconciling = true
        reconciliationGeneration &+= 1
        let reconciliationGeneration = self.reconciliationGeneration
        defer {
            if self.reconciliationGeneration == reconciliationGeneration {
                isReconciling = false
            }
        }
        let generation = lifecycleGeneration
        cachedCanonicalSnapshots = (try? store.cachedSnapshots(for: accountID)) ?? []
        if trigger == .reconnect || trigger == .foreground {
            sync.markReconnected()
        }

        do {
            _ = try await sync.drainPendingOperations(for: accountID)
            guard generation == lifecycleGeneration, activeAccountID == accountID else { return }

            let context = AppStore.container.mainContext
            let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
            let serverGroupIDs = groups.compactMap { SettlementAPIConfiguration.serverGroupId(for: $0) }
            for groupID in Set(serverGroupIDs).sorted() {
                guard generation == lifecycleGeneration, activeAccountID == accountID else { return }
                let scope = ServerBackedLedgerScope(accountID: accountID, groupID: groupID)
                _ = try await sync.refresh(scope: scope)
            }
            guard generation == lifecycleGeneration, activeAccountID == accountID else { return }
            cachedCanonicalSnapshots = (try? store.cachedSnapshots(for: accountID)) ?? []
            lastError = nil
        } catch let error as ServerLedgerSyncError where error == .accountChanged {
            return
        } catch {
            guard generation == lifecycleGeneration, activeAccountID == accountID else { return }
            lastError = error.localizedDescription
        }
    }

    private func invalidateReconciliation() {
        reconciliationGeneration &+= 1
        isReconciling = false
    }
}

enum AccountProfileMergePolicy {
    static func shouldApplyRemoteProfile(remoteUpdatedAt: Date?,
                                         localUpdatedAt: Date?,
                                         isCurrentUser: Bool) -> Bool {
        guard let remoteUpdatedAt else {
            // Legacy records without a timestamp may populate another legacy
            // row, but may never roll back a profile already edited in-app.
            return localUpdatedAt == nil
        }
        guard let localUpdatedAt else { return true }
        return remoteUpdatedAt > localUpdatedAt
    }
}

/// Collapses historical duplicate "me" rows into the one profile owned by the
/// signed-in Apple account and retargets every ledger reference before deletion.
enum AccountProfileIntegrity {
    @MainActor
    @discardableResult
    static func canonicalize(appleUserIdentifier rawAppleID: String?,
                             cloudUserRecordName rawCloudUser: String?,
                             context: ModelContext) -> Person {
        let appleID = rawAppleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudUser = rawCloudUser?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableAppleID = appleID.flatMap { $0.isEmpty ? nil : $0 }
        let usableCloudUser = cloudUser.flatMap { $0.isEmpty ? nil : $0 }
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []

        // CloudKit's user record is the authoritative identity once it is
        // available. The Apple ID in UserDefaults can briefly belong to the
        // account that was signed out on this device, so it must not retarget
        // that old row to the newly signed-in CloudKit account.
        let cloudCandidates = usableCloudUser.map { cloudUser in
            people.filter { $0.cloudUserRecordName == cloudUser }
        } ?? []
        let appleCandidates = usableAppleID.map { appleID in
            people.filter { $0.appleUserIdentifier == appleID }
        } ?? []
        let candidates: [Person]
        if !cloudCandidates.isEmpty {
            // Include only Apple-ID duplicates that are not already linked to
            // another CloudKit account. A stale old-account row must remain a
            // friend/profile record instead of being merged into this account.
            let matching = cloudCandidates + appleCandidates.filter { person in
                person.cloudUserRecordName == nil ||
                    person.cloudUserRecordName == usableCloudUser
            }
            var seen = Set<UUID>()
            candidates = matching.filter { seen.insert($0.id).inserted }
        } else if usableCloudUser != nil {
            // A new CloudKit account on a device with old local data gets a new
            // current-user row. Reusing the old current row was the source of
            // the two-Apple-ID relaunch identity flip.
            candidates = appleCandidates.filter { person in
                person.cloudUserRecordName == nil
            }
        } else {
            candidates = appleCandidates.isEmpty
                ? people.filter { $0.isCurrentUser && $0.appleUserIdentifier == nil }
                : appleCandidates
        }

        func identityScore(_ person: Person) -> Int {
            var score = 0
            if let usableAppleID, person.appleUserIdentifier == usableAppleID { score += 4 }
            if let usableCloudUser, person.cloudUserRecordName == usableCloudUser { score += 8 }
            if person.isCurrentUser { score += 1 }
            return score
        }

        let canonical = candidates.max { lhs, rhs in
            let leftScore = identityScore(lhs)
            let rightScore = identityScore(rhs)
            if leftScore != rightScore { return leftScore < rightScore }
            return (lhs.profileUpdatedAt ?? .distantPast) <
                (rhs.profileUpdatedAt ?? .distantPast)
        } ?? {
            let created = Person(name: "You", isCurrentUser: true)
            context.insert(created)
            return created
        }()

        let duplicates = candidates.filter { $0.id != canonical.id }
        if let newest = candidates.max(by: {
            ($0.profileUpdatedAt ?? .distantPast) < ($1.profileUpdatedAt ?? .distantPast)
        }), let newestDate = newest.profileUpdatedAt,
           newestDate > (canonical.profileUpdatedAt ?? .distantPast) {
            canonical.name = newest.name
            canonical.avatarRaw = newest.avatarRaw
            canonical.profileUpdatedAt = newestDate
        }

        let duplicateIDs = Set(duplicates.map(\.id))
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        for group in groups {
            if group.members.contains(where: { duplicateIDs.contains($0.id) }) {
                group.members.removeAll { duplicateIDs.contains($0.id) }
                if !group.members.contains(where: { $0.id == canonical.id }) {
                    group.members.append(canonical)
                }
            }
            for expense in group.expenses {
                if let payerID = expense.paidBy?.id, duplicateIDs.contains(payerID) {
                    expense.paidBy = canonical
                }
                for split in expense.splits {
                    if let personID = split.person?.id, duplicateIDs.contains(personID) {
                        split.person = canonical
                    }
                }
            }
            for settlement in group.settlements {
                if let fromID = settlement.from?.id, duplicateIDs.contains(fromID) {
                    settlement.from = canonical
                }
                if let toID = settlement.to?.id, duplicateIDs.contains(toID) {
                    settlement.to = canonical
                }
            }
        }

        let activities = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        for item in activities where item.actorID.map(duplicateIDs.contains) == true {
            item.actorID = canonical.id
        }

        repairProgress(from: duplicateIDs, to: canonical.id, context: context)
        for person in people { person.isCurrentUser = person.id == canonical.id }
        canonical.isCurrentUser = true
        canonical.appleUserIdentifier = usableAppleID ?? canonical.appleUserIdentifier
        canonical.cloudUserRecordName = usableCloudUser ?? canonical.cloudUserRecordName
        if canonical.profileUpdatedAt == nil && canonical.name != "You" {
            canonical.profileUpdatedAt = .now
        }
        duplicates.forEach(context.delete)
        try? context.save()
        return canonical
    }

    @MainActor
    private static func repairProgress(from duplicateIDs: Set<UUID>, to canonicalID: UUID,
                                       context: ModelContext) {
        guard !duplicateIDs.isEmpty else { return }
        let progress = (try? context.fetch(FetchDescriptor<UserProgress>())) ?? []
        let oldProgress = progress.filter { duplicateIDs.contains($0.personID) }
        if !oldProgress.isEmpty {
            let canonical = progress.first { $0.personID == canonicalID } ?? {
                let value = UserProgress(personID: canonicalID)
                context.insert(value)
                return value
            }()
            canonical.lifetimeXP = max(canonical.lifetimeXP,
                                       oldProgress.map(\.lifetimeXP).max() ?? 0)
            canonical.isEnabled = canonical.isEnabled || oldProgress.contains(where: \.isEnabled)
            oldProgress.forEach(context.delete)
        }

        let events = (try? context.fetch(FetchDescriptor<ProcessedRewardEvent>())) ?? []
        for event in events where duplicateIDs.contains(event.personID) {
            if events.contains(where: {
                $0.personID == canonicalID && $0.eventID == event.eventID &&
                    $0.actionRaw == event.actionRaw
            }) {
                context.delete(event)
            } else {
                event.personID = canonicalID
                event.key = "\(canonicalID.uuidString):\(event.actionRaw):\(event.eventID.uuidString)"
            }
        }

        let unlocks = (try? context.fetch(FetchDescriptor<AchievementUnlock>())) ?? []
        for unlock in unlocks where duplicateIDs.contains(unlock.personID) {
            if unlocks.contains(where: {
                $0.personID == canonicalID && $0.achievementRaw == unlock.achievementRaw
            }) {
                context.delete(unlock)
            } else {
                unlock.personID = canonicalID
                unlock.key = "\(canonicalID.uuidString):\(unlock.achievementRaw)"
            }
        }
    }
}

/// Prevents historical DEBUG sample ledgers from multiplying through CloudKit.
/// The fingerprint is intentionally strict so similarly named real ledgers are
/// left alone. This remains available in release builds to repair stores that
/// were contaminated by an earlier development build.
enum DemoDataIntegrity {
    enum PersonKind: CaseIterable, Hashable {
        case maya, arjun, riya, sam

        var stableID: UUID {
            switch self {
            case .maya: return UUID(uuidString: "B11B1000-0000-4000-8000-000000000002")!
            case .arjun: return UUID(uuidString: "B11B1000-0000-4000-8000-000000000003")!
            case .riya: return UUID(uuidString: "B11B1000-0000-4000-8000-000000000004")!
            case .sam: return UUID(uuidString: "B11B1000-0000-4000-8000-000000000005")!
            }
        }

        fileprivate var name: String {
            switch self {
            case .maya: return "Maya Chen"
            case .arjun: return "Arjun Rao"
            case .riya: return "Riya Kapoor"
            case .sam: return "Sam Ortiz"
            }
        }

        fileprivate var avatarRaw: String {
            switch self {
            case .maya: return ProfileAvatar.bows.rawValue
            case .arjun: return ProfileAvatar.bucketHat.rawValue
            case .riya: return ProfileAvatar.headphones.rawValue
            case .sam: return ProfileAvatar.messyTie.rawValue
            }
        }
    }

    enum Kind: CaseIterable, Hashable {
        case apartment, pizza, goa

        var stableID: UUID {
            switch self {
            case .apartment: return UUID(uuidString: "B11B0000-0000-4000-8000-000000000001")!
            case .pizza: return UUID(uuidString: "B11B0000-0000-4000-8000-000000000002")!
            case .goa: return UUID(uuidString: "B11B0000-0000-4000-8000-000000000003")!
            }
        }

        fileprivate var name: String {
            switch self {
            case .apartment: return "Apartment 4B"
            case .pizza: return "Friday Pizza"
            case .goa: return "Goa Trip"
            }
        }

        fileprivate var icon: GroupIcon {
            switch self {
            case .apartment: return .house
            case .pizza: return .pizza
            case .goa: return .plane
            }
        }

        fileprivate var memberCount: Int {
            switch self {
            case .apartment, .pizza: return 2
            case .goa: return 5
            }
        }

        fileprivate var expenses: [String: Decimal] {
            switch self {
            case .apartment:
                return ["Groceries": 54.20, "Internet bill": 113.80]
            case .pizza:
                return ["Pizza night": 153.00]
            case .goa:
                return [
                    "Taxi from airport": 120.00,
                    "Beach shack lunch": 86.50,
                    "Scooter rental (2d)": 140.00,
                    "Hotel — 3 nights": 360.00,
                    "Souvenirs": 24.00,
                ]
            }
        }
    }

    static func kind(of group: Group) -> Kind? {
        if let stable = Kind.allCases.first(where: { $0.stableID == group.id }) {
            return stable
        }
        return Kind.allCases.first { kind in
            guard group.name == kind.name,
                  group.icon == kind.icon,
                  group.members.count == kind.memberCount,
                  group.expenses.count == kind.expenses.count else { return false }
            return group.expenses.allSatisfy { expense in
                kind.expenses[expense.title] == expense.amount
            }
        }
    }

    static func shouldSync(_ group: Group) -> Bool {
        kind(of: group) == nil
    }

    private static func personKind(of person: Person) -> PersonKind? {
        if let stable = PersonKind.allCases.first(where: { $0.stableID == person.id }) {
            return stable
        }
        guard !person.isCurrentUser,
              person.cloudUserRecordName?.isEmpty != false,
              person.appleUserIdentifier?.isEmpty != false,
              person.profileUpdatedAt == nil else { return nil }
        return PersonKind.allCases.first {
            $0.name == person.name && $0.avatarRaw == person.avatarRaw
        }
    }

    /// Removes the exact historical sample ledgers and deletes their synthetic
    /// people only when those rows are not linked to an account and are not
    /// referenced by a real ledger. A seed row that later became a connected
    /// friend is preserved as real user data.
    @MainActor
    static func retireFixtures(context: ModelContext) {
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let fixtureGroups = groups.filter { kind(of: $0) != nil }
        let fixtureGroupIDs = Set(fixtureGroups.map(\.id))
        let fixtureRecordIDs = Set(fixtureGroups.flatMap { group in
            [group.id] + group.expenses.map(\.id) + group.settlements.map(\.id)
        })

        for group in fixtureGroups { context.delete(group) }
        let activities = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        for item in activities where
            item.groupID.map(fixtureGroupIDs.contains) == true ||
            item.refID.map(fixtureRecordIDs.contains) == true {
            context.delete(item)
        }
        if !fixtureGroups.isEmpty { try? context.save() }

        let remainingGroups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        var referencedPersonIDs = Set(remainingGroups.flatMap { $0.members.map(\.id) })
        for group in remainingGroups {
            for expense in group.expenses {
                if let id = expense.paidBy?.id { referencedPersonIDs.insert(id) }
                referencedPersonIDs.formUnion(expense.splits.compactMap { $0.person?.id })
            }
            for settlement in group.settlements {
                if let id = settlement.from?.id { referencedPersonIDs.insert(id) }
                if let id = settlement.to?.id { referencedPersonIDs.insert(id) }
            }
        }

        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let removable = people.filter { person in
            personKind(of: person) != nil &&
                !person.isCurrentUser &&
                person.cloudUserRecordName?.isEmpty != false &&
                person.appleUserIdentifier?.isEmpty != false &&
                !referencedPersonIDs.contains(person.id)
        }
        guard !removable.isEmpty else { return }

        let removableIDs = Set(removable.map(\.id))
        for item in (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        where item.actorID.map(removableIDs.contains) == true {
            context.delete(item)
        }
        for value in (try? context.fetch(FetchDescriptor<UserProgress>())) ?? []
        where removableIDs.contains(value.personID) {
            context.delete(value)
        }
        for value in (try? context.fetch(FetchDescriptor<ProcessedRewardEvent>())) ?? []
        where removableIDs.contains(value.personID) {
            context.delete(value)
        }
        for value in (try? context.fetch(FetchDescriptor<AchievementUnlock>())) ?? []
        where removableIDs.contains(value.personID) {
            context.delete(value)
        }
        removable.forEach(context.delete)
        try? context.save()
    }

    @MainActor
    static func repairDuplicateGroups(context: ModelContext) {
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let matches = Dictionary(grouping: groups.compactMap { group in
            kind(of: group).map { ($0, group) }
        }, by: \.0)
        var removedGroupIDs = Set<UUID>()

        for (kind, pairs) in matches where pairs.count > 1 {
            let candidates = pairs.map(\.1)
            guard let keeper = candidates.min(by: { lhs, rhs in
                if lhs.id == kind.stableID { return true }
                if rhs.id == kind.stableID { return false }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }) else { continue }
            for group in candidates where group !== keeper {
                removedGroupIDs.insert(group.id)
                context.delete(group)
            }
        }

        guard !removedGroupIDs.isEmpty else { return }
        let activities = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        for item in activities where item.groupID.map(removedGroupIDs.contains) == true {
            context.delete(item)
        }
        try? context.save()
    }

    /// Earlier DEBUG builds generated a fresh copy of the complete four-person
    /// sample cast on each device. Repair only a full, equal-sized fixture batch
    /// anchored by all four stable seed IDs; a lone same-name contact is not
    /// enough evidence to delete or merge a real person.
    @MainActor
    static func repairDuplicatePeople(context: ModelContext) {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let canonicalByKind = Dictionary(uniqueKeysWithValues: PersonKind.allCases.compactMap {
            kind in people.first(where: { $0.id == kind.stableID }).map { (kind, $0) }
        })
        guard canonicalByKind.count == PersonKind.allCases.count else { return }

        let duplicateByKind = Dictionary(uniqueKeysWithValues: PersonKind.allCases.map { kind in
            let matches = people.filter {
                $0.id != kind.stableID && personKind(of: $0) == kind
            }
            return (kind, matches)
        })
        let counts = PersonKind.allCases.map { duplicateByKind[$0]?.count ?? 0 }
        guard let batchCount = counts.first,
              batchCount > 0,
              counts.allSatisfy({ $0 == batchCount }) else { return }

        for kind in PersonKind.allCases {
            guard let canonical = canonicalByKind[kind] else { continue }
            for duplicate in duplicateByKind[kind] ?? [] {
                ConnectedFriendIdentity.mergeLegacyFriend(
                    duplicate, into: canonical, context: context
                )
            }
        }
        try? context.save()
    }
}

enum LedgerIntegrity {
    /// Payments settle expense obligations; an empty group cannot carry a balance.
    /// This also repairs invalid settlements created by earlier test builds.
    @MainActor
    static func repairEmptyGroups(context: ModelContext) {
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let invalidSettlements = groups
            .filter { $0.expenses.isEmpty }
            .flatMap(\.settlements)
        guard !invalidSettlements.isEmpty else { return }

        let invalidIDs = Set(invalidSettlements.map(\.id))
        let activity = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        for group in groups where group.expenses.isEmpty {
            group.settlements.removeAll()
        }
        for settlement in invalidSettlements { context.delete(settlement) }
        for item in activity where item.refID.map(invalidIDs.contains) == true {
            context.delete(item)
        }
        try? context.save()
    }
}

enum ActivityData {
    static func unreadCount(in items: [ActivityItem], currentUserID: UUID,
                            lastRead: Date) -> Int {
        items.filter {
            guard let actorID = $0.actorID else { return false }
            return actorID != currentUserID && $0.timestamp > lastRead
        }.count
    }

    @MainActor
    static func enrichGroupContextIfNeeded(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? []
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let settlements = (try? context.fetch(FetchDescriptor<Settlement>())) ?? []
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let expensesByID = Dictionary(uniqueKeysWithValues: expenses.map { ($0.id, $0) })
        let settlementsByID = Dictionary(uniqueKeysWithValues: settlements.map { ($0.id, $0) })
        var changed = false

        for item in items where item.groupName == nil {
            let group: Group?
            switch item.kind {
            case .groupCreated:
                group = item.refID.flatMap { groupsByID[$0] }
            case .expenseAdded, .expenseEdited, .expenseDeleted:
                group = item.refID.flatMap { expensesByID[$0]?.group }
            case .settlementRecorded:
                group = item.refID.flatMap { settlementsByID[$0]?.group }
            case .memberAdded, .friendAdded:
                group = nil
            }
            guard let group else { continue }
            item.groupID = group.id
            item.groupName = group.name
            changed = true
        }
        if changed { try? context.save() }
    }
}

struct ActivitySection: Identifiable {
    enum Kind: Hashable {
        case date(Date)
        case earlier
    }

    let kind: Kind
    let items: [ActivityItem]

    var id: Kind { kind }
    var date: Date? {
        guard case .date(let date) = kind else { return nil }
        return date
    }
}

enum ActivitySectioning {
    static func sections(from items: [ActivityItem],
                         maximumDatedSections: Int = 5,
                         calendar: Calendar = .current) -> [ActivitySection] {
        let byDay = Dictionary(grouping: items) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let dated = byDay.keys.sorted(by: >).map { day in
            ActivitySection(
                kind: .date(day),
                items: (byDay[day] ?? []).sorted { $0.timestamp > $1.timestamp }
            )
        }
        let limit = max(0, maximumDatedSections)
        var result = Array(dated.prefix(limit))
        let earlierItems = dated.dropFirst(limit)
            .flatMap(\.items)
            .sorted { $0.timestamp > $1.timestamp }
        if !earlierItems.isEmpty {
            result.append(ActivitySection(kind: .earlier, items: earlierItems))
        }
        return result
    }
}

#if DEBUG
/// Seed = the mockup world. Dashboard must read: you're owed $160.50,
/// you owe $18.00 → net $142.50 (exactly like mockup B2).
enum SeedData {

    static func reset(context: ModelContext) {
        UserDefaults.standard.removeObject(forKey: "activityLastReadTimestamp")
        for value in (try? context.fetch(FetchDescriptor<ProcessedRewardEvent>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<AchievementUnlock>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<UserProgress>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<ActivityItem>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<Settlement>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<Split>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<Expense>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<Group>())) ?? [] { context.delete(value) }
        for value in (try? context.fetch(FetchDescriptor<Person>())) ?? [] { context.delete(value) }
        try? context.save()
    }

    static func seedIfEmpty(context: ModelContext) {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard people.isEmpty else { return }

        let you   = Person(id: UUID(uuidString: "B11B1000-0000-4000-8000-000000000001")!, name: "You", isCurrentUser: true, avatar: .sunglasses)
        let maya  = Person(id: UUID(uuidString: "B11B1000-0000-4000-8000-000000000002")!, name: "Maya Chen", avatar: .bows)
        let arjun = Person(id: UUID(uuidString: "B11B1000-0000-4000-8000-000000000003")!, name: "Arjun Rao", avatar: .bucketHat)
        let riya  = Person(id: UUID(uuidString: "B11B1000-0000-4000-8000-000000000004")!, name: "Riya Kapoor", avatar: .headphones)
        let sam   = Person(id: UUID(uuidString: "B11B1000-0000-4000-8000-000000000005")!, name: "Sam Ortiz", avatar: .messyTie)
        for p in [you, maya, arjun, riya, sam] { context.insert(p) }

        func log(_ kind: ActivityKind, _ summary: String, ref: UUID? = nil,
                 actor: Person? = nil, group: Group? = nil, when: Date = .now) {
            context.insert(ActivityItem(kind: kind, summary: summary, timestamp: when, refID: ref,
                                        actorID: actor?.id, groupID: group?.id,
                                        groupName: group?.name))
        }

        func expense(_ title: String, _ amount: Decimal, paidBy: Person, in group: Group,
                     splitAmong people: [Person], category: ExpenseCategory, daysAgo: Double) {
            let splits = people.map { Split(mode: .equal, person: $0) }
            let e = Expense(title: title, amount: amount,
                            date: Date().addingTimeInterval(-daysAgo * 86400),
                            category: category, group: group, paidBy: paidBy, splits: splits)
            for s in splits { s.expense = e; context.insert(s) }
            context.insert(e)
            let computed = (try? SplitEngine.compute(
                total: amount,
                inputs: people.map { SplitInput(personID: $0.id, mode: .equal) })) ?? [:]
            for s in splits {
                if let pid = s.person?.id, let amt = computed[pid] { s.computedAmount = amt }
            }
            log(.expenseAdded, "\(paidBy.name) added “\(title)”", ref: e.id,
                actor: paidBy, group: group,
                when: e.date)
        }

        // Apartment 4B — you're owed $84.00
        let apt = Group(id: DemoDataIntegrity.Kind.apartment.stableID,
                        name: "Apartment 4B", icon: .house,
                        createdAt: Date().addingTimeInterval(-40 * 86400), members: [you, maya])
        context.insert(apt)
        log(.groupCreated, "You created “Apartment 4B”", ref: apt.id,
            actor: you, group: apt, when: Date().addingTimeInterval(-40 * 86400))
        expense("Groceries", 54.20, paidBy: you, in: apt, splitAmong: [you, maya], category: .groceries, daysAgo: 6)
        expense("Internet bill", 113.80, paidBy: you, in: apt, splitAmong: [you, maya], category: .other, daysAgo: 12)

        // Friday Pizza — you're owed $76.50
        let pizza = Group(id: DemoDataIntegrity.Kind.pizza.stableID,
                          name: "Friday Pizza", icon: .pizza,
                          createdAt: Date().addingTimeInterval(-70 * 86400), members: [you, sam])
        context.insert(pizza)
        expense("Pizza night", 153.00, paidBy: you, in: pizza, splitAmong: [you, sam], category: .food, daysAgo: 9)

        // Goa Trip — you owe $18.00 after your settlement to Maya
        let goa = Group(id: DemoDataIntegrity.Kind.goa.stableID,
                        name: "Goa Trip", icon: .plane,
                        createdAt: Date().addingTimeInterval(-120 * 86400),
                        members: [you, maya, arjun, riya, sam])
        context.insert(goa)
        log(.groupCreated, "You created “Goa Trip”", ref: goa.id,
            actor: you, group: goa, when: Date().addingTimeInterval(-120 * 86400))
        expense("Taxi from airport", 120.00, paidBy: maya, in: goa, splitAmong: [you, maya, arjun, riya, sam], category: .transport, daysAgo: 30)
        expense("Beach shack lunch", 86.50, paidBy: you, in: goa, splitAmong: [you, maya, arjun, riya, sam], category: .food, daysAgo: 29)
        expense("Scooter rental (2d)", 140.00, paidBy: arjun, in: goa, splitAmong: [you, maya, arjun, riya], category: .transport, daysAgo: 28)
        expense("Hotel — 3 nights", 360.00, paidBy: you, in: goa, splitAmong: [you, maya, arjun, riya, sam], category: .lodging, daysAgo: 27)
        expense("Souvenirs", 24.00, paidBy: riya, in: goa, splitAmong: [you, maya, riya], category: .gift, daysAgo: 26)

        // Your Goa net is +290.20 before this; Maya's overpayment puts you at −$18.00,
        // so the group settle-up plan reads "you → Maya $18.00" (mockups B2/B3).
        let settlement = Settlement(amount: 308.20, date: Date().addingTimeInterval(-5 * 86400),
                                    from: maya, to: you, group: goa)
        context.insert(settlement)
        log(.settlementRecorded, "Maya paid you \(Money.currency(308.20))", ref: settlement.id,
            actor: maya, group: goa,
            when: settlement.date)

        try? context.save()
    }
}
#endif
