import SwiftUI
import SwiftData

/// Phase-2 CRUD screen (invoice-style group detail lands in Phase 3).
struct GroupsScreen: View {
    var onCreateGroup: () -> Void = {}
    var onGroupContextChange: (Group?) -> Void = { _ in }
    @Query(sort: \Group.createdAt) private var groups: [Group]
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var me: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var serverLedger = ServerLedgerSurfaceStore.shared
    @State private var path = NavigationPath()
    @State private var groupsPendingLocalDeletion: [Group] = []
    @State private var groupPendingSharedRemoval: Group?
    @State private var showSharedGroupRemovalConfirmation = false
    @State private var isRemovingSharedGroup = false
    @State private var showLocalGroupDeleteConfirmation = false
    @State private var showGroupDeleteError = false
    @State private var groupDeleteErrorMessage = ""

    private var visibleGroups: [Group] {
        groups.filter {
            $0.isVisible(toServerAccountID: serverLedger.activeAccountIdentifier)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Text("Groups")
                    .font(BrandFont.display(28, weight: .bold))
                    .foregroundStyle(Color.Brand.creamSoft)
                    .listRowBackground(Color.Brand.cobalt)
                    .listRowSeparator(.hidden)
                    .padding(.top, 4)
                if visibleGroups.isEmpty {
                    VStack(spacing: 10) {
                        MascotView(mascot: .neutral, size: 145)
                        Text(BrandFont.handText("no crews yet"))
                            .font(BrandFont.hand(24, weight: .bold))
                        Text("Start a group for a home, trip, or shared ritual.")
                            .font(BrandFont.body(12, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .opacity(0.7)
                        Button("Create a group", action: onCreateGroup)
                            .font(BrandFont.display(13, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Color.Brand.creamSoft, in: Capsule())
                    }
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                    .listRowBackground(Color.Brand.cobalt)
                    .listRowSeparator(.hidden)
                }
                ForEach(groupSections) { section in
                    Text(section.title)
                        .font(BrandFont.display(13, weight: .bold))
                        .foregroundStyle(Color.Brand.creamSoft.opacity(0.8))
                        .listRowBackground(Color.Brand.cobalt)
                        .listRowSeparator(.hidden)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.items) { group in
                        groupRow(group)
                    }
                    .onDelete { idx in
                        requestDelete(idx.map { section.items[$0] })
                    }
                }
            }
            .alert("Delete this group?", isPresented: $showSharedGroupRemovalConfirmation) {
                Button("Delete group", role: .destructive) {
                    Task { await removePendingSharedGroup() }
                }
                Button("Cancel", role: .cancel) { groupPendingSharedRemoval = nil }
            } message: {
                Text("Everyone must be settled first. The group leaves every member's list. Its history stays in Activity.")
            }
            .alert(
                groupsPendingLocalDeletion.count == 1 ? "Delete this group?" : "Delete these groups?",
                isPresented: $showLocalGroupDeleteConfirmation
            ) {
                Button(
                    groupsPendingLocalDeletion.count == 1 ? "Delete Group" : "Delete Groups",
                    role: .destructive
                ) {
                    deletePendingLocalGroups()
                }
                Button("Cancel", role: .cancel) {
                    groupsPendingLocalDeletion = []
                }
            } message: {
                Text(groupsPendingLocalDeletion.count == 1
                     ? "This permanently removes the group. This can't be undone."
                     : "This permanently removes the selected groups. This can't be undone.")
            }
            .listStyle(.plain)
            .animation(reduceMotion ? nil : BrandMotion.revealSpring, value: visibleGroups.map(\.id))
            .scrollContentBackground(.hidden)
            .background(Color.Brand.cobalt)
            .refreshable {
                await CloudCollaborationService.shared.synchronize(
                    promoteLocalChanges: true
                )
                await serverLedger.refresh(groups: visibleGroups)
            }
            .navigationTitle("Groups")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                if let group = visibleGroups.first(where: { $0.id == id }) {
                    GroupDetailScreen(group: group, onContextChange: onGroupContextChange)
                } else {
                    // The group was left, deleted, or removed by a sync while open.
                    Color.Brand.cobalt.ignoresSafeArea()
                        .onAppear { if !path.isEmpty { path.removeLast() } }
                }
            }
        }
        // Screenshot support: `-openGroup <name>` pushes straight into a group.
        .onAppear {
            onGroupContextChange(nil)
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-openGroup"), i + 1 < args.count else { return }
            let name = args[(i + 1)...].joined(separator: " ")
            if let g = visibleGroups.first(where: { $0.name == name }) { path.append(g.id) }
        }
        .onDisappear { onGroupContextChange(nil) }
        .task(id: visibleGroups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
            await serverLedger.refresh(groups: visibleGroups)
        }
        .alert("Group not deleted", isPresented: $showGroupDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(groupDeleteErrorMessage)
        }
    }

    private var groupSections: [RecencySection<Group>] {
        RecencySectioning.sections(
            GroupRecency.sorted(visibleGroups, snapshot: serverLedger.snapshot)
        ) { GroupRecency.lastActivity(of: $0, snapshot: serverLedger.snapshot) }
    }

    @ViewBuilder
    private func groupRow(_ group: Group) -> some View {
        NavigationLink(value: group.id) {
            HStack(spacing: 11) {
                Circle()
                    .fill(Color.Brand.creamSoft)
                    .frame(width: 36, height: 36)
                    .overlay(BrandIconView(icon: group.icon.icon, size: 17)
                        .foregroundStyle(Color.Brand.cobalt))
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(BrandFont.display(13.5))
                    Text(GroupCopy.memberCount(group.members.count))
                        .font(BrandFont.type(9.5))
                        .opacity(0.65)
                }
                .foregroundStyle(Color.Brand.creamSoft)
                Spacer()
                if group.serverLedgerGroupID != nil {
                    if let presentation = serverLedger.groupBalancePresentation(for: group) {
                        ServerLedgerBalanceChip(presentation: presentation)
                    } else {
                        ServerLedgerUnavailableChip(
                            isLoading: serverLedger.status.phase == .loading
                        )
                    }
                } else if let me = me.first {
                    NetChip(
                        net: BalanceMath.nets(in: group)[me.id] ?? 0,
                        currencyCode: group.resolvedCurrencyCode
                    )
                }
            }
        }
        .listRowBackground(Color.Brand.cobalt)
        .listRowSeparator(.hidden)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    /// A shared group has server-owned membership and history. A local model
    /// delete cannot stand in for a server delete or leave.
    private func requestDelete(_ selection: [Group]) {
        if selection.contains(where: { $0.serverLedgerGroupID != nil }) {
            guard selection.count == 1, let group = selection.first else {
                groupDeleteErrorMessage = "Delete one group at a time. No group was changed."
                showGroupDeleteError = true
                return
            }
            groupPendingSharedRemoval = group
            showSharedGroupRemovalConfirmation = true
            return
        }
        groupsPendingLocalDeletion = selection
        showLocalGroupDeleteConfirmation = !selection.isEmpty
    }

    private func removePendingSharedGroup() async {
        guard !isRemovingSharedGroup, let group = groupPendingSharedRemoval,
              let serverID = group.serverLedgerGroupID,
              let activeAccountID = serverLedger.activeAccountIdentifier,
              group.serverAccountId == activeAccountID else {
            groupDeleteErrorMessage = "This group is not available for your current account. No group was changed."
            showGroupDeleteError = true
            return
        }
        isRemovingSharedGroup = true
        defer { isRemovingSharedGroup = false; groupPendingSharedRemoval = nil }
        do {
            _ = try await SharedGroupMembershipService.perform(.delete, serverGroupID: serverID)
            await ServerSocialSyncService.shared.refresh()
            if visibleGroups.contains(where: { $0.id == group.id }) {
                groupDeleteErrorMessage = "The group was deleted, but this phone has not caught up yet. Pull down to refresh."
                showGroupDeleteError = true
            }
        } catch {
            groupDeleteErrorMessage = SharedGroupMembershipService.message(for: error, action: .delete)
            showGroupDeleteError = true
        }
    }

    private func deletePendingLocalGroups() {
        let groupsToDelete = groupsPendingLocalDeletion
        groupsPendingLocalDeletion = []
        guard !groupsToDelete.isEmpty else { return }
        guard groupsToDelete.allSatisfy({ $0.serverLedgerGroupID == nil }) else {
            groupDeleteErrorMessage = "This group is now shared. It cannot be deleted here. Your group is unchanged."
            showGroupDeleteError = true
            return
        }

        // Save existing edits first so rollback after a failed delete restores only this operation.
        do {
            try context.save()
        } catch {
            groupDeleteErrorMessage = "The group was kept. Save failed. Try again after you restart the app."
            showGroupDeleteError = true
            return
        }

        for group in groupsToDelete {
            CloudCollaborationService.shared.groupWasDeleted(group)
            context.delete(group)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            groupDeleteErrorMessage = "The group was kept. Save failed. Try again after you restart the app."
            showGroupDeleteError = true
        }
    }
}

enum SharedGroupMembershipAction {
    case delete
    case leave
}

/// Delete and leave for server groups. The server decides who may do what and
/// explains why in `message`; the app shows that text as is.
@MainActor
enum SharedGroupMembershipService {
    private struct Response: Decodable {
        let code: String
        let message: String?
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }

    /// Returns the server's confirmation text. Throws when the server refuses.
    /// Callers refresh the group list afterwards, once no screen shows the group.
    static func perform(_ action: SharedGroupMembershipAction, serverGroupID: String) async throws -> String {
        let encoded = serverGroupID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serverGroupID
        let response: Response
        switch action {
        case .delete:
            response = try await APIClient.live().delete("/api/mobile/groups/\(encoded)")
            guard response.code == "GROUP_ARCHIVED" else {
                throw SettlementAPIError.server(response.message ?? "The server did not confirm the delete.")
            }
        case .leave:
            response = try await APIClient.live().post(
                "/api/mobile/groups/\(encoded)/leave",
                body: SettlementEmptyBody(),
                idempotencyKey: UUID().uuidString
            )
            guard response.code == "GROUP_LEFT" else {
                throw SettlementAPIError.server(response.message ?? "The server did not confirm that you left.")
            }
        }
        return response.message ?? (action == .delete ? "Group deleted." : "You left the group.")
    }

    /// The reason to show the person. Prefers the server's own words.
    static func message(for error: Error, action: SharedGroupMembershipAction) -> String {
        let verb = action == .delete ? "delete this group" : "leave this group"
        switch error {
        case SettlementAPIError.structured(_, _, let body):
            if let body,
               let message = try? JSONDecoder().decode(ErrorBody.self, from: body).message,
               !message.isEmpty {
                return message
            }
            return "The server could not \(verb). Pull down to refresh and try again."
        case SettlementAPIError.server(let message):
            return message
        case SettlementAPIError.offline:
            return "You are offline. Connect to the internet to \(verb)."
        case SettlementAPIError.unauthorized:
            return "Sign in again to \(verb)."
        default:
            return "The server could not \(verb). Try again."
        }
    }
}

/// Orders groups by their latest activity, newest first.
enum GroupRecency {
    static func lastActivity(of group: Group, snapshot: ServerLedgerSurfaceSnapshot?) -> Date {
        // The server's dates win. A local copy's createdAt is when this phone
        // first saw the group, not when the group was made.
        if let serverGroupID = group.serverLedgerGroupID,
           let last = snapshot?.group(for: serverGroupID)?.activity.map(\.at).max() {
            return last
        }
        var latest = group.createdAt
        if let last = group.expenses.map(\.date).max() { latest = max(latest, last) }
        if let last = group.settlements.map(\.date).max() { latest = max(latest, last) }
        return latest
    }

    static func sorted(_ groups: [Group], snapshot: ServerLedgerSurfaceSnapshot?) -> [Group] {
        let keyed = groups.map { ($0, lastActivity(of: $0, snapshot: snapshot)) }
        return keyed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.createdAt > rhs.0.createdAt
        }
        .map(\.0)
    }
}

/// One dated block of a list: "Today", "Yesterday", "Monday", "Last week",
/// "Last month", then month names.
struct RecencySection<Item>: Identifiable {
    let title: String
    var items: [Item]
    var id: String { title }
}

enum RecencySectioning {
    static func title(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        case 7...13: return "Last week"
        case 14...30: return "Last month"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return sameYear
                ? date.formatted(.dateTime.month(.wide))
                : date.formatted(.dateTime.month(.wide).year())
        }
    }

    /// Splits items that are already sorted newest first into dated blocks,
    /// keeping their order.
    static func sections<Item>(
        _ items: [Item],
        now: Date = .now,
        date: (Item) -> Date
    ) -> [RecencySection<Item>] {
        var result = [RecencySection<Item>]()
        for item in items {
            let title = title(for: date(item), now: now)
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append(RecencySection(title: title, items: [item]))
            }
        }
        return result
    }
}
