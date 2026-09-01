import SwiftUI
import SwiftData
import UIKit
import Foundation

struct AddGroupSheet: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: GroupIcon = .house
    @State private var selected = Set<UUID>()
    @State private var simplify = true
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isSubmitting = false
    @State private var activeOperationID: UUID?
    @State private var requiresReconfirmation = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var memberOptions: [Person] {
        ConnectedFriendIdentity.groupMemberOptions(from: people)
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "New group") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    BrandSectionLabel("NAME")
                    TextField("Group name", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { nameFocused = false }
                        .accessibilityIdentifier("groupNameField")
                        .font(BrandFont.type(15, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))

                    BrandSectionLabel("ICON")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                        ForEach(GroupIcon.allCases, id: \.self) { gi in
                            Button { icon = gi } label: {
                                BrandIconView(icon: gi.icon, size: 22)
                                    .foregroundStyle(icon == gi ? Color.Brand.creamSoft : Color.Brand.cobalt)
                                    .frame(width: 44, height: 44)
                                    .background(icon == gi ? Color.Brand.cobalt : .clear)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    BrandSectionLabel("MEMBERS")
                    VStack(spacing: 0) {
                        ForEach(Array(memberOptions.enumerated()), id: \.element.id) { index, person in
                            Button { toggle(person) } label: {
                                HStack {
                                    Text(person.isCurrentUser ? "\(person.name) · you" : person.name)
                                        .font(BrandFont.body(14, weight: .bold))
                                        .foregroundStyle(Color.Brand.cobalt)
                                    Spacer()
                                    BrandCheckmark(isOn: person.isCurrentUser || selected.contains(person.id))
                                }
                                .padding(.horizontal, 15)
                                .frame(height: 50)
                            }
                            .buttonStyle(.plain)
                            .disabled(person.isCurrentUser)
                            if index < memberOptions.count - 1 {
                                Rectangle().fill(Color.Brand.cobalt.opacity(0.18)).frame(height: 1)
                                    .padding(.horizontal, 15)
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.Brand.cobalt, lineWidth: 2))

                    Button { simplify.toggle() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Simplify debts")
                                    .font(BrandFont.display(14, weight: .semibold))
                                Text("Fewer payments between members")
                                    .font(BrandFont.type(9.5, bold: true))
                                    .opacity(0.58)
                            }
                            Spacer()
                            BrandCheckmark(isOn: simplify)
                        }
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(.horizontal, 16)
                        .frame(height: 62)
                    }
                    .buttonStyle(.plain)
                    .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))

                    if let statusMessage {
                        Text(statusMessage)
                            .font(BrandFont.type(10, bold: true))
                            .foregroundStyle(Color.Brand.cobalt.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("groupMutationStatus")
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(BrandFont.type(10, bold: true))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("groupMutationError")
                    }

                    Button(action: create) {
                        Text(isSubmitting ? "Creating…" : "Create group")
                            .font(BrandFont.display(15.5, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("createGroupButton")
                    .disabled(trimmedName.isEmpty || isSubmitting || requiresReconfirmation)
                    .opacity(trimmedName.isEmpty || isSubmitting || requiresReconfirmation ? 0.45 : 1)
                }
                .padding(18)
            }
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .task {
            await FriendInvitationService.shared.refreshAcceptedInvites()
            await CloudCollaborationService.shared.refreshFriendProfiles()
        }
    }

    private func toggle(_ person: Person) {
        guard !person.isCurrentUser else { return }
        if selected.contains(person.id) { selected.remove(person.id) }
        else { selected.insert(person.id) }
    }

    private func create() {
        let finalName = trimmedName.capitalizingFirstLetter
        guard !finalName.isEmpty else { return }

        guard !isSubmitting, !requiresReconfirmation else { return }
        if UsernameIdentityService.hasStoredSession {
            guard selected.isEmpty else {
                errorMessage = "Shared groups can only use canonical server members. Create the group first, then add members from the shared group."
                statusMessage = nil
                return
            }

            let operationID = activeOperationID ?? UUID()
            activeOperationID = operationID
            isSubmitting = true
            errorMessage = nil
            statusMessage = "Creating shared group…"
            Task { @MainActor in
                await createServerGroup(
                    name: finalName,
                    icon: icon,
                    simplifyDebts: simplify,
                    operationID: operationID
                )
            }
            return
        }

        createLocalGroup(named: finalName)
    }

    private func createLocalGroup(named finalName: String) {
        var memberIDs = Set<UUID>()
        let members = memberOptions.compactMap { person -> Person? in
            guard person.isCurrentUser || selected.contains(person.id) else { return nil }
            let preferred = ConnectedFriendIdentity.preferredPerson(for: person, among: people)
            return memberIDs.insert(preferred.id).inserted ? preferred : nil
        }
        let group = Group(name: finalName, icon: icon, simplifyDebts: simplify, members: members)
        context.insert(group)
        let currentUser = people.first(where: \.isCurrentUser)
        context.insert(ActivityItem(kind: .groupCreated,
                                    summary: "\(currentUser?.name ?? "You") created “\(finalName)”",
                                    refID: group.id, actorID: currentUser?.id,
                                    groupID: group.id, groupName: group.name))
        let rewardOutcome = currentUser.flatMap { currentUser in
            try? RewardEngine.award(action: .groupCreated, eventID: group.id,
                                    personID: currentUser.id, context: context)
        }
        do {
            try context.save()
            CloudCollaborationService.shared.groupDidChange(group)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            if let rewardOutcome {
                RewardFeedbackCenter.shared.present(rewardOutcome)
            }
        } catch {
            return
        }
    }

    @MainActor
    private func createServerGroup(
        name: String,
        icon: GroupIcon,
        simplifyDebts: Bool,
        operationID: UUID
    ) async {
        let runtime = T15CanonicalLedgerRuntime.shared
        do {
            let remoteUser = try await runtime.authenticatedUser()
            let response: T15GroupCreateEnvelope = try await APIClient.live().post(
                "/api/mobile/groups",
                body: T15GroupCreateRequest(
                    name: name,
                    description: nil,
                    currency: Money.currentCurrency.rawValue,
                    category: "OTHER"
                ),
                idempotencyKey: operationID.uuidString
            )
            let serverGroupID = response.group.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverGroupID.isEmpty else { throw T15LedgerUIError.groupResponseMissingID }

            let scope = ServerBackedLedgerScope(
                accountID: remoteUser.id,
                groupID: serverGroupID
            )
            let canonicalGroup: SettlementCanonicalLedgerGroup?
            do {
                let snapshot = try await runtime.refresh(scope: scope)
                canonicalGroup = try runtime.validatedGroup(from: snapshot, scope: scope)
            } catch {
                // The POST has already been acknowledged. Keep only the
                // server identity locally; the canonical read model will be
                // refreshed by the shared surfaces when transport returns.
                canonicalGroup = nil
                statusMessage = "Group created. Shared details are waiting for a canonical refresh."
            }

            var newlyCreatedPeople = [Person]()
            let members = localPeople(
                for: canonicalGroup,
                accountID: remoteUser.id,
                newlyCreatedPeople: &newlyCreatedPeople
            )
            let localGroup = Group(
                id: operationID,
                name: canonicalGroup?.name ?? name,
                icon: icon,
                simplifyDebts: simplifyDebts,
                members: members,
                serverGroupId: serverGroupID
            )
            for person in newlyCreatedPeople { context.insert(person) }
            context.insert(localGroup)

            // A shared group is represented locally only as a routing/index
            // projection after server acknowledgement. Its ledger and
            // activity remain canonical server data.
            if let currentUser = members.first(where: \.isCurrentUser) {
                _ = try? RewardEngine.award(
                    action: .groupCreated,
                    eventID: localGroup.id,
                    personID: currentUser.id,
                    context: context
                )
            }
            try context.save()
            await ServerLedgerSurfaceStore.shared.refresh(groups: [localGroup])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isSubmitting = false
            activeOperationID = nil
            dismiss()
        } catch {
            isSubmitting = false
            requiresReconfirmation = true
            errorMessage = T15LedgerUIError.message(for: error, fallback: "Could not create the shared group.")
            statusMessage = "The server did not confirm this operation. Refresh before trying again."
        }
    }

    private func localPeople(
        for canonicalGroup: SettlementCanonicalLedgerGroup?,
        accountID: String,
        newlyCreatedPeople: inout [Person]
    ) -> [Person] {
        guard let canonicalGroup else {
            if let current = people.first(where: \.isCurrentUser) { return [current] }
            let current = Person(name: "You", isCurrentUser: true)
            newlyCreatedPeople.append(current)
            return [current]
        }

        var result = [Person]()
        var seen = Set<UUID>()
        for member in canonicalGroup.members {
            let localIdentityID = member.localIdentityID.flatMap(UUID.init(uuidString:))
            let existing = localIdentityID.flatMap { id in people.first(where: { $0.id == id }) }
                ?? (member.accountID == accountID ? people.first(where: \.isCurrentUser) : nil)
            let person: Person
            if let existing {
                person = existing
            } else if let localIdentityID {
                person = Person(id: localIdentityID,
                                name: member.displayName,
                                isCurrentUser: member.accountID == accountID)
                newlyCreatedPeople.append(person)
            } else {
                // There is no safe local identity for this server member.
                // Do not invent a local UUID that could later enter a shared
                // mutation as if it were a canonical member.
                continue
            }
            guard seen.insert(person.id).inserted else { continue }
            result.append(person)
        }

        if !result.contains(where: \.isCurrentUser),
           let current = people.first(where: \.isCurrentUser) {
            result.insert(current, at: 0)
        }
        return result
    }
}

struct BrandCheckmark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.Brand.cobalt : .clear)
                .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
            if isOn {
                Text("✓")
                    .font(BrandFont.body(13, weight: .extraBold))
                    .foregroundStyle(Color.Brand.creamSoft)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(isOn ? "Selected" : "Not selected")
    }
}

private struct T15GroupCreateRequest: Encodable {
    let name: String
    let description: String?
    let currency: String
    let category: String
}

private struct T15GroupCreateEnvelope: Decodable {
    let group: T15GroupCreateResponse
}

private struct T15GroupCreateResponse: Decodable {
    let id: String
}

enum T15LedgerUIError: LocalizedError {
    case unauthenticated
    case groupResponseMissingID
    case canonicalSnapshotUnavailable
    case canonicalReadOnly
    case canonicalConflict
    case memberIdentityUnavailable(String)
    case expenseNotInCanonicalSnapshot
    case unsupportedSharedCurrency(String)
    case nonIntegralShares

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Sign in before changing the shared ledger."
        case .groupResponseMissingID:
            return "The server created no usable group identity."
        case .canonicalSnapshotUnavailable:
            return "The shared ledger is not ready yet. Refresh and try again."
        case .canonicalReadOnly:
            return "The shared ledger is read-only while it refreshes."
        case .canonicalConflict:
            return "The shared ledger changed. Refresh and confirm this action again."
        case let .memberIdentityUnavailable(name):
            return "The server has no canonical member identity for \(name). Refresh the group before saving."
        case .expenseNotInCanonicalSnapshot:
            return "This expense has no canonical server identity yet. Refresh before editing it."
        case let .unsupportedSharedCurrency(code):
            return "This shared group uses \(code). Change the app currency before saving."
        case .nonIntegralShares:
            return "Shared-ledger shares must be whole numbers."
        }
    }

    static func message(for error: Error, fallback: String) -> String {
        switch error {
        case ServerLedgerSyncError.unauthorized,
             ServerLedgerAPIClientError.unauthorized, SettlementAPIError.unauthorized:
            return "Your shared-ledger session expired. Sign in again before retrying."
        case ServerLedgerSyncError.offline,
             ServerLedgerAPIClientError.offline, SettlementAPIError.offline:
            return "Offline. Shared changes are waiting for a connection; local-only changes remain available."
        case ServerLedgerSyncError.conflictRequiresReconfirmation,
             ServerLedgerAPIClientError.revisionConflict:
            return "The shared ledger changed. Refresh it, then confirm this action again."
        case ServerLedgerAPIClientError.idempotencyKeyReused:
            return "This operation ID is already bound to another request. Start again from a fresh form."
        case let localError as T15LedgerUIError:
            return localError.localizedDescription
        default:
            let description = error.localizedDescription
            return description.isEmpty ? fallback : description
        }
    }

    static func isOffline(_ error: Error) -> Bool {
        switch error {
        case ServerLedgerSyncError.offline,
             ServerLedgerAPIClientError.offline,
             SettlementAPIError.offline:
            return true
        default:
            return false
        }
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        switch error {
        case ServerLedgerSyncError.unauthorized,
             ServerLedgerAPIClientError.unauthorized,
             SettlementAPIError.unauthorized:
            return true
        default:
            return false
        }
    }

    static func isConflict(_ error: Error) -> Bool {
        switch error {
        case ServerLedgerSyncError.conflictRequiresReconfirmation,
             ServerLedgerAPIClientError.revisionConflict,
             T15LedgerUIError.canonicalConflict:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class T15CanonicalLedgerRuntime {
    static let shared = T15CanonicalLedgerRuntime()

    let store: ServerLedgerStore
    let coordinator: ServerLedgerMutationCoordinator
    let sync: ServerLedgerSync

    private init() {
        store = AppStore.serverLedgerStore
        coordinator = ServerLedgerMutationCoordinator(store: store)
        sync = ServerLedgerSync(store: store, apiClient: URLSessionServerLedgerAPIClient.live())
    }

    func authenticatedUser() async throws -> UsernameIdentityService.RemoteUser {
        guard UsernameIdentityService.hasStoredSession else {
            throw T15LedgerUIError.unauthenticated
        }
        let user = try await UsernameIdentityService.currentUser()
        try coordinator.activate(accountID: user.id)
        try sync.activate(accountID: user.id)
        return user
    }

    func cachedOrRefresh(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        if let cached = try store.cachedSnapshot(for: scope) { return cached }
        return try await refresh(scope: scope)
    }

    func refresh(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        sync.markReconnected()
        return try await sync.refresh(scope: scope)
    }

    func enqueueExpense(
        operationID: UUID,
        scope: ServerBackedLedgerScope,
        expectedRevision: Int64,
        kind: String,
        method: String,
        path: String,
        body: Data
    ) throws {
        if sync.requiresReconfirmation {
            let request = ServerLedgerMutationRequest(
                operationID: operationID,
                scope: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
                expectedRevision: expectedRevision,
                kind: kind,
                method: method,
                path: path,
                body: body
            )
            _ = try sync.reconfirm(
                operationID: operationID,
                scope: request.scope,
                expectedRevision: expectedRevision,
                requestPayload: request.requestPayload
            )
        } else {
            _ = try coordinator.enqueueExpenseAction(
                operationID: operationID,
                scope: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
                expectedRevision: expectedRevision,
                kind: kind,
                method: method,
                path: path,
                body: body
            )
        }
    }

    func reconcile(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        sync.markReconnected()
        return try await sync.onForeground(scope: scope)
    }

    func validatedGroup(
        from snapshot: ServerLedgerSnapshot,
        scope: ServerBackedLedgerScope
    ) throws -> SettlementCanonicalLedgerGroup {
        guard snapshot.accountID == scope.accountID,
              snapshot.groupID == scope.groupID else {
            throw ServerLedgerAPIClientError.snapshotScopeMismatch
        }
        let envelope = try JSONDecoder.serverLedger.decode(
            SettlementCanonicalLedgerReadEnvelope.self,
            from: snapshot.payload
        )
        let group = envelope.data.group
        guard envelope.contractVersion == ServerLedgerContract.version,
              envelope.kind == "read",
              envelope.scope.kind == .shared,
              envelope.scope.accountID == scope.accountID,
              envelope.scope.groupID == scope.groupID,
              envelope.scope.localOnly == false,
              group.scope == "shared",
              group.localOnly == false,
              group.accountID == scope.accountID,
              group.groupID == scope.groupID,
              envelope.revision == snapshot.revision,
              Int64(group.revision) == envelope.revision,
              Int64(group.readRevision) == envelope.readRevision else {
            throw ServerLedgerAPIClientError.snapshotScopeMismatch
        }
        let readOnlyStatuses = ["pending", "in_progress", "blocked"]
        guard !readOnlyStatuses.contains(envelope.migration.status),
              !readOnlyStatuses.contains(group.migration.status),
              !envelope.stale.isStale,
              !group.stale.isStale else {
            throw T15LedgerUIError.canonicalReadOnly
        }
        return group
    }
}
