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
    ])

    static let container: ModelContainer = {
        do {
            // iCloud capability is used by CloudCollaborationService's shared
            // record zones. Keep SwiftData explicitly local so it doesn't infer
            // private-store mirroring from the entitlement and reject this
            // existing local-first schema.
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

    /// DEBUG seeds run on the main actor, once, at app start (see RootTabView).
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        guard !didPrepareStore else { return }
        didPrepareStore = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetDemoData") {
            SeedData.reset(context: context)
        }
        SeedData.seedIfEmpty(context: context)
        #endif
        LedgerIntegrity.repairEmptyGroups(context: context)
        ActivityData.enrichGroupContextIfNeeded(context: context)
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

        let you   = Person(name: "You", isCurrentUser: true, avatar: .sunglasses)
        let maya  = Person(name: "Maya Chen", avatar: .bows)
        let arjun = Person(name: "Arjun Rao", avatar: .bucketHat)
        let riya  = Person(name: "Riya Kapoor", avatar: .headphones)
        let sam   = Person(name: "Sam Ortiz", avatar: .messyTie)
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
        let apt = Group(name: "Apartment 4B", icon: .house,
                        createdAt: Date().addingTimeInterval(-40 * 86400), members: [you, maya])
        context.insert(apt)
        log(.groupCreated, "You created “Apartment 4B”", ref: apt.id,
            actor: you, group: apt, when: Date().addingTimeInterval(-40 * 86400))
        expense("Groceries", 54.20, paidBy: you, in: apt, splitAmong: [you, maya], category: .groceries, daysAgo: 6)
        expense("Internet bill", 113.80, paidBy: you, in: apt, splitAmong: [you, maya], category: .other, daysAgo: 12)

        // Friday Pizza — you're owed $76.50
        let pizza = Group(name: "Friday Pizza", icon: .pizza,
                          createdAt: Date().addingTimeInterval(-70 * 86400), members: [you, sam])
        context.insert(pizza)
        expense("Pizza night", 153.00, paidBy: you, in: pizza, splitAmong: [you, sam], category: .food, daysAgo: 9)

        // Goa Trip — you owe $18.00 after your settlement to Maya
        let goa = Group(name: "Goa Trip", icon: .plane,
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
