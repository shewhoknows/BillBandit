import Foundation

struct MobileUser: Codable, Hashable, Sendable {
    var id: String
    var name: String?
    var email: String?
    var image: String?
    var phone: String?
    var preferredName: String?
    var upiID: String?
    var isProfileComplete: Bool?
}

struct MobileMember: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case admin = "ADMIN"
        case member = "MEMBER"
    }

    var userId: String
    var role: Role
    var joinedAt: Date?
    var user: MobileUser
}

struct MobileExpense: Codable, Hashable, Sendable {
    enum SplitType: String, Codable, Sendable {
        case equal = "EQUAL"
        case exact = "EXACT"
        case percentage = "PERCENTAGE"
        case shares = "SHARES"
    }

    struct GroupSummary: Codable, Hashable, Sendable {
        var id: String
        var name: String
    }

    struct Split: Codable, Hashable, Sendable {
        var userId: String
        var amount: Double
        var percentage: Double?
        var shares: Int?
        var user: MobileUser?
    }

    var id: String
    var description: String
    var amount: Double
    var currency: String
    var date: Date
    var category: String
    var groupId: String?
    var group: GroupSummary?
    var paidById: String
    var paidBy: MobileUser?
    var splitType: SplitType
    var notes: String?
    var splits: [Split]
    var createdAt: Date?
    var updatedAt: Date?
}

struct MobileGroup: Codable, Hashable, Sendable {
    enum Category: String, Codable, Sendable {
        case home = "HOME"
        case trip = "TRIP"
        case couple = "COUPLE"
        case work = "WORK"
        case other = "OTHER"
    }

    enum Status: String, Codable, Sendable {
        case active = "ACTIVE"
        case finalized = "FINALIZED"
    }

    var id: String
    var name: String
    var description: String?
    var image: String?
    var currency: String
    var category: Category
    var status: Status
    var finalizedAt: Date?
    var finalizedById: String?
    var memberCount: Int
    var expenseCount: Int
    var members: [MobileMember]
    var expenses: [MobileExpense]?
    var createdAt: Date?
    var updatedAt: Date?
}

struct MobileGroupBalances: Codable, Hashable, Sendable {
    struct NetBalance: Codable, Hashable, Sendable {
        var userId: String
        var name: String?
        var image: String?
        var netAmount: Double
    }

    struct SimplifiedDebt: Codable, Hashable, Sendable {
        var fromId: String
        var toId: String
        var amount: Double
        var fromName: String?
        var toName: String?
    }

    var netBalances: [NetBalance]
    var simplifiedDebts: [SimplifiedDebt]
}

struct MobileTransaction: Codable, Hashable, Sendable {
    struct RawUser: Codable, Hashable, Sendable {
        var id: String
        var name: String?
        var image: String?
        var email: String
    }

    var id: String
    var amount: Double
    var currency: String
    var note: String?
    var group: MobileExpense.GroupSummary?
    var sender: RawUser
    var receiver: RawUser
    var createdAt: Date
}

struct AuthEnvelope: Codable, Sendable {
    var token: String
    var user: MobileUser
}

struct RegisterEnvelope: Codable, Sendable {
    var token: String
    var user: MobileUser
    var message: String
}

struct UserEnvelope: Codable, Sendable {
    var user: MobileUser
}

struct OTPStartEnvelope: Codable, Hashable, Sendable {
    enum DeliveryChannel: String, Codable, Sendable {
        case email
        case phone
    }

    var challengeId: String
    var maskedIdentifier: String
    var deliveryChannel: DeliveryChannel
    var expiresInSeconds: Int
    var message: String
}

struct GroupsEnvelope: Codable, Sendable {
    var groups: [MobileGroup]
}

struct GroupEnvelope: Codable, Sendable {
    var group: MobileGroup
    var balances: MobileGroupBalances
}

struct ExpenseEnvelope: Codable, Sendable {
    var expense: MobileExpense
}

struct ExpensesEnvelope: Codable, Sendable {
    var expenses: [MobileExpense]
}

struct MemberEnvelope: Codable, Sendable {
    var member: MobileMember
}

struct TransactionEnvelope: Codable, Sendable {
    var transaction: MobileTransaction
}

struct DeleteEnvelope: Codable, Sendable {
    var success: Bool
}

struct AppleSignInRequest: Encodable, Sendable {
    var identityToken: String
    var nonce: String?
    var fullName: String?
    var email: String?
}

struct EmailLoginRequest: Encodable, Sendable {
    var email: String
    var password: String
}

struct RegisterRequest: Encodable, Sendable {
    var name: String
    var email: String
    var password: String
}

struct OTPStartRequest: Encodable, Sendable {
    var identifier: String
}

struct OTPVerifyRequest: Encodable, Sendable {
    var challengeId: String
    var code: String
}

struct UpdateProfileRequest: Encodable, Sendable {
    var name: String?
    var preferredName: String?
    var upiID: String?
}

struct CreateGroupRequest: Encodable, Sendable {
    var name: String
    var description: String?
    var currency: String
    var category: MobileGroup.Category
}

struct AddMemberRequest: Encodable, Sendable {
    var email: String
}

struct UpsertExpenseRequest: Encodable, Sendable {
    struct Split: Encodable, Sendable {
        var userId: String
        var amount: Double
        var percentage: Double?
        var shares: Int?
    }

    var description: String
    var amount: Double
    var currency: String
    var date: Date
    var category: String
    var groupId: String?
    var paidById: String
    var splitType: MobileExpense.SplitType
    var splits: [Split]
    var notes: String?
}

struct CreateTransactionRequest: Encodable, Sendable {
    var receiverId: String?
    var senderId: String?
    var amount: Double
    var currency: String
    var groupId: String?
    var note: String?
}

