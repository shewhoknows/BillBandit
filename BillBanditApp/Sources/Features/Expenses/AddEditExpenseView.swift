import SwiftUI

enum ExpenseSplitKind: String, CaseIterable, Identifiable {
    case equal = "Equal"
    case exact = "Exact"
    case percentages = "Percent"
    case shares = "Shares"
    case payerOnly = "Payer only"

    var id: String { rawValue }
}

@MainActor
@Observable
final class ExpenseEditorViewModel {
    private let expenseRepository: any ExpenseRepository
    let trip: Trip
    let currentUserId: ParticipantID?
    let existingExpense: Expense?
    let isTripFinalized: Bool

    var title = ""
    var amountText = ""
    var paidBy: ParticipantID
    var date = Date()
    var category = "general"
    var notes = ""
    var includedParticipants: Set<ParticipantID>
    var splitKind: ExpenseSplitKind = .equal
    var exactTexts: [ParticipantID: String] = [:]
    var percentageTexts: [ParticipantID: String] = [:]
    var shareTexts: [ParticipantID: String] = [:]
    var isSaving = false
    var errorMessage: String?

    init(
        expenseRepository: any ExpenseRepository,
        trip: Trip,
        currentUserId: ParticipantID?,
        existingExpense: Expense?,
        isTripFinalized: Bool = false
    ) {
        self.expenseRepository = expenseRepository
        self.trip = trip
        self.currentUserId = currentUserId
        self.existingExpense = existingExpense
        self.isTripFinalized = isTripFinalized
        self.paidBy = existingExpense?.paidBy ?? currentUserId ?? trip.participants.first?.id ?? ""
        self.includedParticipants = Set(existingExpense?.includedParticipants ?? trip.participants.map(\.id))

        if let existingExpense {
            title = existingExpense.title
            amountText = existingExpense.amount.majorUnits.plainString
            date = existingExpense.date
            category = existingExpense.category
            notes = existingExpense.notes ?? ""
            switch existingExpense.splitMethod {
            case .equal:
                splitKind = .equal
            case .exactAmounts(let values):
                splitKind = .exact
                exactTexts = values.mapValues { $0.majorUnits.plainString }
            case .percentages(let values):
                splitKind = .percentages
                percentageTexts = values.mapValues(\.plainString)
            case .shares(let values):
                splitKind = .shares
                shareTexts = values.mapValues(String.init)
            case .payerOnly:
                splitKind = .payerOnly
            }
        }
        seedSplitFields()
    }

    var canMutateExistingExpense: Bool {
        guard !isTripFinalized else { return false }
        guard let existingExpense else { return true }
        return existingExpense.paidBy == currentUserId
    }

    var saveTitle: String {
        existingExpense == nil ? "Save expense" : "Update expense"
    }

    func participantName(_ id: ParticipantID) -> String {
        trip.participants.first(where: { $0.id == id })?.displayName ?? "Someone"
    }

    func toggleParticipant(_ id: ParticipantID) {
        if includedParticipants.contains(id) {
            includedParticipants.remove(id)
        } else {
            includedParticipants.insert(id)
        }
        if splitKind == .payerOnly {
            includedParticipants = [paidBy]
        }
        seedSplitFields()
        validateLive()
    }

    func setSplitKind(_ kind: ExpenseSplitKind) {
        splitKind = kind
        if kind == .payerOnly {
            includedParticipants = [paidBy]
        } else if includedParticipants.isEmpty {
            includedParticipants = Set(trip.participants.map(\.id))
        }
        seedSplitFields()
        validateLive()
    }

    func payerChanged() {
        if splitKind == .payerOnly {
            includedParticipants = [paidBy]
        }
        validateLive()
    }

    func validateLive() {
        do {
            _ = try makeExpense()
            errorMessage = nil
        } catch {
            errorMessage = errorMessage(for: error)
        }
    }

    func save() async -> Bool {
        guard canMutateExistingExpense else {
            errorMessage = isTripFinalized ? "This trip is finalized, so expenses are locked." : "Only the current payer can edit this expense."
            return false
        }
        let expense: Expense
        do {
            expense = try makeExpense()
        } catch {
            errorMessage = errorMessage(for: error)
            return false
        }
        isSaving = true
        errorMessage = nil
        do {
            if let existingExpense {
                _ = try await expenseRepository.update(id: existingExpense.id, groupId: trip.id, expense: expense)
            } else {
                _ = try await expenseRepository.create(groupId: trip.id, expense: expense)
            }
            isSaving = false
            return true
        } catch {
            errorMessage = error.billBanditMessage
            isSaving = false
            return false
        }
    }

    func delete() async -> Bool {
        guard let existingExpense, canMutateExistingExpense else {
            errorMessage = isTripFinalized ? "This trip is finalized, so expenses are locked." : "Only the current payer can delete this expense."
            return false
        }
        isSaving = true
        errorMessage = nil
        do {
            try await expenseRepository.delete(id: existingExpense.id)
            isSaving = false
            return true
        } catch {
            errorMessage = error.billBanditMessage
            isSaving = false
            return false
        }
    }

    private func seedSplitFields() {
        for participant in trip.participants {
            _ = exactTexts[participant.id, default: ""]
            _ = percentageTexts[participant.id, default: ""]
            _ = shareTexts[participant.id, default: "1"]
        }
    }

    private func makeExpense() throws -> Expense {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw FormError.message("Add a title for the receipt.") }
        guard let amount = moneyFromMajorText(amountText, currency: trip.currency), amount.minorUnits > 0 else {
            throw FormError.message("Enter an amount greater than zero.")
        }

        let included = Array(includedParticipants).sorted()
        let splitMethod: SplitMethod
        switch splitKind {
        case .equal:
            splitMethod = .equal
        case .payerOnly:
            splitMethod = .payerOnly
        case .exact:
            splitMethod = .exactAmounts(try moneyMap(from: exactTexts, included: included, currency: trip.currency))
        case .percentages:
            splitMethod = .percentages(try decimalMap(from: percentageTexts, included: included))
        case .shares:
            splitMethod = .shares(try shareMap(from: shareTexts, included: included))
        }

        let expense = Expense(
            id: existingExpense?.id ?? "expense-\(UUID().uuidString)",
            title: cleanTitle,
            amount: amount,
            paidBy: paidBy,
            date: date,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "general" : category,
            notes: notes.nilIfBlank,
            includedParticipants: splitKind == .payerOnly ? [paidBy] : included,
            splitMethod: splitMethod
        )
        try ExpenseValidation.validate(expense)
        return expense
    }

    private func moneyMap(from texts: [ParticipantID: String], included: [ParticipantID], currency: Currency) throws -> [ParticipantID: Money] {
        var values: [ParticipantID: Money] = [:]
        for id in included {
            guard let value = moneyFromMajorText(texts[id] ?? "", currency: currency) else {
                throw FormError.message("Enter exact amounts for every included person.")
            }
            values[id] = value
        }
        return values
    }

    private func decimalMap(from texts: [ParticipantID: String], included: [ParticipantID]) throws -> [ParticipantID: Decimal] {
        var values: [ParticipantID: Decimal] = [:]
        for id in included {
            guard let value = Decimal(string: texts[id] ?? "") else {
                throw FormError.message("Enter percentages for every included person.")
            }
            values[id] = value
        }
        return values
    }

    private func shareMap(from texts: [ParticipantID: String], included: [ParticipantID]) throws -> [ParticipantID: Int] {
        var values: [ParticipantID: Int] = [:]
        for id in included {
            guard let value = Int(texts[id] ?? ""), value > 0 else {
                throw FormError.message("Shares must be whole numbers above zero.")
            }
            values[id] = value
        }
        return values
    }

    private func errorMessage(for error: Error) -> String {
        if let formError = error as? FormError {
            return formError.message
        }
        if let validation = error as? ExpenseValidationError {
            switch validation {
            case .negativeAmount:
                return "Amounts cannot be negative."
            case .noIncludedParticipants:
                return "Include at least one person."
            case .duplicateParticipants:
                return "Each person can only appear once."
            case .exactAmountsDoNotMatchTotal(let expected, let actual):
                return "Exact splits add up to \(actual.formatted()), not \(expected.formatted())."
            case .percentagesDoNotSumTo100(let actual):
                return "Percentages add up to \(actual.plainString)%, not 100%."
            case .invalidShares:
                return "Shares must be whole numbers above zero."
            case .splitDefinitionsDoNotMatchParticipants:
                return "Split values must match the included people."
            }
        }
        return error.billBanditMessage
    }
}

struct AddEditExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: ExpenseEditorViewModel
    let onSaved: () -> Void

    var body: some View {
        @Bindable var model = model

        ReceiptScroll {
            ReceiptCard(eyebrow: model.existingExpense == nil ? "New bill" : "Edit bill", title: model.existingExpense == nil ? "Add expense" : "Expense details") {
                VStack(spacing: BBSpacing.lg) {
                    if !model.canMutateExistingExpense {
                        Text(model.isTripFinalized ? "This trip is finalized — expenses are locked." : "Only \(model.participantName(model.existingExpense?.paidBy ?? "")) can edit or delete this expense. You can still review the split.")
                            .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(BBColor.textFaded)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ReceiptFormSection(title: "Title") {
                        HandwrittenTextField(title: "Title", placeholder: "Dinner, taxis, snacks", text: $model.title)
                            .disabled(!model.canMutateExistingExpense)
                    }

                    ReceiptFormSection(title: "Amount") {
                        TextField("0.00", text: $model.amountText)
                            .keyboardType(.decimalPad)
                            .font(BBFont.amount(size: 28, relativeTo: .title2))
                            .foregroundStyle(BBColor.textPrimary)
                            .padding(.horizontal, BBSpacing.sm)
                            .frame(minHeight: 52)
                            .background(BBColor.cream.opacity(0.62), in: RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous)
                                    .stroke(BBColor.fieldBorder, style: BBBorder.field)
                            }
                            .disabled(!model.canMutateExistingExpense)
                            .onChange(of: model.amountText) { _, _ in model.validateLive() }
                    }

                    ReceiptFormSection(title: "Paid by") {
                        Picker("Paid by", selection: $model.paidBy) {
                            ForEach(model.trip.participants) { participant in
                                Text(participant.displayName).tag(participant.id)
                            }
                        }
                        .onChange(of: model.paidBy) { _, _ in model.payerChanged() }
                        .disabled(!model.canMutateExistingExpense)
                    }

                    ReceiptFormSection(title: "Date") {
                        DatePicker("Date", selection: $model.date, displayedComponents: .date)
                            .disabled(!model.canMutateExistingExpense)
                    }

                    ReceiptFormSection(title: "Category") {
                        HandwrittenTextField(title: "Category", placeholder: "food", text: $model.category)
                            .disabled(!model.canMutateExistingExpense)
                    }

                    ReceiptFormSection(title: "Notes") {
                        HandwrittenTextEditor(placeholder: "Optional notes", text: $model.notes, minHeight: 90)
                            .disabled(!model.canMutateExistingExpense)
                    }

                    ReceiptFormSection(title: "Included people") {
                        FlowLayout(spacing: BBSpacing.xs) {
                            ForEach(model.trip.participants) { participant in
                                ParticipantChip(
                                    name: participant.displayName,
                                    initials: participant.initials,
                                    isSelected: model.includedParticipants.contains(participant.id)
                                ) {
                                    model.toggleParticipant(participant.id)
                                }
                                .disabled(!model.canMutateExistingExpense || model.splitKind == .payerOnly)
                            }
                        }
                    }

                    ReceiptFormSection(title: "Split method") {
                        Picker("Split method", selection: Binding(
                            get: { model.splitKind },
                            set: { model.setSplitKind($0) }
                        )) {
                            ForEach(ExpenseSplitKind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.canMutateExistingExpense)

                        SplitEditor(model: model)
                    }

                    InlineErrorText(message: model.errorMessage)

                    if model.canMutateExistingExpense {
                        PrimaryButton(title: model.saveTitle, systemImage: "checkmark", isLoading: model.isSaving) {
                            Task {
                                if await model.save() {
                                    onSaved()
                                }
                            }
                        }

                        if model.existingExpense != nil {
                            Button(role: .destructive) {
                                Task {
                                    if await model.delete() {
                                        onSaved()
                                    }
                                }
                            } label: {
                                Label("Delete expense", systemImage: "trash")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(model.existingExpense == nil ? "Add Expense" : "Edit Expense")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}

struct SplitEditor: View {
    @Bindable var model: ExpenseEditorViewModel

    var body: some View {
        VStack(spacing: BBSpacing.sm) {
            switch model.splitKind {
            case .equal:
                Text("Everyone included gets an equal share.")
                    .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(BBColor.textFaded)
            case .payerOnly:
                Text("\(model.participantName(model.paidBy)) covers this one.")
                    .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(BBColor.textFaded)
            case .exact:
                splitRows(suffix: model.trip.currency.code, texts: $model.exactTexts, keyboard: .decimalPad)
            case .percentages:
                splitRows(suffix: "%", texts: $model.percentageTexts, keyboard: .decimalPad)
            case .shares:
                splitRows(suffix: "shares", texts: $model.shareTexts, keyboard: .numberPad)
            }
        }
    }

    private func splitRows(suffix: String, texts: Binding<[ParticipantID: String]>, keyboard: UIKeyboardType) -> some View {
        VStack(spacing: BBSpacing.xs) {
            ForEach(model.trip.participants.filter { model.includedParticipants.contains($0.id) }) { participant in
                HStack {
                    Text(participant.displayName)
                        .font(BBFont.bodyRounded(size: 14, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BBColor.textPrimary)
                    Spacer()
                    TextField("0", text: Binding(
                        get: { texts.wrappedValue[participant.id] ?? "" },
                        set: {
                            texts.wrappedValue[participant.id] = $0
                            model.validateLive()
                        }
                    ))
                    .keyboardType(keyboard)
                    .multilineTextAlignment(.trailing)
                    .font(BBFont.amount(size: 16, relativeTo: .headline))
                    .frame(width: 94)
                    .disabled(!model.canMutateExistingExpense)
                    Text(suffix)
                        .font(BBFont.label(size: 10, relativeTo: .caption2))
                        .foregroundStyle(BBColor.textFaded)
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private enum FormError: Error {
    case message(String)

    var message: String {
        switch self {
        case .message(let message):
            message
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
