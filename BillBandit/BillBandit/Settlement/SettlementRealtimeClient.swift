import Foundation

struct SettlementRealtimeEvent: Equatable {
    let eventType: String
    let groupId: String
    let recordId: String
    let version: Int
}

enum SettlementRealtimeConstants {
    static let invalidationEvent = "settlement-invalidation"

    static func privateChannelName(groupId: String) -> String {
        "private-group-\(groupId)-settle-up"
    }
}

enum SettlementRealtimeConfig {
    static var pusherKey: String? {
        configuredValue(forInfoKey: "PUSHER_KEY")
    }

    static var pusherCluster: String? {
        configuredValue(forInfoKey: "PUSHER_CLUSTER")
    }

    static var isPusherConfigured: Bool {
        pusherKey != nil && pusherCluster != nil
    }

    private static func configuredValue(forInfoKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

@MainActor
protocol SettlementRealtimeClient: AnyObject {
    var onVersion: ((SettlementRealtimeEvent) -> Void)? { get set }
    func subscribe(groupId: String, apiClient: APIClient) async
    func unsubscribe() async
}

@MainActor
func makeDefaultSettlementRealtimeClient() -> SettlementRealtimeClient {
    if SettlementRealtimeConfig.isPusherConfigured {
        return SettlementPusherRealtimeClient()
    }
    return SettlementPollingRealtimeClient()
}

/// Polling-only adapter used when Pusher is unavailable or not yet configured (Ticket 09).
/// Subscribes to nothing; SettlementStore handles ten-second REST polling instead.
@MainActor
final class SettlementPollingRealtimeClient: SettlementRealtimeClient {
    var onVersion: ((SettlementRealtimeEvent) -> Void)?

    func subscribe(groupId: String, apiClient: APIClient) async {}

    func unsubscribe() async {
        onVersion = nil
    }
}

/// Test double that emits version events without network I/O.
@MainActor
final class FakeSettlementRealtimeClient: SettlementRealtimeClient {
    var onVersion: ((SettlementRealtimeEvent) -> Void)?
    private(set) var subscribedGroupId: String?

    func subscribe(groupId: String, apiClient: APIClient) async {
        subscribedGroupId = groupId
    }

    func unsubscribe() async {
        subscribedGroupId = nil
        onVersion = nil
    }

    func emit(_ event: SettlementRealtimeEvent) {
        onVersion?(event)
    }
}
