import Foundation
import SwiftData

// MARK: - Enums (stored as raw strings for SwiftData stability)

enum ProfileAvatar: String, Codable, CaseIterable, Identifiable {
    case sunglasses
    case bucketHat = "bucket-hat"
    case bows
    case messyTie = "messy-tie"
    case headphones
    case bandana
    case beanie
    case flower

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sunglasses: return "Sunglasses"
        case .bucketHat: return "Bucket hat"
        case .bows: return "Bows"
        case .messyTie: return "Messy tie"
        case .headphones: return "Headphones"
        case .bandana: return "Bandana"
        case .beanie: return "Beanie"
        case .flower: return "Flower"
        }
    }

    static func defaultAvatar(for name: String, isCurrentUser: Bool) -> ProfileAvatar {
        if isCurrentUser { return .sunglasses }
        switch name.lowercased() {
        case let value where value.contains("maya"): return .bows
        case let value where value.contains("arjun"): return .bucketHat
        case let value where value.contains("riya"): return .headphones
        case let value where value.contains("sam"): return .messyTie
        default:
            let index = name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % allCases.count
            return allCases[index]
        }
    }
}

enum SplitMode: String, Codable, CaseIterable {
    case equal, exact, percent, shares

    var label: String {
        switch self {
        case .equal: return "equally"
        case .exact: return "exact"
        case .percent: return "%"
        case .shares: return "shares"
        }
    }
}

enum ExpenseCategory: String, Codable, CaseIterable {
    case food, coffee, transport, groceries, gift, lodging, travel, other

    var icon: BrandIcon {
        switch self {
        case .food: return .pizza
        case .coffee: return .coffee
        case .transport: return .car
        case .groceries: return .cart
        case .gift: return .gift
        case .lodging: return .house
        case .travel: return .plane
        case .other: return .receipti
        }
    }
}

enum GroupIcon: String, Codable, CaseIterable {
    case house, plane, pizza, cart, gift, car, coffee, users

    var icon: BrandIcon {
        switch self {
        case .house: return .house
        case .plane: return .plane
        case .pizza: return .pizza
        case .cart: return .cart
        case .gift: return .gift
        case .car: return .car
        case .coffee: return .coffee
        case .users: return .users
        }
    }
}

enum ActivityKind: String, Codable {
    case expenseAdded, expenseEdited, expenseDeleted
    case settlementRecorded, memberAdded, groupCreated, friendAdded
}

enum RewardAction: String, Codable, CaseIterable {
    case expenseAdded
    case groupCreated
    case settlementRecorded

    var xp: Int {
        switch self {
        case .expenseAdded: return 5
        case .groupCreated: return 8
        case .settlementRecorded: return 10
        }
    }

    var starterAchievement: StarterAchievement {
        switch self {
        case .expenseAdded: return .initiativeTaker
        case .groupCreated: return .crewFounder
        case .settlementRecorded: return .settlerScion
        }
    }
}

enum ProgressLevel: Int, Codable, CaseIterable, Identifiable {
    case lookout = 1
    case crewScout = 2
    case ledgerKeeper = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .lookout: return "Lookout"
        case .crewScout: return "Crew Scout"
        case .ledgerKeeper: return "Ledger Keeper"
        }
    }

    var minimumXP: Int {
        switch self {
        case .lookout: return 0
        case .crewScout: return 50
        case .ledgerKeeper: return 150
        }
    }

    var nextThreshold: Int? {
        switch self {
        case .lookout: return ProgressLevel.crewScout.minimumXP
        case .crewScout: return ProgressLevel.ledgerKeeper.minimumXP
        case .ledgerKeeper: return nil
        }
    }

    static func level(for xp: Int) -> ProgressLevel {
        if xp >= ProgressLevel.ledgerKeeper.minimumXP { return .ledgerKeeper }
        if xp >= ProgressLevel.crewScout.minimumXP { return .crewScout }
        return .lookout
    }
}

enum StarterAchievement: String, Codable, CaseIterable, Identifiable {
    case initiativeTaker
    case settlerScion
    case highOnDetails
    case crewFounder
    case splitPersonality
    case peacekeeper
    case bigSpender
    case partnerInCrime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .initiativeTaker: return "Initiative Taker"
        case .settlerScion: return "Settler Scion"
        case .highOnDetails: return "High on Details"
        case .crewFounder: return "Crew Founder"
        case .splitPersonality: return "Split Personality"
        case .peacekeeper: return "Peacekeeper"
        case .bigSpender: return "Big Spender"
        case .partnerInCrime: return "Partner in Crime"
        }
    }

    var requirement: String {
        switch self {
        case .initiativeTaker: return "Add your first expense"
        case .settlerScion: return "Record your first payment"
        case .highOnDetails: return "Edit your first expense"
        case .crewFounder: return "Create your first group"
        case .splitPersonality: return "Use 3 of 4 split methods"
        case .peacekeeper: return "Record 5 settlements"
        case .bigSpender: return "Pay the most in a group"
        case .partnerInCrime: return "Add your first friend"
        }
    }

    var assetName: String {
        switch self {
        case .initiativeTaker: return "achievement-initiative-taker"
        case .settlerScion: return "achievement-settler-scion"
        case .highOnDetails: return "achievement-high-on-details"
        case .crewFounder: return "achievement-crew-founder"
        case .splitPersonality: return "achievement-split-personality"
        case .peacekeeper: return "achievement-peacekeeper"
        case .bigSpender: return "achievement-big-spender"
        case .partnerInCrime: return "achievement-partner-in-crime"
        }
    }
}

// MARK: - Models

@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var name: String
    var isCurrentUser: Bool
    /// Optional so existing SwiftData stores migrate without rewriting people.
    var avatarRaw: String?
    /// CloudKit's user-record name links the same person across invited devices.
    /// It stays optional so local-only profiles and existing stores remain valid.
    var cloudUserRecordName: String?
    @Relationship(inverse: \Group.members) var groups: [Group]

    init(id: UUID = UUID(), name: String, isCurrentUser: Bool = false,
         avatar: ProfileAvatar? = nil) {
        self.id = id
        self.name = name
        self.isCurrentUser = isCurrentUser
        self.avatarRaw = avatar?.rawValue
        self.cloudUserRecordName = nil
        self.groups = []
    }

    var profileAvatar: ProfileAvatar {
        get {
            avatarRaw.flatMap(ProfileAvatar.init(rawValue:)) ??
                ProfileAvatar.defaultAvatar(for: name, isCurrentUser: isCurrentUser)
        }
        set { avatarRaw = newValue.rawValue }
    }
}

@Model
final class Group {
    @Attribute(.unique) var id: UUID
    var name: String
    var iconRaw: String
    var simplifyDebts: Bool
    var createdAt: Date
    /// Optional collaboration metadata. A nil zone means the group is still
    /// local-only and will be promoted when iCloud becomes available.
    var cloudZoneName: String?
    var cloudZoneOwnerName: String?
    var cloudDatabaseScopeRaw: String?
    var members: [Person]
    @Relationship(deleteRule: .cascade, inverse: \Expense.group) var expenses: [Expense]
    @Relationship(deleteRule: .cascade, inverse: \Settlement.group) var settlements: [Settlement]

    init(id: UUID = UUID(), name: String, icon: GroupIcon = .users, simplifyDebts: Bool = true,
         createdAt: Date = .now, members: [Person] = []) {
        self.id = id
        self.name = name
        self.iconRaw = icon.rawValue
        self.simplifyDebts = simplifyDebts
        self.createdAt = createdAt
        self.cloudZoneName = nil
        self.cloudZoneOwnerName = nil
        self.cloudDatabaseScopeRaw = nil
        self.members = members
        self.expenses = []
        self.settlements = []
    }

    var icon: GroupIcon { GroupIcon(rawValue: iconRaw) ?? .users }
}

@Model
final class Expense {
    @Attribute(.unique) var id: UUID
    var title: String
    var amount: Decimal
    var date: Date
    var categoryRaw: String
    var notes: String
    var group: Group?
    var paidBy: Person?
    @Relationship(deleteRule: .cascade, inverse: \Split.expense) var splits: [Split]

    init(id: UUID = UUID(), title: String, amount: Decimal, date: Date = .now,
         category: ExpenseCategory = .other, notes: String = "",
         group: Group? = nil, paidBy: Person? = nil, splits: [Split] = []) {
        self.id = id
        self.title = title
        self.amount = amount
        self.date = date
        self.categoryRaw = category.rawValue
        self.notes = notes
        self.group = group
        self.paidBy = paidBy
        self.splits = splits
    }

    var category: ExpenseCategory { ExpenseCategory(rawValue: categoryRaw) ?? .other }
}

@Model
final class Split {
    var modeRaw: String
    /// Input value: exact amount / percent / share count (ignored for `.equal`).
    var value: Decimal
    /// Engine-computed share of the expense. Sum of all splits == expense amount.
    var computedAmount: Decimal
    var person: Person?
    var expense: Expense?

    init(mode: SplitMode = .equal, value: Decimal = 0, computedAmount: Decimal = 0,
         person: Person? = nil, expense: Expense? = nil) {
        self.modeRaw = mode.rawValue
        self.value = value
        self.computedAmount = computedAmount
        self.person = person
        self.expense = expense
    }

    var mode: SplitMode { SplitMode(rawValue: modeRaw) ?? .equal }
}

@Model
final class Settlement {
    @Attribute(.unique) var id: UUID
    var amount: Decimal
    var date: Date
    var from: Person?
    var to: Person?
    var group: Group?

    init(id: UUID = UUID(), amount: Decimal, date: Date = .now,
         from: Person? = nil, to: Person? = nil, group: Group? = nil) {
        self.id = id
        self.amount = amount
        self.date = date
        self.from = from
        self.to = to
        self.group = group
    }
}

@Model
final class ActivityItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var summary: String
    var timestamp: Date
    var refID: UUID?
    var actorID: UUID?
    var groupID: UUID?
    var groupName: String?

    init(id: UUID = UUID(), kind: ActivityKind, summary: String,
         timestamp: Date = .now, refID: UUID? = nil,
         actorID: UUID? = nil, groupID: UUID? = nil, groupName: String? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.summary = summary
        self.timestamp = timestamp
        self.refID = refID
        self.actorID = actorID
        self.groupID = groupID
        self.groupName = groupName
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .expenseAdded }

    var displaySummary: String {
        guard let groupName, !groupName.isEmpty else { return summary }
        switch kind {
        case .expenseAdded, .expenseEdited, .expenseDeleted, .settlementRecorded, .memberAdded:
            return "\(summary) in \(groupName)"
        case .groupCreated, .friendAdded:
            return summary
        }
    }
}

@Model
final class UserProgress {
    @Attribute(.unique) var personID: UUID
    var lifetimeXP: Int
    var isEnabled: Bool

    init(personID: UUID, lifetimeXP: Int = 0, isEnabled: Bool = true) {
        self.personID = personID
        self.lifetimeXP = lifetimeXP
        self.isEnabled = isEnabled
    }

    var level: ProgressLevel { ProgressLevel.level(for: lifetimeXP) }
}

@Model
final class ProcessedRewardEvent {
    @Attribute(.unique) var key: String
    var eventID: UUID
    var personID: UUID
    var actionRaw: String
    var awardedXP: Int
    var processedAt: Date

    init(eventID: UUID, personID: UUID, action: RewardAction,
         awardedXP: Int, processedAt: Date = .now) {
        self.key = "\(personID.uuidString):\(action.rawValue):\(eventID.uuidString)"
        self.eventID = eventID
        self.personID = personID
        self.actionRaw = action.rawValue
        self.awardedXP = awardedXP
        self.processedAt = processedAt
    }

    var action: RewardAction { RewardAction(rawValue: actionRaw) ?? .expenseAdded }
}

@Model
final class AchievementUnlock {
    @Attribute(.unique) var key: String
    var achievementRaw: String
    var personID: UUID
    var unlockedAt: Date

    init(achievement: StarterAchievement, personID: UUID, unlockedAt: Date = .now) {
        self.key = "\(personID.uuidString):\(achievement.rawValue)"
        self.achievementRaw = achievement.rawValue
        self.personID = personID
        self.unlockedAt = unlockedAt
    }

    var achievement: StarterAchievement {
        StarterAchievement(rawValue: achievementRaw) ?? .initiativeTaker
    }
}
