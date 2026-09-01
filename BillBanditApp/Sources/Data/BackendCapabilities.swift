import Foundation

struct BackendCapabilities: Hashable, Sendable {
    let friendCodes: Bool
    let inviteLinks: Bool
    let reopenTrip: Bool
    let memberRemoval: Bool
    let friendsList: Bool
    let phoneOTP: Bool
    let groupEdit: Bool
    let groupDelete: Bool
    let settlementList: Bool
    let avatarUpload: Bool

    static let current = BackendCapabilities(
        friendCodes: false,
        inviteLinks: false,
        reopenTrip: false,
        memberRemoval: false,
        friendsList: false,
        phoneOTP: false,
        groupEdit: false,
        groupDelete: false,
        settlementList: false,
        avatarUpload: false
    )
}

