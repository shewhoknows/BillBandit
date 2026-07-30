import Foundation
import PusherSwift

private struct SettlementRealtimeEventPayload: Decodable {
    let eventType: String
    let groupId: String
    let recordId: String
    let version: Int
}

private final class SettlementPusherAuthRequestBuilder: AuthRequestBuilderProtocol {
    private let authURL: URL
    private let tokenProvider: @Sendable () -> String?

    init(authURL: URL, tokenProvider: @escaping @Sendable () -> String?) {
        self.authURL = authURL
        self.tokenProvider = tokenProvider
    }

    func requestFor(socketID: String, channelName: String) -> URLRequest? {
        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: String] = [
            "socket_id": socketID,
            "channel_name": channelName,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Live Pusher adapter for private settlement invalidation events.
@MainActor
final class SettlementPusherRealtimeClient: NSObject, SettlementRealtimeClient {
    var onVersion: ((SettlementRealtimeEvent) -> Void)?

    private var pusher: Pusher?
    private var subscribedChannel: PusherChannel?
    private var subscribedGroupId: String?

    func subscribe(groupId: String, apiClient: APIClient) async {
        guard SettlementRealtimeConfig.isPusherConfigured,
              let key = SettlementRealtimeConfig.pusherKey,
              let cluster = SettlementRealtimeConfig.pusherCluster else {
            return
        }

        if subscribedGroupId == groupId, pusher != nil {
            return
        }

        await unsubscribe()

        guard let authURL = URL(
            string: "/api/groups/\(groupId)/realtime/auth",
            relativeTo: apiClient.baseURL
        ) else {
            return
        }

        let authBuilder = SettlementPusherAuthRequestBuilder(
            authURL: authURL,
            tokenProvider: { apiClient.authorizationToken() }
        )
        let options = PusherClientOptions(
            authMethod: .authRequestBuilder(authRequestBuilder: authBuilder),
            host: .cluster(cluster)
        )
        let client = Pusher(key: key, options: options)
        client.delegate = self
        client.connect()

        let channelName = SettlementRealtimeConstants.privateChannelName(groupId: groupId)
        let channel = client.subscribe(channelName)
        channel.bind(eventName: SettlementRealtimeConstants.invalidationEvent) { [weak self] (event: PusherEvent) in
            guard let payload = Self.decodeEvent(event) else { return }
            Task { @MainActor in
                self?.onVersion?(
                    SettlementRealtimeEvent(
                        eventType: payload.eventType,
                        groupId: payload.groupId,
                        recordId: payload.recordId,
                        version: payload.version
                    )
                )
            }
        }

        pusher = client
        subscribedChannel = channel
        subscribedGroupId = groupId
        SettlementAPILog.api("event=settlement.realtime.subscribe transport=pusher group=\(SettlementAPILog.redactedID(groupId))")
    }

    func unsubscribe() async {
        subscribedChannel?.unbindAll()
        subscribedChannel = nil
        if let pusher {
            pusher.unsubscribeAll()
            pusher.disconnect()
        }
        pusher = nil
        subscribedGroupId = nil
    }

    private static func decodeEvent(_ event: PusherEvent) -> SettlementRealtimeEventPayload? {
        guard let data = event.data?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SettlementRealtimeEventPayload.self, from: data)
    }
}

extension SettlementPusherRealtimeClient: PusherDelegate {
    nonisolated func changedConnectionState(from old: ConnectionState, to new: ConnectionState) {
        SettlementAPILog.api("event=settlement.realtime.connection from=\(String(describing: old)) to=\(String(describing: new))")
    }

    nonisolated func debugLog(message: String) {
        #if DEBUG
        SettlementAPILog.api("event=settlement.realtime.debug message=\(message)")
        #endif
    }
}
