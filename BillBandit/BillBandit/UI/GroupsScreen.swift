import SwiftUI
import SwiftData

/// Phase-2 CRUD screen (invoice-style group detail lands in Phase 3).
struct GroupsScreen: View {
    @Query(sort: \Group.createdAt) private var groups: [Group]
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var me: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var serverLedger = ServerLedgerSurfaceStore.shared
    @State private var showAdd = false
    @State private var path = NavigationPath()
    @State private var groupsPendingLocalDeletion: [Group] = []
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
                if visibleGroups.isEmpty {
                    VStack(spacing: 10) {
                        MascotView(mascot: .neutral, size: 145)
                        Text(BrandFont.handText("no crews yet"))
                            .font(BrandFont.hand(24, weight: .bold))
                        Text("Start a group for a home, trip, or shared ritual.")
                            .font(BrandFont.body(12, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .opacity(0.7)
                        Button("Create a group") { showAdd = true }
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
                ForEach(visibleGroups) { group in
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
                                if let serverGroupID = group.serverLedgerGroupID {
                                    // Source tag intentionally omitted for shared groups.
                                } else {
                                    Text(ServerLedgerUserFacingCopy.onDevice)
                                        .font(BrandFont.type(8.5, bold: true))
                                        .opacity(0.58)
                                }
                            }
                            .foregroundStyle(Color.Brand.creamSoft)
                            Spacer()
                            if let serverGroupID = group.serverLedgerGroupID {
                                if let presentation = serverLedger.groupBalancePresentation(for: serverGroupID) {
                                    ServerLedgerBalanceChip(presentation: presentation)
                                } else {
                                    ServerLedgerUnavailableChip(
                                        isLoading: serverLedger.status.phase == .loading
                                    )
                                }
                            } else if let me = me.first {
                                NetChip(net: BalanceMath.nets(in: group)[me.id] ?? 0)
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
                .onDelete { idx in
                    // A shared group has server-owned membership and history. A local
                    // model delete cannot represent a server deletion or leave action.
                    if idx.contains(where: { visibleGroups[$0].serverLedgerGroupID != nil }) {
                        groupDeleteErrorMessage = "Shared groups cannot be deleted here. Your group is unchanged."
                        showGroupDeleteError = true
                        return
                    }
                    groupsPendingLocalDeletion = idx.map { visibleGroups[$0] }
                    showLocalGroupDeleteConfirmation = !groupsPendingLocalDeletion.isEmpty
                }
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
                     ? "This permanently removes the group and its on-device data. This can't be undone."
                     : "This permanently removes the selected groups and their on-device data. This can't be undone.")
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
            .toolbar {
                Button { showAdd = true } label: {
                    BrandIconView(icon: .plus, size: 17).foregroundStyle(Color.Brand.creamSoft)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let group = visibleGroups.first(where: { $0.id == id }) {
                    GroupDetailScreen(group: group)
                }
            }
            .fullScreenCover(isPresented: $showAdd) { AddGroupSheet() }
        }
        // Screenshot support: `-openGroup <name>` pushes straight into a group.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-openGroup"), i + 1 < args.count else { return }
            let name = args[(i + 1)...].joined(separator: " ")
            if let g = visibleGroups.first(where: { $0.name == name }) { path.append(g.id) }
        }
        .task(id: visibleGroups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
            await serverLedger.refresh(groups: visibleGroups)
        }
        .alert("Group not deleted", isPresented: $showGroupDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(groupDeleteErrorMessage)
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
