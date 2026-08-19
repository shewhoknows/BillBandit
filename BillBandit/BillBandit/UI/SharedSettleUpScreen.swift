import SwiftUI
import SwiftData

struct SharedSettleUpScreen: View {
    @Bindable var group: Group
    let currentUserName: String
    let onDismiss: () -> Void

    @State private var activeServerGroupId: String?
    @State private var store = SettlementStore()
    @State private var confirmationTransfer: SettlementPlanTransferDTO?
    @State private var confirmationNote = ""
    @State private var settledExpanded = false
    @State private var isSubmitting = false
    @State private var actionError: String?
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        group: Group,
        currentUserName: String,
        onDismiss: @escaping () -> Void,
        settlementStore: SettlementStore? = nil
    ) {
        self.group = group
        self.currentUserName = currentUserName
        self.onDismiss = onDismiss
        let linked = SettlementAPIConfiguration.serverGroupId(for: group)
        _activeServerGroupId = State(initialValue: linked)
        _store = State(initialValue: settlementStore ?? SettlementStore())
    }

    var body: some View {
        VStack(spacing: 12) {
            sharedHeader

            if let serverGroupId = activeServerGroupId {
                linkedSettleContent(serverGroupId: serverGroupId)
            } else {
                localOnlySettlePanel
            }
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .task(id: activeServerGroupId) {
            guard let serverGroupId = activeServerGroupId else { return }
            guard let remoteUser = try? await UsernameIdentityService.currentUser() else {
                store.markIdentityUnavailable()
                return
            }
            let settlementUserLabel = [
                remoteUser.name,
                remoteUser.preferredName,
                remoteUser.username,
                currentUserName
            ]
            .compactMap { $0 }
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "You"
            store.configure(
                accountID: remoteUser.id,
                groupID: serverGroupId,
                currentUserLabel: settlementUserLabel
            )
            store.setVisible(true)
        }
        .onDisappear { store.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, activeServerGroupId != nil {
                Task { await store.refreshOnForeground() }
            }
        }
        .fullScreenCover(item: $confirmationTransfer, onDismiss: {
            store.setInteractionActive(false)
        }) { transfer in
            settlementConfirmationSheet(transfer)
        }
        .accessibilityIdentifier("sharedSettleUpScreen")
    }

    private func linkedSettleContent(serverGroupId: String) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                settleHero

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

    private var settleHero: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(BrandFont.handText("settle the score"))
                    .font(BrandFont.hand(30, weight: .bold))
                    .foregroundStyle(Color.Brand.cobalt)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                Text(group.name.uppercased())
                    .font(BrandFont.type(10, bold: true))
                    .tracking(1.5)
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 88)

            MascotView(mascot: .thinking, size: 88)
                .padding(.bottom, -14)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
    }

    private var localOnlySettlePanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(group.name.uppercased())
                    .font(BrandFont.type(10, bold: true))
                    .tracking(1.4)
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.55))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Group balance unavailable")
                        .font(BrandFont.display(18, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                    Text("This group is still getting ready. Try again after it finishes updating.")
                        .font(BrandFont.type(12))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.72))
                    Button(action: onDismiss) {
                        Text("Close")
                            .font(BrandFont.display(15, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }
                    .buttonStyle(.plain)
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
                    ZStack {
                        if store.isUpdating || store.isLoading {
                            ProgressView()
                                .tint(Color.Brand.creamSoft)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.Brand.creamSoft)
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .disabled(store.isUpdating || store.isLoading)
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
        } else if store.isMigrationBlocked {
            settleBanner("This group is still updating — read only.")
        } else if store.isOffline, store.snapshot != nil {
            settleBanner(
                store.canQueueSettlement
                    ? "Offline — cached balances shown. Payments will sync when you reconnect."
                    : "Offline — showing cached balances. Writes disabled."
            )
        } else if store.requiresReconfirmation {
            settleBanner("Settlement changed. Confirm again.")
        } else if store.snapshot?.lifecycle.isArchived == true {
            settleBanner("Archived — read only.")
        } else if store.lastError != nil, store.snapshot == nil {
            settleBanner("Could not load Settle Up.")
        }
    }

    @ViewBuilder
    private var simplificationPanel: some View {
        if let snapshot = store.snapshot {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.simplifyDebts ? "Debts simplified" : "Direct payments")
                        .font(BrandFont.display(15, weight: .semibold))
                    Text(snapshot.simplifyDebts
                         ? "Fewer payments between members"
                         : "Payments follow each original balance")
                        .font(BrandFont.type(10, bold: true))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.58))
                }
                Spacer()
                BrandCheckmark(isOn: snapshot.simplifyDebts)
            }
            .foregroundStyle(Color.Brand.cobalt)
            .padding(.horizontal, 16)
            .frame(minHeight: 66)
            .background(Color.Brand.creamSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.Brand.cobalt, lineWidth: BrandOutline.control)
            )
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var transferSections: some View {
        if let snapshot = store.snapshot, snapshot.plan.isEmpty {
            VStack(spacing: 8) {
                MascotView(mascot: .celebrating, size: 120)
                Text(BrandFont.handText("everyone is settled"))
                    .font(BrandFont.hand(28, weight: .bold))
                    .foregroundStyle(Color.Brand.cobalt)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
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
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(transfer.payerName) pays \(transfer.recipientName)")
                                .font(BrandFont.display(16, weight: .semibold))
                                .foregroundStyle(Color.Brand.cobalt)
                            Text(transferAmount(transfer))
                                .font(BrandFont.display(30, weight: .bold))
                                .foregroundStyle(Color.Brand.cobalt)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                    }

                    if showSettle, store.canDisplaySettlementAction(transfer) {
                        Button {
                            store.setInteractionActive(true)
                            confirmationNote = ""
                            actionError = nil
                            confirmationTransfer = transfer
                        } label: {
                            Text("Settle \(transferAmount(transfer))")
                                .font(BrandFont.display(14, weight: .bold))
                                .foregroundStyle(Color.Brand.creamSoft)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(Color.Brand.cobalt, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canStartSettlement(transfer))
                        .opacity(store.canStartSettlement(transfer) ? 1 : 0.48)
                        .accessibilityIdentifier("settleTransferButton-\(transfer.id)")
                    }
                }
                .padding(.vertical, 8)
                if transfer.id != transfers.last?.id {
                    Rectangle()
                        .fill(Color.Brand.cobalt.opacity(0.12))
                        .frame(height: 1)
                }
            }
        }
        .padding(16)
        .background(Color.Brand.creamSoft)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.Brand.cobalt, lineWidth: BrandOutline.control)
        )
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
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(BrandFont.handText("payment ready"))
                                .font(BrandFont.hand(29, weight: .bold))
                                .foregroundStyle(Color.Brand.cobalt)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: true)
                            Text(group.name.uppercased())
                                .font(BrandFont.type(10, bold: true))
                                .tracking(1.5)
                                .foregroundStyle(Color.Brand.cobalt.opacity(0.55))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(transfer.payerName) pays \(transfer.recipientName)")
                                .font(BrandFont.display(17, weight: .semibold))
                            Text(transferAmount(transfer))
                                .font(BrandFont.display(42, weight: .bold))
                                .monospacedDigit()
                            Text("This marks the payment as complete for everyone in the group.")
                                .font(BrandFont.type(11, bold: true))
                                .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
                        }
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.Brand.cobalt, lineWidth: BrandOutline.control)
                        )

                        BrandSectionLabel("NOTE (OPTIONAL)")
                        TextField("Add a note for the group", text: $confirmationNote, axis: .vertical)
                            .lineLimit(2...4)
                            .font(BrandFont.type(13))
                            .foregroundStyle(Color.Brand.cobalt)
                            .padding(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.Brand.cobalt, lineWidth: BrandOutline.control)
                            )
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
                                    let settlementEventID = try await store.settle(
                                        transfer: transfer,
                                        note: confirmationNote,
                                        expectedVersion: expectedVersion
                                    )
                                    confirmationTransfer = nil
                                    if let settlementEventID,
                                       let currentUser = currentUsers.first {
                                        let outcome = try? RewardEngine.award(
                                            action: .settlementRecorded,
                                            eventID: SharedRewardReconciler.eventID(
                                                for: settlementEventID
                                            ),
                                            personID: currentUser.id,
                                            context: context
                                        )
                                        try? context.save()
                                        if let outcome {
                                            RewardFeedbackCenter.shared.present(outcome)
                                        }
                                    }
                                    await ServerLedgerSurfaceStore.shared.refresh(groups: [group])
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                        } label: {
                            Text(isSubmitting ? "Saving…" : "Confirm payment")
                                .font(BrandFont.display(15, weight: .bold))
                                .foregroundStyle(Color.Brand.creamSoft)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.Brand.cobalt, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            isSubmitting
                                || !store.canConfirmSettlement(transfer, expectedVersion: expectedVersion)
                        )
                        .opacity(
                            isSubmitting
                                || !store.canConfirmSettlement(transfer, expectedVersion: expectedVersion)
                                ? 0.48 : 1
                        )
                        .accessibilityIdentifier("confirmSettlementButton")
                    }
                    .padding(18)
                }
                .background(Color.Brand.creamSoft)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
            .background(Color.Brand.cobalt.ignoresSafeArea())
        }
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
        SettlementMoneyFormatting.display(
            minorUnits: transfer.minorUnits,
            currencyCode: transfer.currencyCode,
            currencyExponent: transfer.currencyExponent
        )
    }

    private func settledSummary(_ item: SettlementHistoryItemDTO) -> String {
        switch item.type {
        case "reversal":
            return "Reversal"
        default:
            if let minorUnits = item.minorUnits,
               let currencyCode = item.currencyCode,
               let currencyExponent = item.currencyExponent {
                return "\(item.payerName ?? "?") paid \(item.recipientName ?? "?") · "
                    + SettlementMoneyFormatting.display(
                        minorUnits: minorUnits,
                        currencyCode: currencyCode,
                        currencyExponent: currencyExponent
                    )
            }
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
