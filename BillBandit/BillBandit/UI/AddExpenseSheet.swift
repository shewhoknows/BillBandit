import SwiftUI
import SwiftData
import UIKit
import Foundation

/// Add expense — mockup B4 layout. Supports equal / exact / % / shares splits.
struct AddExpenseSheet: View {
    private enum FocusedField: Hashable { case amount, title }

    @Query(sort: \Group.createdAt, order: .reverse) private var groups: [Group]
    @Query(sort: \Person.name) private var people: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var title = ""
    @State private var category: ExpenseCategory = .food
    @State private var group: Group?
    @State private var paidBy: Person?
    @State private var mode: SplitMode = .equal
    @State private var inputs: [UUID: String] = [:] // per-person values for exact/%/shares
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isSubmitting = false
    @State private var activeOperationID: UUID?
    @FocusState private var focusedField: FocusedField?

    private let editingExpense: Expense?

    private let controlOutlineWidth = BrandOutline.control

    private var participants: [Person] {
        let source = group?.members ?? people
        return source.sorted {
            if $0.isCurrentUser != $1.isCurrentUser { return $0.isCurrentUser }
            return $0.name < $1.name
        }
    }

    private var parsedAmount: Decimal? {
        guard let d = Money.parseInput(amountText) else { return nil }
        return d > 0 ? d : nil
    }

    private var you: Person? { people.first { $0.isCurrentUser } }

    init(initialGroup: Group? = nil, editingExpense: Expense? = nil) {
        self.editingExpense = editingExpense
        _amountText = State(initialValue: editingExpense.map { Money.inputString($0.amount) } ?? "")
        _title = State(initialValue: editingExpense?.title ?? "")
        _category = State(initialValue: editingExpense?.category ?? .food)
        _group = State(initialValue: editingExpense?.group ?? initialGroup)
        _paidBy = State(initialValue: editingExpense?.paidBy)
        let initialMode = editingExpense?.splits.first?.mode ?? .equal
        _mode = State(initialValue: initialMode)
        var initialInputs = [UUID: String]()
        if initialMode != .equal, let expense = editingExpense {
            for split in expense.splits {
                guard let person = split.person else { continue }
                initialInputs[person.id] = NSDecimalNumber(decimal: split.value).stringValue
            }
        }
        _inputs = State(initialValue: initialInputs)
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: editingExpense == nil ? "Add expense" : "Edit expense") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    amountHero
                    titleField
                    categorySection
                    groupRow
                    paidByRow
                    splitSection
                    if let errorMessage {
                        Text(errorMessage)
                            .font(BrandFont.type(10, bold: true))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("expenseMutationError")
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(BrandFont.type(10, bold: true))
                            .foregroundStyle(Color.Brand.cobalt.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("expenseMutationStatus")
                    }
                    saveButton
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 650, alignment: .top)
            }
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .onAppear { if paidBy == nil { paidBy = you } }
        .onChange(of: people.count) {
            if paidBy == nil { paidBy = you }
        }
    }

    // MARK: sections

    private var amountHero: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Money.symbol)
                        .font(BrandFont.display(29, weight: .bold))
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                        .accessibilityIdentifier("expenseAmountField")
                        .font(BrandFont.display(42, weight: .bold))
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(Color.Brand.cobalt)
                BrandSquiggle()
                    .stroke(Color.Brand.cobalt, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: 76, height: 10)
            }
            Spacer(minLength: 4)
            ThinkingBlinkMascotView(size: 88)
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.bottom, -12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleField: some View {
        HStack(spacing: 10) {
            BrandIconView(icon: .receipti, size: 17).foregroundStyle(Color.Brand.cobalt)
            TextField("What was it for?", text: $title)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($focusedField, equals: .title)
                .onSubmit { focusedField = nil }
                .accessibilityIdentifier("expenseTitleField")
                .font(BrandFont.type(14.5, bold: true))
                .foregroundStyle(Color.Brand.cobalt)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                .foregroundStyle(Color.Brand.cobalt.opacity(0.5)).frame(height: 2)
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionLabel("CATEGORY")
            HStack(spacing: 2) {
                ForEach(ExpenseCategory.allCases, id: \.self) { cat in
                    Button { category = cat } label: {
                        BrandIconView(icon: cat.icon, size: 19)
                            .foregroundStyle(category == cat ? Color.Brand.creamSoft : Color.Brand.cobalt)
                            .frame(width: 36, height: 36)
                            .background(category == cat ? Color.Brand.cobalt : .clear, in: Circle())
                            .overlay(Circle().strokeBorder(Color.Brand.cobalt, lineWidth: controlOutlineWidth))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var groupRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionLabel("GROUP")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    segmentChip("None", on: group == nil) { selectGroup(nil) }
                    ForEach(groups) { g in
                        segmentChip(g.name, on: group?.id == g.id) { selectGroup(g) }
                    }
                }
                .padding(2)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.Brand.cobalt, lineWidth: controlOutlineWidth))
        }
    }

    private var paidByRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionLabel("PAID BY")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(participants, id: \.id) { p in
                        segmentChip(compactName(p), on: paidBy?.id == p.id) { paidBy = p }
                    }
                }
                .padding(2)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.Brand.cobalt, lineWidth: controlOutlineWidth))
        }
    }

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionLabel("SPLIT TYPE")
            HStack(spacing: 0) {
                ForEach(SplitMode.allCases, id: \.self) { m in
                    Button { mode = m } label: {
                        Text(m.label)
                            .font(BrandFont.body(11, weight: .extraBold))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(mode == m ? Color.Brand.cobalt : .clear)
                            .foregroundStyle(mode == m ? Color.Brand.creamSoft : Color.Brand.cobalt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.Brand.cobalt, lineWidth: controlOutlineWidth))

            if mode != .equal {
                ForEach(participants, id: \.id) { p in
                    HStack {
                        Text(p.name).font(BrandFont.type(12)).foregroundStyle(Color.Brand.cobalt)
                        Spacer()
                        TextField(mode == .percent ? "%" : (mode == .shares ? "1" : "0.00"),
                                  text: Binding(get: { inputs[p.id] ?? "" },
                                                set: { inputs[p.id] = $0 }))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(BrandFont.type(12, bold: true))
                            .foregroundStyle(Color.Brand.cobalt)
                            .frame(width: 80)
                    }
                }
            } else {
                Text(equalSplitSummary)
                    .font(BrandFont.type(11.5, bold: true))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.75))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var saveButton: some View {
        Button(action: save) {
            Text(isSubmitting ? "Saving…" : (editingExpense == nil ? "Save expense" : "Save changes"))
                .font(BrandFont.display(15.5))
                .foregroundStyle(Color.Brand.creamSoft)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.Brand.cobalt)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("saveExpenseButton")
        .disabled(isSubmitting || parsedAmount == nil || title.trimmingCharacters(in: .whitespaces).isEmpty || paidBy == nil)
        .opacity((isSubmitting || parsedAmount == nil || title.trimmingCharacters(in: .whitespaces).isEmpty || paidBy == nil) ? 0.5 : 1)
    }

    // MARK: helpers

    private func segmentChip(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(BrandFont.body(11, weight: .extraBold))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(on ? Color.Brand.cobalt : .clear)
                .foregroundStyle(on ? Color.Brand.creamSoft : Color.Brand.cobalt)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var equalSplitSummary: String {
        guard let total = parsedAmount, !participants.isEmpty else {
            return "\(participants.count) people · splits evenly"
        }
        let splitInputs = participants.map { SplitInput(personID: $0.id, mode: .equal) }
        guard let values = try? SplitEngine.compute(total: total, inputs: splitInputs).values,
              let low = values.min(), let high = values.max() else {
            return "\(participants.count) people · whole-rupee split"
        }
        if low == high { return "\(participants.count) people · \(Money.currency(low)) each" }
        return "\(participants.count) people · \(Money.currency(low))–\(Money.currency(high)) each"
    }

    private func selectGroup(_ selection: Group?) {
        group = selection
        guard let payer = paidBy, !participants.contains(where: { $0.id == payer.id }) else { return }
        paidBy = participants.first(where: { $0.isCurrentUser }) ?? participants.first
    }

    private func compactName(_ person: Person) -> String {
        if person.isCurrentUser { return "You" }
        return person.name.split(separator: " ").first.map(String.init) ?? person.name
    }

    private func save() {
        guard let amount = parsedAmount, let payer = paidBy else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces).capitalizingFirstLetter
        guard !trimmedTitle.isEmpty else { return }
        guard !isSubmitting else { return }

        var splitInputs = [SplitInput]()
        switch mode {
        case .equal:
            splitInputs = participants.map { SplitInput(personID: $0.id, mode: .equal) }
        case .exact, .percent, .shares:
            for p in participants {
                let v = Money.parseInput(inputs[p.id] ?? "") ?? 0
                splitInputs.append(SplitInput(personID: p.id, mode: mode, value: v))
            }
        }

        do {
            let computed = try SplitEngine.compute(total: amount, inputs: splitInputs)
            let splits = participants.compactMap { p -> Split? in
                guard let amt = computed[p.id] else { return nil }
                return Split(mode: mode,
                             value: Money.parseInput(inputs[p.id] ?? "0") ?? 0,
                             computedAmount: amt, person: p)
            }
            if let selectedGroup = group, selectedGroup.serverLedgerGroupID != nil {
                saveSharedExpense(
                    amount: amount,
                    title: trimmedTitle,
                    payer: payer,
                    computed: computed,
                    group: selectedGroup
                )
            } else {
                saveLocalExpense(
                    amount: amount,
                    title: trimmedTitle,
                    payer: payer,
                    splits: splits
                )
            }
        } catch let e as SplitError {
            switch e {
            case .exactMismatch(let expected, let got):
                errorMessage = "exact amounts add up to \(Money.string(got)), not \(Money.string(expected))"
            case .percentNot100(let p):
                errorMessage = "percentages add up to \(Money.string(p))%, not 100%"
            case .nonPositiveShares:
                errorMessage = "give at least one person a share"
            default:
                errorMessage = "check the amounts"
            }
        } catch {
            errorMessage = "couldn't save that expense"
        }
    }

    private func saveLocalExpense(
        amount: Decimal,
        title: String,
        payer: Person,
        splits: [Split]
    ) {
        let roundedAmount = Money.whole(amount)
        let expense: Expense
        var rewardOutcome: RewardOutcome?
        if let existing = editingExpense {
            let oldGroup = existing.group
            if oldGroup?.id != group?.id {
                oldGroup?.expenses.removeAll { $0.id == existing.id }
            }
            let oldSplits = existing.splits
            existing.splits.removeAll()
            for oldSplit in oldSplits { context.delete(oldSplit) }
            existing.title = title
            existing.amount = roundedAmount
            existing.categoryRaw = category.rawValue
            existing.group = group
            existing.paidBy = payer
            existing.splits = splits
            expense = existing
            let actorName = you?.name ?? "You"
            context.insert(ActivityItem(kind: .expenseEdited,
                                        summary: "\(actorName) updated “\(title)”",
                                        refID: existing.id, actorID: you?.id,
                                        groupID: group?.id, groupName: group?.name))
            if let currentUser = you {
                try? AchievementEngine.unlock(.highOnDetails, personID: currentUser.id,
                                              context: context)
            }
        } else {
            expense = Expense(title: title, amount: roundedAmount,
                              category: category, group: group, paidBy: payer, splits: splits)
            context.insert(expense)
            let actorName = you?.name ?? "You"
            context.insert(ActivityItem(kind: .expenseAdded,
                                        summary: "\(actorName) added “\(title)”",
                                        refID: expense.id, actorID: you?.id,
                                        groupID: group?.id, groupName: group?.name))
            if let currentUser = you {
                rewardOutcome = try? RewardEngine.award(
                    action: .expenseAdded, eventID: expense.id,
                    personID: currentUser.id, context: context
                )
            }
        }
        for split in splits {
            split.expense = expense
            context.insert(split)
        }
        if let selectedGroup = group,
           !selectedGroup.expenses.contains(where: { $0.id == expense.id }) {
            selectedGroup.expenses.append(expense)
        }
        if let currentUser = you {
            try? AchievementEngine.evaluateExpenseMilestones(personID: currentUser.id,
                                                              context: context)
        }
        do {
            try context.save()
            if let selectedGroup = group {
                CloudCollaborationService.shared.groupDidChange(selectedGroup)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            if let rewardOutcome {
                RewardFeedbackCenter.shared.present(rewardOutcome)
            }
        } catch {
            errorMessage = "couldn't save that expense"
        }
    }

    @MainActor
    private func saveSharedExpense(
        amount: Decimal,
        title: String,
        payer: Person,
        computed: [UUID: Decimal],
        group: Group
    ) {
        guard let rawServerGroupID = group.serverLedgerGroupID else { return }
        let operationID = activeOperationID ?? UUID()
        activeOperationID = operationID
        isSubmitting = true
        errorMessage = nil
        statusMessage = "Preparing a canonical shared-ledger mutation…"

        Task { @MainActor in
            var queued = false
            do {
                let remoteUser = try await T15CanonicalLedgerRuntime.shared.authenticatedUser()
                let scope = ServerBackedLedgerScope(
                    accountID: remoteUser.id,
                    groupID: rawServerGroupID
                )
                let cachedOrFresh = try await T15CanonicalLedgerRuntime.shared.cachedOrRefresh(scope: scope)
                let canonicalGroup = try T15CanonicalLedgerRuntime.shared.validatedGroup(
                    from: cachedOrFresh,
                    scope: scope
                )
                guard canonicalGroup.baseCurrency.currencyCode == Money.currentCurrency.rawValue else {
                    throw T15LedgerUIError.unsupportedSharedCurrency(canonicalGroup.baseCurrency.currencyCode)
                }
                guard canonicalGroup.members.contains(where: {
                    $0.accountID == remoteUser.id && $0.status == "active"
                }) else {
                    throw T15LedgerUIError.memberIdentityUnavailable("You")
                }

                let editingID = editingExpense?.id.uuidString
                if let editingID,
                   !canonicalGroup.expenses.contains(where: { $0.expenseID == editingID }) {
                    throw T15LedgerUIError.expenseNotInCanonicalSnapshot
                }
                let expenseID = editingID ?? operationID.uuidString
                let body = try makeSharedExpenseBody(
                    amount: amount,
                    title: title,
                    payer: payer,
                    computed: computed,
                    canonicalGroup: canonicalGroup,
                    accountID: remoteUser.id,
                    expenseID: expenseID,
                    operationID: operationID
                )
                let isEdit = editingID != nil
                let path = isEdit
                    ? "/api/mobile/expenses/\(expenseID)"
                    : "/api/mobile/expenses"
                try T15CanonicalLedgerRuntime.shared.enqueueExpense(
                    operationID: operationID,
                    scope: scope,
                    expectedRevision: cachedOrFresh.revision,
                    kind: isEdit ? "expense.edit" : "expense.create",
                    method: isEdit ? "PUT" : "POST",
                    path: path,
                    body: body
                )
                queued = true
                statusMessage = "Saved to the durable queue. Reconciling the canonical ledger…"

                let canonicalSnapshot = try await T15CanonicalLedgerRuntime.shared.reconcile(scope: scope)
                let reconciledGroup = try T15CanonicalLedgerRuntime.shared.validatedGroup(
                    from: canonicalSnapshot,
                    scope: scope
                )
                guard let reconciledExpense = reconciledGroup.expenses.first(where: {
                    $0.expenseID == expenseID && $0.status == "active"
                }), reconciledExpense.amount.minorUnits == body.amount.minorUnits else {
                    throw T15LedgerUIError.canonicalSnapshotUnavailable
                }

                let groupForRefresh = group
                Task { @MainActor in
                    await ServerLedgerSurfaceStore.shared.refresh(groups: [groupForRefresh])
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isSubmitting = false
                activeOperationID = nil
                statusMessage = nil
                dismiss()
            } catch {
                if queued && T15LedgerUIError.isOffline(error) {
                    // The row remains retryable with the same operation ID;
                    // never create a second local expense as a fallback.
                    isSubmitting = true
                    errorMessage = nil
                    statusMessage = "Offline. This shared expense is queued and will retry when the connection returns."
                    return
                }
                if queued && T15LedgerUIError.isUnauthorized(error) {
                    isSubmitting = true
                    errorMessage = nil
                    statusMessage = "Your session expired. Re-authenticate; this shared expense remains queued."
                    return
                }
                if queued && T15LedgerUIError.isConflict(error) {
                    isSubmitting = false
                    activeOperationID = nil
                    errorMessage = T15LedgerUIError.message(for: error, fallback: "The shared ledger changed.")
                    statusMessage = "Refresh the canonical snapshot, then confirm the expense again before retrying."
                    return
                }
                if queued {
                    // Keep the same operation ID attached to the durable row
                    // until the user explicitly resolves the visible state.
                    // A second tap must never create a competing mutation.
                    isSubmitting = true
                    errorMessage = T15LedgerUIError.message(
                        for: error,
                        fallback: "The shared expense remains queued."
                    )
                    statusMessage = "The durable operation was not replayed in this sheet. Reconnect or refresh before trying again."
                    return
                }
                isSubmitting = false
                activeOperationID = nil
                errorMessage = T15LedgerUIError.message(for: error, fallback: "Could not save that shared expense.")
                statusMessage = nil
            }
        }
    }

    private func makeSharedExpenseBody(
        amount: Decimal,
        title: String,
        payer: Person,
        computed: [UUID: Decimal],
        canonicalGroup: SettlementCanonicalLedgerGroup,
        accountID: String,
        expenseID: String,
        operationID: UUID
    ) throws -> Data {
        let payerMemberID = try canonicalMemberID(
            for: payer,
            canonicalGroup: canonicalGroup,
            accountID: accountID
        )
        let money = try canonicalMoney(
            Money.whole(amount),
            currencyCode: canonicalGroup.baseCurrency.currencyCode,
            currencyExponent: canonicalGroup.baseCurrency.currencyExponent
        )
        let encodedSplits = try participants.enumerated().map { index, person in
            let memberID = try canonicalMemberID(
                for: person,
                canonicalGroup: canonicalGroup,
                accountID: accountID
            )
            guard let computedAmount = computed[person.id] else {
                throw T15LedgerUIError.canonicalSnapshotUnavailable
            }
            let input = Money.parseInput(inputs[person.id] ?? "") ?? 0
            let percentage: Double?
            let shares: Int?
            switch mode {
            case .percent:
                percentage = NSDecimalNumber(decimal: input).doubleValue
                shares = nil
            case .shares:
                let whole = Money.whole(input)
                guard whole == input,
                      let parsedShares = Int(NSDecimalNumber(decimal: whole).stringValue),
                      parsedShares > 0 else {
                    throw T15LedgerUIError.nonIntegralShares
                }
                percentage = nil
                shares = parsedShares
            case .equal, .exact:
                percentage = nil
                shares = nil
            }
            return T15ExpenseSplitMutation(
                splitId: "\(expenseID)-\(index)-\(memberID)",
                memberId: memberID,
                amount: try canonicalMoney(
                    computedAmount,
                    currencyCode: canonicalGroup.baseCurrency.currencyCode,
                    currencyExponent: canonicalGroup.baseCurrency.currencyExponent
                ),
                percentage: percentage,
                shares: shares
            )
        }
        let body = T15ExpenseMutationBody(
            kind: editingExpense == nil ? "expense.create" : "expense.edit",
            groupId: canonicalGroup.groupID,
            expenseId: expenseID,
            paidByMemberId: payerMemberID,
            description: title,
            amount: money,
            currency: canonicalGroup.baseCurrency.currencyCode,
            date: serverDate(editingExpense?.date ?? .now),
            category: category.rawValue,
            splitMethod: mode.serverValue,
            splits: encodedSplits,
            notes: editingExpense?.notes.isEmpty == false ? editingExpense?.notes : nil,
            operationId: operationID.uuidString
        )
        return try JSONEncoder.serverLedger.encode(body)
    }

    private func canonicalMemberID(
        for person: Person,
        canonicalGroup: SettlementCanonicalLedgerGroup,
        accountID: String
    ) throws -> String {
        if let localIdentityID = canonicalGroup.members.first(where: {
            guard let raw = $0.localIdentityID else { return false }
            return UUID(uuidString: raw) == person.id
        })?.memberID {
            return localIdentityID
        }
        if person.isCurrentUser,
           let current = canonicalGroup.members.first(where: { $0.accountID == accountID }) {
            return current.memberID
        }
        throw T15LedgerUIError.memberIdentityUnavailable(person.name)
    }

    private func canonicalMoney(
        _ amount: Decimal,
        currencyCode: String,
        currencyExponent: Int
    ) throws -> ServerLedgerMoneyDTO {
        let decimalString = NSDecimalNumber(decimal: Money.whole(amount)).stringValue
        let minorUnits = SettlementMoneyFormatting.minorUnits(
            from: decimalString,
            exponent: currencyExponent
        )
        guard ServerLedgerMoneyDTO.isCanonicalMinorUnits(minorUnits) else {
            throw ServerLedgerDTOError.nonCanonicalMinorUnits(path: "amount.minorUnits")
        }
        return ServerLedgerMoneyDTO(
            minorUnits: minorUnits,
            currencyCode: currencyCode,
            currencyExponent: currencyExponent
        )
    }

    private func serverDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension SplitMode {
    var serverValue: String {
        switch self {
        case .equal: return "EQUAL"
        case .exact: return "EXACT"
        case .percent: return "PERCENTAGE"
        case .shares: return "SHARES"
        }
    }
}

private struct T15ExpenseSplitMutation: Encodable {
    let splitId: String
    let memberId: String
    let amount: ServerLedgerMoneyDTO
    let percentage: Double?
    let shares: Int?
}

private struct T15ExpenseMutationBody: Encodable {
    let kind: String
    let groupId: String
    let expenseId: String
    let paidByMemberId: String
    let description: String
    let amount: ServerLedgerMoneyDTO
    let currency: String
    let date: String
    let category: String
    let splitMethod: String
    let splits: [T15ExpenseSplitMutation]
    let notes: String?
    let operationId: String
}

/// Shared full-screen modal header. Keeping this in SwiftUI avoids system sheet chrome.
struct BrandModalHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Button(action: close) {
                BrandIconView(icon: .x, size: 16)
                    .foregroundStyle(Color.Brand.cobalt)
                    .frame(width: 42, height: 42)
                    .background(Color.Brand.creamSoft, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
            Spacer()
            Text(title)
                .font(BrandFont.display(17, weight: .semibold))
                .foregroundStyle(Color.Brand.creamSoft)
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }
}

struct BrandSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(BrandFont.body(10, weight: .extraBold))
            .tracking(1.8)
            .foregroundStyle(Color.Brand.cobalt.opacity(0.6))
    }
}

struct BrandSquiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addCurve(to: CGPoint(x: rect.width * 0.5, y: rect.midY),
                      control1: CGPoint(x: rect.width * 0.16, y: 0),
                      control2: CGPoint(x: rect.width * 0.34, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.midY),
                      control1: CGPoint(x: rect.width * 0.66, y: 0),
                      control2: CGPoint(x: rect.width * 0.84, y: rect.height))
        return path
    }
}
