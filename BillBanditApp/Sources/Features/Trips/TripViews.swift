import SwiftUI

struct TripSummary: Identifiable, Hashable {
    var trip: Trip
    var total: Money
    var expenseCount: Int

    var id: String { trip.id }
}

@MainActor
@Observable
final class TripListViewModel {
    private let tripRepository: any TripRepository
    var summaries: [TripSummary] = []
    var isLoading = false
    var errorMessage: String?

    init(tripRepository: any TripRepository) {
        self.tripRepository = tripRepository
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let trips = try await tripRepository.list()
            var loaded: [TripSummary] = []
            for trip in trips {
                if let detail = try? await tripRepository.get(id: trip.id) {
                    loaded.append(
                        TripSummary(
                            trip: detail.trip,
                            total: detail.expenses.reduce(.zero(currency: detail.trip.currency)) { $0 + $1.amount },
                            expenseCount: detail.expenses.count
                        )
                    )
                } else {
                    loaded.append(TripSummary(trip: trip, total: .zero(currency: trip.currency), expenseCount: 0))
                }
            }
            summaries = loaded
        } catch {
            errorMessage = error.billBanditMessage
        }
        isLoading = false
    }
}

@MainActor
@Observable
final class CreateTripViewModel {
    private let tripRepository: any TripRepository
    var name = ""
    var note = ""
    var currencyCode = "INR"
    var category: MobileGroup.Category = .trip
    var isSaving = false
    var errorMessage: String?

    init(tripRepository: any TripRepository) {
        self.tripRepository = tripRepository
    }

    func create() async -> Trip? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Give this trip a receipt name."
            return nil
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            return try await tripRepository.create(
                name: cleanName,
                description: note.nilIfBlank,
                currency: Currency(code: currencyCode),
                category: category
            )
        } catch {
            errorMessage = error.billBanditMessage
            return nil
        }
    }
}

@MainActor
@Observable
final class TripDashboardViewModel {
    private let tripRepository: any TripRepository
    private let participantRepository: any ParticipantRepository
    private let settlementRepository: any SettlementRepository
    let capabilities: BackendCapabilities
    let tripId: String

    var detail: TripDetail?
    var isLoading = false
    var isMutating = false
    var errorMessage: String?
    var memberEmail = ""
    var settlementNote: String?

    init(container: DataContainer, tripId: String) {
        self.tripRepository = container.tripRepository
        self.participantRepository = container.participantRepository
        self.settlementRepository = container.settlementRepository
        self.capabilities = container.capabilities
        self.tripId = tripId
    }

    var trip: Trip? { detail?.trip }
    var expenses: [Expense] { detail?.expenses ?? [] }
    var settlementSummary: SettlementSummary? { detail?.settlementSummary }
    var isFinalized: Bool { trip?.status == .finalized }
    var totalSpend: Money {
        expenses.reduce(.zero(currency: trip?.currency ?? .inr)) { $0 + $1.amount }
    }
    var perPersonSpend: Money {
        let count = max(trip?.participants.count ?? 1, 1)
        return Money(minorUnits: totalSpend.minorUnits / count, currency: totalSpend.currency)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await tripRepository.get(id: tripId)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isLoading = false
    }

    func addMember() async {
        guard let trip, !isFinalized else {
            errorMessage = "This trip is finalized, so members cannot be added."
            return
        }
        let email = memberEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            errorMessage = "Enter the member's exact account email."
            return
        }
        isMutating = true
        errorMessage = nil
        do {
            _ = try await participantRepository.addMember(groupId: trip.id, email: email)
            memberEmail = ""
            detail = try await tripRepository.get(id: trip.id)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isMutating = false
    }

    func finalize() async {
        guard let trip else { return }
        isMutating = true
        errorMessage = nil
        do {
            detail = try await tripRepository.finalize(id: trip.id)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isMutating = false
    }

    func record(_ instruction: SettlementInstruction) async {
        guard let trip else { return }
        isMutating = true
        errorMessage = nil
        do {
            _ = try await settlementRepository.record(
                groupId: trip.id,
                receiverId: instruction.to,
                senderId: nil,
                amount: instruction.amount,
                note: "Settled from BillBandit"
            )
            detail = try await tripRepository.get(id: trip.id)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isMutating = false
    }
}

enum TripRoute: Hashable {
    case dashboard(String)
    case finalBill(String)
}

struct TripsNavigationView: View {
    let container: DataContainer
    @State private var path: [TripRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            TripListView(
                model: TripListViewModel(tripRepository: container.tripRepository),
                createModel: CreateTripViewModel(tripRepository: container.tripRepository),
                openTrip: { path.append(.dashboard($0.id)) }
            )
            .navigationDestination(for: TripRoute.self) { route in
                switch route {
                case .dashboard(let id):
                    TripDashboardView(
                        model: TripDashboardViewModel(container: container, tripId: id),
                        container: container,
                        openFinalBill: { path.append(.finalBill(id)) }
                    )
                case .finalBill(let id):
                    FinalBillView(model: FinalBillViewModel(tripRepository: container.tripRepository, tripId: id))
                }
            }
        }
    }
}

struct TripListView: View {
    @State var model: TripListViewModel
    @State var createModel: CreateTripViewModel
    let openTrip: (Trip) -> Void
    @State private var isCreating = false

    var body: some View {
        Group {
            if model.isLoading && model.summaries.isEmpty {
                LoadingReceiptView()
            } else if let error = model.errorMessage, model.summaries.isEmpty {
                ErrorReceiptView(message: error) {
                    Task { await model.load() }
                }
            } else {
                ReceiptScroll {
                    header

                    if model.summaries.isEmpty {
                        EmptyState(
                            mascot: .peek,
                            title: "No trips yet",
                            message: "Create your first trip receipt and invite the crew by email.",
                            primaryActionTitle: "Create trip"
                        ) {
                            isCreating = true
                        }
                    } else {
                        ForEach(model.summaries) { summary in
                            TripSummaryCard(summary: summary) {
                                openTrip(summary.trip)
                            }
                        }
                    }
                }
                .refreshable {
                    await model.load()
                }
            }
        }
        .navigationTitle("Trips")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create trip")
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                CreateTripView(model: createModel) { trip in
                    isCreating = false
                    Task { await model.load() }
                    openTrip(trip)
                }
            }
        }
        .task {
            await model.load()
        }
    }

    private var header: some View {
        ReceiptCard(eyebrow: "Trip receipts", title: "Your ledger trail", subtitle: "Pull to refresh when someone adds a bill.") {
            PrimaryButton(title: "Create trip", systemImage: "plus") {
                isCreating = true
            }
        }
    }
}

struct TripSummaryCard: View {
    let summary: TripSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ReceiptCard(eyebrow: "\(summary.trip.participants.count) members", title: summary.trip.name, subtitle: "\(summary.expenseCount) expenses", barcodeValue: summary.trip.id) {
                VStack(spacing: BBSpacing.sm) {
                    AmountRow(title: "Trip total", amount: summary.total, subtitle: "CURRENT TOTAL")
                    if summary.trip.status == .finalized {
                        HStack {
                            Spacer()
                            StampBadge(text: "Finalized", systemImage: "checkmark.seal.fill", tone: BBColor.success)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct CreateTripView: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: CreateTripViewModel
    let onCreated: (Trip) -> Void

    var body: some View {
        @Bindable var model = model

        ReceiptScroll {
            ReceiptCard(eyebrow: "New receipt", title: "Create trip", subtitle: "Destination notes stay in the description field the backend actually stores.") {
                VStack(spacing: BBSpacing.lg) {
                    ReceiptFormSection(title: "Trip name") {
                        HandwrittenTextField(title: "Trip name", placeholder: "Goa food run", text: $model.name)
                    }

                    ReceiptFormSection(title: "Description", subtitle: "Optional. Saved as the trip description.") {
                        HandwrittenTextEditor(placeholder: "Destination, plan, or tiny warning to future you", text: $model.note, minHeight: 92)
                    }

                    ReceiptFormSection(title: "Currency") {
                        Picker("Currency", selection: $model.currencyCode) {
                            Text("INR").tag("INR")
                            Text("USD").tag("USD")
                            Text("EUR").tag("EUR")
                            Text("GBP").tag("GBP")
                        }
                        .pickerStyle(.segmented)
                    }

                    ReceiptFormSection(title: "Category") {
                        Picker("Category", selection: $model.category) {
                            Text("Trip").tag(MobileGroup.Category.trip)
                            Text("Home").tag(MobileGroup.Category.home)
                            Text("Couple").tag(MobileGroup.Category.couple)
                            Text("Work").tag(MobileGroup.Category.work)
                            Text("Other").tag(MobileGroup.Category.other)
                        }
                    }

                    InlineErrorText(message: model.errorMessage)

                    PrimaryButton(title: "Create trip", systemImage: "receipt", isLoading: model.isSaving) {
                        Task {
                            if let trip = await model.create() {
                                onCreated(trip)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Create Trip")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}

struct TripDashboardView: View {
    @State var model: TripDashboardViewModel
    let container: DataContainer
    let openFinalBill: () -> Void
    @State private var showingExpense: ExpenseEditorContext?
    @State private var confirmingFinalize = false

    var body: some View {
        Group {
            if model.isLoading && model.detail == nil {
                LoadingReceiptView()
            } else if let error = model.errorMessage, model.detail == nil {
                ErrorReceiptView(message: error) {
                    Task { await model.load() }
                }
            } else if let trip = model.trip {
                content(trip)
            } else {
                ErrorReceiptView(message: "We could not load this trip.") {
                    Task { await model.load() }
                }
            }
        }
        .navigationTitle(model.trip?.name ?? "Trip")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let trip = model.trip {
                    Button {
                        openFinalBill()
                    } label: {
                        Image(systemName: trip.status == .finalized ? "doc.text.fill" : "doc.text")
                    }
                    .accessibilityLabel("Open final bill")
                }
            }
        }
        .sheet(item: $showingExpense) { context in
            NavigationStack {
                AddEditExpenseView(
                    model: ExpenseEditorViewModel(
                        expenseRepository: container.expenseRepository,
                        trip: context.trip,
                        currentUserId: context.currentUserId,
                        existingExpense: context.expense
                    )
                ) {
                    showingExpense = nil
                    Task { await model.load() }
                }
            }
        }
        .confirmationDialog("Finalize this trip?", isPresented: $confirmingFinalize, titleVisibility: .visible) {
            Button("Finalize trip") {
                Task {
                    await model.finalize()
                    openFinalBill()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finalizing is one-way in the current backend. Expenses and members will be locked.")
        }
        .task {
            await model.load()
        }
    }

    private func content(_ trip: Trip) -> some View {
        @Bindable var model = model

        return ReceiptScroll {
            ReceiptCard(eyebrow: trip.status == .finalized ? "Finalized trip" : "Live trip", title: trip.name, subtitle: "\(trip.participants.count) members") {
                VStack(alignment: .leading, spacing: BBSpacing.md) {
                    if trip.status == .finalized {
                        StampBadge(text: "Finalized", systemImage: "checkmark.seal.fill", tone: BBColor.success)
                        Text("Reopening is not available yet.")
                            .font(BBFont.bodyRounded(size: 13, relativeTo: .caption))
                            .foregroundStyle(BBColor.textFaded)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(trip.participants) { participant in
                                ParticipantChip(name: participant.displayName, initials: participant.initials, isSelected: participant.kind == .currentUser)
                            }
                        }
                    }

                    if !model.isFinalized {
                        ReceiptFormSection(title: "Add member", subtitle: "The backend adds existing users by exact email.") {
                            HStack(spacing: BBSpacing.sm) {
                                ReceiptTextField(title: "Email", text: $model.memberEmail, keyboardType: .emailAddress, textContentType: .emailAddress)
                                Button {
                                    Task { await model.addMember() }
                                } label: {
                                    Image(systemName: "person.badge.plus")
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(BBSecondaryButtonStyle())
                                .accessibilityLabel("Add member")
                            }
                        }
                    }
                }
            }

            InlineErrorText(message: model.errorMessage)

            ReceiptCard(eyebrow: "Spend", title: "Totals") {
                AmountRow(title: "Trip spend", amount: model.totalSpend, subtitle: "ALL EXPENSES")
                AmountRow(title: "Per-person average", amount: model.perPersonSpend, subtitle: "SIMPLE AVERAGE")
            }

            ReceiptCard(eyebrow: "Ledger", title: "Expenses") {
                VStack(spacing: BBSpacing.sm) {
                    if model.expenses.isEmpty {
                        EmptyState(mascot: .ledger, title: "No expenses yet", message: "Add the first bill and the ledger will start balancing.")
                    } else {
                        ForEach(model.expenses) { expense in
                            ExpenseRow(expense: expense, participants: trip.participants) {
                                showingExpense = ExpenseEditorContext(trip: trip, expense: expense)
                            }
                            PerforationDivider()
                        }
                    }

                    if !model.isFinalized {
                        PrimaryButton(title: "Add expense", systemImage: "plus") {
                            showingExpense = ExpenseEditorContext(trip: trip, expense: nil)
                        }
                    } else {
                        Text("Finalized trips do not accept expense changes.")
                            .font(BBFont.bodyRounded(size: 13, relativeTo: .caption))
                            .foregroundStyle(BBColor.textFaded)
                    }
                }
            }

            balancesCard(trip)
            settlementsCard(trip)

            if !model.isFinalized {
                SecondaryButton(title: "Finalize trip", systemImage: "checkmark.seal") {
                    confirmingFinalize = true
                }
            }

            PrimaryButton(title: "Final bill", systemImage: "square.and.arrow.up") {
                openFinalBill()
            }
        }
        .refreshable {
            await model.load()
        }
    }

    private func balancesCard(_ trip: Trip) -> some View {
        ReceiptCard(eyebrow: "Balances", title: "Who stands where") {
            VStack(spacing: BBSpacing.sm) {
                if model.settlementSummary?.balances.isEmpty != false {
                    EmptyState(mascot: .thinking, title: "All square", message: "No balances to settle yet.")
                } else {
                    ForEach(model.settlementSummary?.balances ?? [], id: \.participantId) { balance in
                        BalanceRow(
                            name: participantName(balance.participantId, in: trip.participants),
                            net: balance.net,
                            detail: balance.net.minorUnits >= 0 ? "GETS BACK" : "OWES"
                        )
                    }
                }
            }
        }
    }

    private func settlementsCard(_ trip: Trip) -> some View {
        ReceiptCard(eyebrow: "Settle", title: "Suggested payments", subtitle: "Tap a row when you have recorded the payment.") {
            VStack(spacing: BBSpacing.sm) {
                if model.settlementSummary?.simplifiedInstructions.isEmpty != false {
                    EmptyState(mascot: .badge, title: "No payments needed", message: "The trip is balanced.")
                } else {
                    ForEach(model.settlementSummary?.simplifiedInstructions ?? [], id: \.self) { instruction in
                        SettlementRow(
                            payerName: participantName(instruction.from, in: trip.participants),
                            recipientName: participantName(instruction.to, in: trip.participants),
                            amount: instruction.amount
                        ) {
                            Task { await model.record(instruction) }
                        }
                    }
                }
            }
        }
    }
}

struct ExpenseRow: View {
    let expense: Expense
    let participants: [TripParticipant]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: BBSpacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(expense.title)
                        .font(BBFont.handwriting(size: 25, relativeTo: .title3))
                        .foregroundStyle(BBColor.textPrimary)
                    Text("\(participantName(expense.paidBy, in: participants)) · \(expense.category) · \(expense.date.receiptDate)")
                        .font(BBFont.label(size: 10, relativeTo: .caption2))
                        .tracking(BBTracking.value(BBTracking.monoLabel, for: 10))
                        .foregroundStyle(BBColor.textFaded)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(expense.amount.formatted())
                    .font(BBFont.amount(size: 16, relativeTo: .headline))
                    .foregroundStyle(BBColor.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ExpenseEditorContext: Identifiable {
    let id = UUID()
    let trip: Trip
    let expense: Expense?

    var currentUserId: ParticipantID? {
        trip.participants.first(where: { $0.kind == .currentUser })?.id
    }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
