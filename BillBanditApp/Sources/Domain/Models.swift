import Foundation

typealias ParticipantID = String

struct UserProfile: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String?
    var email: String?
    var imageURL: URL?
    var phone: String?
    var preferredName: String?
    var upiID: String?
    var isProfileComplete: Bool
}

struct Friend: Identifiable, Hashable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case accepted
        case rejected
    }

    var id: String
    var user: UserProfile
    var status: Status
}

struct FriendCode: Hashable, Codable, Sendable {
    var value: InviteCode
}

struct TripParticipant: Identifiable, Hashable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case admin
        case member
    }

    enum Kind: Hashable, Codable, Sendable {
        case currentUser
        case friend(friendId: String)
        case invited(email: String?)
        case guest
    }

    var id: ParticipantID
    var displayName: String
    var kind: Kind
    var role: Role

    init(id: ParticipantID, displayName: String, kind: Kind, role: Role = .member) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.role = role
    }
}

struct Trip: Identifiable, Hashable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case active
        case finalized
    }

    var id: String
    var name: String
    var destination: String?
    var startDate: Date?
    var endDate: Date?
    var currency: Currency
    var participants: [TripParticipant]
    var status: Status
}

enum SplitMethod: Hashable, Codable, Sendable {
    case equal
    case exactAmounts([ParticipantID: Money])
    case percentages([ParticipantID: Decimal])
    case shares([ParticipantID: Int])
    case payerOnly
}

struct Expense: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var amount: Money
    var paidBy: ParticipantID
    var date: Date
    var category: String
    var notes: String?
    var includedParticipants: [ParticipantID]
    var splitMethod: SplitMethod

    init(
        id: String,
        title: String,
        amount: Money,
        paidBy: ParticipantID,
        date: Date = Date(),
        category: String = "general",
        notes: String? = nil,
        includedParticipants: [ParticipantID],
        splitMethod: SplitMethod
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.paidBy = paidBy
        self.date = date
        self.category = category
        self.notes = notes
        self.includedParticipants = includedParticipants
        self.splitMethod = splitMethod
    }
}

struct ExpenseSplit: Hashable, Codable, Sendable {
    var participantId: ParticipantID
    var amount: Money
}

struct Settlement: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var from: ParticipantID
    var to: ParticipantID
    var amount: Money
    var date: Date
    var note: String?

    init(id: String, from: ParticipantID, to: ParticipantID, amount: Money, date: Date = Date(), note: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.amount = amount
        self.date = date
        self.note = note
    }
}

struct ParticipantBalance: Hashable, Codable, Sendable {
    var participantId: ParticipantID
    var paid: Money
    var owed: Money
    var net: Money
}

struct SettlementInstruction: Hashable, Codable, Sendable {
    var from: ParticipantID
    var to: ParticipantID
    var amount: Money
}

struct SettlementSummary: Hashable, Codable, Sendable {
    var balances: [ParticipantBalance]
    var simplifiedInstructions: [SettlementInstruction]
}

struct InviteLink: Hashable, Codable, Sendable {
    var url: URL
    var code: InviteCode
}
