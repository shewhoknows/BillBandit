import SwiftUI

@MainActor
@Observable
final class FriendsViewModel {
    let container: DataContainer
    var trips: [Trip] = []
    var isLoading = false
    var errorMessage: String?

    init(container: DataContainer) {
        self.container = container
    }

    var uniqueParticipants: [TripParticipant] {
        var seen = Set<ParticipantID>()
        return trips
            .flatMap(\.participants)
            .filter { participant in
                guard !seen.contains(participant.id) else { return false }
                seen.insert(participant.id)
                return participant.kind != .currentUser
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            trips = try await container.tripRepository.list()
        } catch {
            errorMessage = error.billBanditMessage
        }
    }
}

struct FriendsView: View {
    @State var model: FriendsViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.trips.isEmpty {
                    LoadingReceiptView(title: "Reading crew list...")
                } else {
                    ReceiptScroll {
                        ReceiptCard(
                            eyebrow: "Crew",
                            title: "People from your trips",
                            subtitle: model.container.capabilities.friendsList
                                ? "Backed by the native friends endpoint."
                                : "Derived from group membership because the backend has no native friends list yet."
                        ) {
                            VStack(spacing: BBSpacing.sm) {
                                if model.uniqueParticipants.isEmpty {
                                    EmptyState(
                                        mascot: .thinking,
                                        title: "No crew yet",
                                        message: "Add members to a trip and they will appear here."
                                    )
                                } else {
                                    ForEach(Array(model.uniqueParticipants.enumerated()), id: \.element.id) { index, participant in
                                        FriendRow(
                                            name: participant.displayName,
                                            subtitle: participantSubtitle(participant),
                                            initials: participant.initials,
                                            avatarColor: BBColor.avatarPalette[index % BBColor.avatarPalette.count],
                                            badge: AnyView(badge(for: participant))
                                        )
                                    }
                                }
                            }
                        }

                        InlineErrorText(message: model.errorMessage)
                    }
                    .refreshable {
                        await model.load()
                    }
                }
            }
            .navigationTitle("Friends")
            .task {
                await model.load()
            }
        }
    }

    private func participantSubtitle(_ participant: TripParticipant) -> String {
        switch participant.kind {
        case .currentUser:
            "You"
        case .friend:
            "Trip member"
        case .invited(let email):
            email ?? "Invited by email"
        case .guest:
            "Guest"
        }
    }

    @ViewBuilder
    private func badge(for participant: TripParticipant) -> some View {
        switch participant.kind {
        case .invited:
            InvitedBadge()
        case .guest:
            GuestBadge()
        default:
            EmptyView()
        }
    }
}

