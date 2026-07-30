import SwiftUI
import SwiftData

struct SharedSettleUpScreen: View {
    @Bindable var group: Group
    let currentUserName: String
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var activeServerGroupId: String?
    @State private var draftGroupId = ""
    @State private var linkError: String?
    @State private var store = SettlementStore()
    @State private var confirmationTransfer: SettlementPlanTransferDTO?
    @State private var confirmationNote = ""
    @State private var explanationTransfer: SettlementPlanTransferDTO?
    @State private var settledExpanded = false
    @State private var isSubmitting = false
    @State private var actionError: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let apiClient = APIClient.live()

    init(group: Group, currentUserName: String, onDismiss: @escaping () -> Void) {
        self.group = group
        self.currentUserName = currentUserName
        self.onDismiss = onDismiss
        let linked = SettlementAPIConfiguration.serverGroupId(for: group)
        _activeServerGroupId = State(initialValue: linked)
        _draftGroupId = State(initialValue: linked ?? group.serverGroupId ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            sharedHeader

            if let serverGroupId = activeServerGroupId {
                linkedSettleContent(serverGroupId: serverGroupId)
            } else {
                linkFairShareGroupPanel
            }
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .task(id: activeServerGroupId) {
            guard let serverGroupId = activeServerGroupId else { return }
            store.configure(
                apiClient: apiClient,
                groupId: serverGroupId,
                currentUserLabel: currentUserName
            )
            store.setVisible(true)
        }
        .onDisappear { store.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, activeServerGroupId != nil {
                Task { await store.refreshOnForeground() }
            }
        }
        .sheet(item: $confirmationTransfer) { transfer in
            settlementConfirmationSheet(transfer)
        }
        .sheet(item: $explanationTransfer) { transfer in
            transferExplanationSheet(transfer)
        }
        .accessibilityIdentifier("sharedSettleUpScreen")
    }

    private func linkedSettleContent(serverGroupId: String) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(group.name.uppercased())
                    .font(BrandFont.type(10, bold: true))
                    .tracking(1.4)
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.55))

                statusBanner
                simplificationPanel
                transferSections
                settledSection
            }
            .padding(18)
        }
        .background(Color.Brand.creamSoft)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var linkFairShareGroupPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(group.name.uppercased())
                    .font(BrandFont.type(10, bold: true))
                    .tracking(1.4)
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.55))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Link to FairShare group")
                        .font(BrandFont.display(18, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                    Text("Your phone keeps its own invoice group. Paste the FairShare group id from the web app so shared Settle Up knows which server group to load.")
                        .font(BrandFont.type(12))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.72))
                    BrandSectionLabel("FAIRSHARE GROUP ID")
                    TextField("e.g. grp_abc123", text: $draftGroupId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(BrandFont.type(14))
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
                        .accessibilityIdentifier("fairshareGroupIdField")
                    if let linkError {
                        Text(linkError)
                            .font(BrandFont.type(10.5, bold: true))
                            .foregroundStyle(Color.red.opacity(0.82))
                    }
                    Button(action: saveLinkedGroupId) {
                        Text("Save & load Settle Up")
                            .font(BrandFont.display(15, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(draftGroupId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("fairshareGroupIdSaveButton")
                }
                .padding(18)
                .background(Color.Brand.creamSoft)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
            }
            .padding(18)
        }
        .background(Color.Brand.creamSoft)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func saveLinkedGroupId() {
        let trimmed = draftGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            linkError = "Enter a FairShare group id."
            return
        }
        group.serverGroupId = trimmed
        do {
            try modelContext.save()
            linkError = nil
            activeServerGroupId = trimmed
        } catch {
            linkError = "Could not save the link. Try again."
        }
    }

    private var sharedHeader: some View {
        HStack {
            Button(action: onDismiss) {
                BrandIconView(icon: .x, size: 16)
                    .foregroundStyle(Color.Brand.cobalt)
                    .frame(width: 42, height: 42)
                    .background(Color.Brand.creamSoft, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Settle up")
            Spacer()
            Text("Settle up")
                .font(BrandFont.display(17, weight: .semibold))
                .foregroundStyle(Color.Brand.creamSoft)
            Spacer()
            if activeServerGroupId != nil {
                Button {
                    Task { await store.refresh(forceWritesDisabled: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.Brand.creamSoft)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh settlements")
            } else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if store.isLoading, store.snapshot == nil {
            settleBanner("Loading settlements…", showsProgress: true)
        } else if store.isOffline, store.snapshot != nil {
            settleBanner("Offline — showing cached balances. Writes disabled.")
        } else if store.isUpdating {
            settleBanner("Updating…")
        } else if store.requiresReconfirmation {
            settleBanner("Settlement changed. Confirm again.")
        } else if store.snapshot?.lifecycle.isArchived == true {
            settleBanner("Archived — read only.")
        } else if store.snapshot?.realtime.available == false {
            settleBanner("Realtime unavailable — refreshing every 10 seconds.")
        } else if store.lastError != nil, store.snapshot == nil {
            settleBanner("Could not load Settle Up.")
        }
    }

    @ViewBuilder
    private var simplificationPanel: some View {
        if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { snapshot.simplifyDebts },
                    set: { newValue in
                        Task {
                            do {
                                try await store.updateSimplifyDebts(newValue)
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                    }
                )) {
                    Text("Simplify debts")
                        .font(BrandFont.type(13, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                }
                .disabled(!store.writesEnabled || !snapshot.permissions.canChangeSetting)
                if let audit = snapshot.latestSettingAudit {
                    Text("Last changed by \(audit.actorName ?? "Unknown member") · \(settleFormattedDate(audit.createdAt))")
                        .font(BrandFont.type(10))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
                }
            }
            .padding(16)
            .background(Color.Brand.creamSoft)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
        }
    }

    @ViewBuilder
    private var transferSections: some View {
        if let snapshot = store.snapshot, snapshot.plan.isEmpty {
            VStack(spacing: 8) {
                MascotView(mascot: .celebrating, size: 120)
                Text("everyone is settled")
                    .font(BrandFont.hand(28, weight: .bold))
                    .foregroundStyle(Color.Brand.cobalt)
                if let completedAt = snapshot.settlementCompletedAt {
                    Text(settleFormattedDate(completedAt))
                        .font(BrandFont.type(11))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            let yours = store.yourTransfers()
            let everyone = store.everyoneTransfers()
            if yours.isEmpty == false {
                transferSection(title: "Your transfers", transfers: yours)
            }
            if everyone.isEmpty == false {
                transferSection(title: "Everyone", transfers: everyone, showSettle: false)
            }
        }
    }

    private func transferSection(
        title: String,
        transfers: [SettlementPlanTransferDTO],
        showSettle: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandSectionLabel(title.uppercased())
            ForEach(transfers) { transfer in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(transfer.payerName) → \(transfer.recipientName)")
                                .font(BrandFont.type(12.5, bold: true))
                            Text(transferAmount(transfer))
                                .font(BrandFont.type(16, bold: true))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                    }
                    HStack(spacing: 14) {
                        Button("Details") {
                            explanationTransfer = transfer
                            Task { await store.loadExplanation(for: transfer) }
                        }
                        .font(BrandFont.type(11, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                        if showSettle, store.canSettle(transfer), store.writesEnabled {
                            Button("Settle") {
                                confirmationNote = ""
                                actionError = nil
                                confirmationTransfer = transfer
                            }
                            .font(BrandFont.display(11, weight: .bold))
                            .foregroundStyle(Color.Brand.cobaltDeep)
                        }
                    }
                }
                .padding(.vertical, 6)
                if transfer.id != transfers.last?.id {
                    Rectangle()
                        .fill(Color.Brand.cobalt.opacity(0.12))
                        .frame(height: 1)
                }
            }
        }
        .padding(16)
        .background(Color.Brand.creamSoft)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
    }

    @ViewBuilder
    private var settledSection: some View {
        if let snapshot = store.snapshot, snapshot.permissions.canReadHistory {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.16) : BrandMotion.revealSpring) {
                        settledExpanded.toggle()
                    }
                } label: {
                    HStack {
                        BrandSectionLabel("SETTLED")
                        Spacer()
                        Image(systemName: settledExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                    }
                }
                .buttonStyle(.plain)
                if settledExpanded {
                    if snapshot.settled.items.isEmpty {
                        Text("No settlements yet.")
                            .font(BrandFont.type(11))
                            .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
                    } else {
                        ForEach(snapshot.settled.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(settledSummary(item))
                                    .font(BrandFont.type(12, bold: true))
                                    .foregroundStyle(Color.Brand.cobalt)
                                Text("\(item.actorName ?? "Unknown member") · \(settleFormattedDate(item.createdAt))")
                                    .font(BrandFont.type(10))
                                    .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
                                if item.type == "settlement", store.writesEnabled {
                                    Button("Reverse") {
                                        Task {
                                            do {
                                                try await store.reverse(settlementId: item.id)
                                            } catch {
                                                actionError = error.localizedDescription
                                            }
                                        }
                                    }
                                    .font(BrandFont.type(10, bold: true))
                                    .foregroundStyle(Color.Brand.cobaltDeep)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        if snapshot.settled.nextCursor != nil {
                            Button("Load more") {
                                Task { await store.loadMoreHistory() }
                            }
                            .font(BrandFont.type(11, bold: true))
                            .foregroundStyle(Color.Brand.cobalt)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.Brand.creamSoft)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
        }
    }

    private func settlementConfirmationSheet(_ transfer: SettlementPlanTransferDTO) -> some View {
        let expectedVersion = store.snapshot?.version ?? 0
        return NavigationStack {
            VStack(spacing: 12) {
                BrandModalHeader(title: "Confirm settlement") {
                    confirmationTransfer = nil
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(transfer.payerName) pays \(transfer.recipientName)")
                        .font(BrandFont.type(14, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                    Text(transferAmount(transfer))
                        .font(BrandFont.type(34, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                    Text("The server records an immutable date and time when you confirm.")
                        .font(BrandFont.type(10.5))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.66))
                    BrandSectionLabel("NOTE (OPTIONAL)")
                    TextField("Group-visible note", text: $confirmationNote, axis: .vertical)
                        .lineLimit(2...4)
                        .font(BrandFont.type(13))
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Brand.cobalt, lineWidth: 2))
                    if let actionError {
                        Text(actionError)
                            .font(BrandFont.type(10.5, bold: true))
                            .foregroundStyle(Color.red.opacity(0.82))
                    }
                    Button {
                        Task {
                            isSubmitting = true
                            defer { isSubmitting = false }
                            do {
                                try await store.settle(
                                    transfer: transfer,
                                    note: confirmationNote,
                                    expectedVersion: expectedVersion
                                )
                                confirmationTransfer = nil
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                    } label: {
                        Text(isSubmitting ? "Saving…" : "Confirm exact amount")
                            .font(BrandFont.display(15, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || !store.writesEnabled || store.requiresReconfirmation)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.Brand.creamSoft)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
            .background(Color.Brand.cobalt.ignoresSafeArea())
        }
        .presentationDetents([.medium, .large])
    }

    private func transferExplanationSheet(_ transfer: SettlementPlanTransferDTO) -> some View {
        NavigationStack {
            VStack(spacing: 12) {
                BrandModalHeader(title: "Transfer details") {
                    explanationTransfer = nil
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(transfer.payerName) → \(transfer.recipientName)")
                        .font(BrandFont.type(13, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                    if let explanation = store.explanation {
                        if let expenses = explanation.directExpenses {
                            ForEach(expenses) { expense in
                                Text("\(expense.description): \(expense.amount)")
                                    .font(BrandFont.type(11))
                                    .foregroundStyle(Color.Brand.cobalt)
                            }
                        }
                        if let paths = explanation.simplifiedPaths {
                            ForEach(paths) { path in
                                Text("\(path.path): \(path.amount)")
                                    .font(BrandFont.type(11))
                                    .foregroundStyle(Color.Brand.cobalt)
                            }
                        }
                    } else if store.explanationError != nil {
                        Text("Could not load transfer details.")
                            .font(BrandFont.type(11))
                            .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
                    } else {
                        ProgressView().tint(Color.Brand.cobalt)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.Brand.creamSoft)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
            .background(Color.Brand.cobalt.ignoresSafeArea())
        }
        .presentationDetents([.medium])
    }

    private func settleBanner(_ text: String, showsProgress: Bool = false) -> some View {
        HStack(spacing: 10) {
            if showsProgress { ProgressView().tint(Color.Brand.cobalt) }
            Text(text)
                .font(BrandFont.type(11, bold: true))
                .foregroundStyle(Color.Brand.cobalt)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.Brand.cobalt.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func transferAmount(_ transfer: SettlementPlanTransferDTO) -> String {
        if transfer.currencyCode.uppercased() == Money.currentCurrency.rawValue.uppercased() {
            if let decimal = Decimal(string: transfer.amount) {
                return Money.currency(decimal)
            }
        }
        return "\(transfer.currencyCode) \(transfer.amount)"
    }

    private func settledSummary(_ item: SettlementHistoryItemDTO) -> String {
        switch item.type {
        case "reversal":
            return "Reversal"
        default:
            return "\(item.payerName ?? "?") paid \(item.recipientName ?? "?") · \(item.amount ?? "") \(item.currencyCode ?? "")"
        }
    }
}

private func settleFormattedDate(_ iso: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    return iso
}
