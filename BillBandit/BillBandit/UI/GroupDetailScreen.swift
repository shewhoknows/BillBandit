import SwiftUI
import SwiftData
import UIKit

struct GroupDetailScreen: View {
    @Bindable var group: Group
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettle = false
    @State private var showAddExpense = false
    @State private var celebration: SettlementCelebration?
    @State private var invoiceRevealed = false
    @State private var expenseIDsBeforeAdd = Set<UUID>()
    @State private var freshExpenseID: UUID?
    @State private var revealFreshExpense = true
    @State private var balanceBreakdownExpanded = false

    init(group: Group) {
        self.group = group
        _showSettle = State(initialValue: ProcessInfo.processInfo.arguments.contains("-showSettle"))
    }

    private var sortedExpenses: [Expense] {
        group.expenses.sorted { $0.date > $1.date }
    }

    private var myNet: Decimal {
        guard let me = currentUsers.first else { return 0 }
        return BalanceMath.nets(in: group)[me.id] ?? 0
    }

    private var settlementPlan: [DebtTransfer] {
        BalanceMath.settleUpPlan(for: group)
    }

    private var total: Decimal {
        Money.cents(group.expenses.reduce(0) { $0 + $1.amount })
    }

    private var myPaid: Decimal {
        guard let me = currentUsers.first else { return 0 }
        return Money.cents(group.expenses.filter { $0.paidBy?.id == me.id }.reduce(0) { $0 + $1.amount })
    }

    private var myShare: Decimal {
        guard let me = currentUsers.first else { return 0 }
        return Money.cents(group.expenses.flatMap(\.splits).filter { $0.person?.id == me.id }.reduce(0) { $0 + $1.computedAmount })
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                groupMeta
                invoice
                VStack(spacing: 10) {
                    Button { beginAddingExpense() } label: {
                        Text("Add expense")
                            .font(BrandFont.display(15, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.Brand.creamSoft, in: Capsule())
                    }
                    .accessibilityIdentifier("groupAddExpenseButton")
                    Button { showSettle = true } label: {
                        Text(settlementPlan.isEmpty ? "All square" : "Settle up")
                            .font(BrandFont.display(15, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .overlay(Capsule().stroke(Color.Brand.creamSoft, lineWidth: 2))
                    }
                    .disabled(settlementPlan.isEmpty)
                    .opacity(settlementPlan.isEmpty ? 0.55 : 1)
                }
                .padding(.top, 18)

                Text(group.simplifyDebts ? "simplify debts: ON" : "simplify debts: OFF")
                    .font(BrandFont.type(10, bold: true))
                    .foregroundStyle(Color.Brand.creamSoft.opacity(0.7))
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
        .background(Color.Brand.cobalt)
        .navigationTitle(group.name)
        .fullScreenCover(isPresented: $showAddExpense, onDismiss: revealNewExpense) {
            AddExpenseSheet(initialGroup: group)
        }
        .fullScreenCover(isPresented: $showSettle) {
            RecordPaymentSheet(group: group) { result in
                celebration = result
            }
        }
        .fullScreenCover(item: $celebration) { result in
            SettlementCelebrationScreen(result: result) {
                celebration = nil
            }
        }
        .onAppear { revealInvoice() }
    }

    private var groupMeta: some View {
        HStack {
            Text("\(group.members.count) members · est. \(group.createdAt.formatted(.dateTime.month(.abbreviated).year()))")
                .font(BrandFont.type(10))
                .opacity(0.65)
            Spacer()
        }
        .foregroundStyle(Color.Brand.creamSoft)
        .padding(.top, 5)
        .padding(.bottom, 3)
    }

    private var invoice: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("BILLBANDIT & CO.")
                        .font(BrandFont.type(14, bold: true))
                        .tracking(1.3)
                    Text("EXPENSE REPORT #\(reportNumber) · \(Date.now.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())")
                        .font(BrandFont.type(9))
                        .opacity(0.58)
                        .padding(.top, 3)
                    DottedRule().padding(.vertical, 10)

                    if sortedExpenses.isEmpty {
                        VStack(spacing: 7) {
                            SleepingMascotSceneView(width: 225)
                                .accessibilityIdentifier("emptyGroupSleepingMascot")
                            Text("no expenses on this invoice")
                                .font(BrandFont.hand(19, weight: .bold))
                        }
                        .padding(.vertical, 10)
                    } else {
                        ForEach(sortedExpenses) { expense in
                            NavigationLink {
                                ExpenseDetailScreen(expense: expense)
                            } label: {
                                InvoiceExpenseRow(expense: expense)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(freshExpenseID == expense.id && !revealFreshExpense ? 0 : 1)
                            .scaleEffect(freshExpenseID == expense.id && !revealFreshExpense ? 0.96 : 1,
                                         anchor: .top)
                            .offset(y: freshExpenseID == expense.id && !revealFreshExpense ? -12 : 0)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                        .animation(reduceMotion ? nil : BrandMotion.revealSpring,
                                   value: sortedExpenses.map(\.id))
                    }

                    DottedRule().padding(.vertical, 9)
                    InvoiceLeaderRow(label: "TOTAL", amount: Money.currency(total),
                                     strong: true, animationValue: total)
                    Text("you paid \(Money.currency(myPaid)) · your share \(Money.currency(myShare))")
                        .font(BrandFont.type(9.5))
                        .opacity(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)

                    balanceStampControl

                    if balanceBreakdownExpanded, !balanceBreakdown.isEmpty {
                        balanceBreakdownPanel
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .background(Color.Brand.creamSoft)

                TornEdge()
                    .fill(Color.Brand.creamSoft)
                    .frame(height: 13)
            }
            .foregroundStyle(Color.Brand.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
            .scaleEffect(x: 1, y: invoiceRevealed ? 1 : 0.96, anchor: .top)
            .opacity(invoiceRevealed ? 1 : 0)

            if !sortedExpenses.isEmpty {
                MascotView(mascot: myNet < 0 ? .grumpy : (myNet == 0 ? .neutral : .confused), size: 66)
                    .offset(x: 8, y: -42)
            }
        }
        .padding(.top, 46)
    }

    private func beginAddingExpense() {
        expenseIDsBeforeAdd = Set(group.expenses.map(\.id))
        freshExpenseID = nil
        revealFreshExpense = true
        showAddExpense = true
    }

    private func revealNewExpense() {
        guard let newID = group.expenses.map(\.id).first(where: { !expenseIDsBeforeAdd.contains($0) }) else {
            return
        }
        freshExpenseID = newID
        revealFreshExpense = reduceMotion
        guard !reduceMotion else {
            freshExpenseID = nil
            return
        }
        DispatchQueue.main.async {
            withAnimation(BrandMotion.expenseReveal) {
                revealFreshExpense = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                freshExpenseID = nil
            }
        }
    }

    private func revealInvoice() {
        guard !invoiceRevealed else { return }
        withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
            invoiceRevealed = true
        }
    }

    private var reportNumber: String {
        String(format: "%04d", abs(group.id.hashValue) % 10_000)
    }

    private var balanceStamp: String {
        if myNet < 0 { return "YOU OWE \(Money.currency(-myNet))" }
        if myNet > 0 { return "OWED TO YOU \(Money.currency(myNet))" }
        return "ALL SQUARE"
    }

    @ViewBuilder
    private var balanceStampControl: some View {
        if balanceBreakdown.isEmpty {
            balanceStampLabel
        } else {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.48, dampingFraction: 0.86)) {
                    balanceBreakdownExpanded.toggle()
                }
            } label: {
                balanceStampLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("invoiceBalanceStamp")
            .accessibilityLabel(balanceBreakdownExpanded
                ? "\(balanceStamp), hide balance breakdown"
                : "\(balanceStamp), show balance breakdown")
        }
    }

    private var balanceStampLabel: some View {
        Text(balanceStamp)
            .font(BrandFont.type(15, bold: true))
            .tracking(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.Brand.cobalt, lineWidth: 2.2))
            .rotationEffect(.degrees(-2.5))
            .padding(.vertical, 11)
            .contentTransition(.numericText(value: NSDecimalNumber(decimal: myNet).doubleValue))
            .animation(reduceMotion ? nil : BrandMotion.counter, value: myNet)
    }

    private var balanceBreakdownPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            DottedRule()
                .padding(.bottom, 9)
            Text(myNet < 0 ? "WHO YOU OWE" : "WHO OWES YOU")
                .font(BrandFont.body(9.5, weight: .extraBold))
                .tracking(1.1)
                .padding(.bottom, 7)
            ForEach(balanceBreakdown) { line in
                InvoiceLeaderRow(label: line.label, amount: Money.currency(line.amount),
                                 animationValue: line.amount)
                    .padding(.bottom, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 9)
        .accessibilityIdentifier("invoiceBalanceBreakdown")
    }

    private var balanceBreakdown: [InvoiceBalanceLine] {
        guard let me = currentUsers.first else { return [] }
        let membersByID = Dictionary(uniqueKeysWithValues: group.members.map { ($0.id, $0) })
        return BalanceMath.settleUpPlan(for: group).compactMap { transfer in
            if transfer.from == me.id, let recipient = membersByID[transfer.to] {
                return InvoiceBalanceLine(id: "\(transfer.from.uuidString)-\(transfer.to.uuidString)",
                                          label: "You owe \(recipient.name)",
                                          amount: transfer.amount)
            }
            if transfer.to == me.id, let payer = membersByID[transfer.from] {
                return InvoiceBalanceLine(id: "\(transfer.from.uuidString)-\(transfer.to.uuidString)",
                                          label: "\(payer.name) owes you",
                                          amount: transfer.amount)
            }
            return nil
        }
    }
}

private struct InvoiceBalanceLine: Identifiable {
    let id: String
    let label: String
    let amount: Decimal
}

private struct InvoiceExpenseRow: View {
    let expense: Expense

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            InvoiceLeaderRow(label: expense.title, amount: Money.string(expense.amount),
                             animationValue: expense.amount)
            Text("paid by \(payerName) · split \(expense.splits.count) ways")
                .font(BrandFont.type(8.5))
                .opacity(0.55)
        }
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var payerName: String {
        let name = expense.paidBy?.name ?? "?"
        return expense.paidBy?.isCurrentUser == true ? "you" : name.lowercased()
    }
}

private struct InvoiceLeaderRow: View {
    let label: String
    let amount: String
    var strong = false
    var animationValue: Decimal? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .lineLimit(1)
                .layoutPriority(1)
            Text(String(repeating: ".", count: 38))
                .lineLimit(1)
                .opacity(0.35)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .layoutPriority(-1)
            Text(amount)
                .font(BrandFont.type(strong ? 13 : 11.5, bold: true))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: 76, alignment: .trailing)
                .contentTransition(.numericText(
                    value: NSDecimalNumber(decimal: animationValue ?? 0).doubleValue
                ))
                .animation(reduceMotion ? nil : BrandMotion.counter, value: amount)
        }
        .font(BrandFont.type(strong ? 13 : 11.5, bold: strong))
    }
}

private struct DottedRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay {
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 500, y: 0))
                }
                .stroke(Color.Brand.cobalt.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .clipped()
    }
}

private struct TornEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        let tooth: CGFloat = 13
        var x = rect.maxX
        while x > 0 {
            path.addLine(to: CGPoint(x: max(0, x - tooth / 2), y: rect.maxY))
            path.addLine(to: CGPoint(x: max(0, x - tooth), y: 0))
            x -= tooth
        }
        path.closeSubpath()
        return path
    }
}

struct ExpenseDetailScreen: View {
    @Bindable var expense: Expense
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var deletionCreatesOverpayment: Bool {
        BalanceMath.deletingWouldCreateOverpayment(expense)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandIconView(icon: expense.category.icon, size: 28)
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(width: 60, height: 60)
                    .background(Color.Brand.cobaltDeep, in: Circle())
                Text(expense.title)
                    .font(BrandFont.type(25, bold: true))
                    .multilineTextAlignment(.center)
                Text(Money.currency(expense.amount))
                    .font(BrandFont.type(36, bold: true))
                Text("paid by \(expense.paidBy?.name ?? "?") · \(expense.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(BrandFont.type(11))
                    .opacity(0.65)

                VStack(alignment: .leading, spacing: 0) {
                    Text("SPLIT BREAKDOWN")
                        .font(BrandFont.body(10, weight: .extraBold))
                        .tracking(1.2)
                        .padding(.bottom, 7)
                    ForEach(expense.splits.sorted { ($0.person?.name ?? "") < ($1.person?.name ?? "") }, id: \.persistentModelID) { split in
                        SplitBreakdownRow(name: split.person?.name ?? "Unknown",
                                          amount: Money.currency(split.computedAmount))
                    }
                    if !expense.notes.isEmpty {
                        DottedRule().padding(.vertical, 8)
                        Text("NOTES")
                            .font(BrandFont.body(10, weight: .extraBold))
                        Text(expense.notes)
                            .font(BrandFont.type(11))
                            .padding(.top, 5)
                    }
                }
                .foregroundStyle(Color.Brand.cobalt)
                .padding(16)
                .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 12))

                Button("Edit expense") { showEdit = true }
                    .font(BrandFont.display(14, weight: .bold))
                    .foregroundStyle(Color.Brand.cobalt)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 11))
                Button("Delete expense", role: .destructive) { confirmDelete = true }
                    .font(BrandFont.type(12, bold: true))
                    .foregroundStyle(Color.Brand.creamSoft)
            }
            .foregroundStyle(Color.Brand.creamSoft)
            .padding(18)
        }
        .background(Color.Brand.cobalt)
        .navigationTitle("Expense")
        .fullScreenCover(isPresented: $showEdit) { AddExpenseSheet(editingExpense: expense) }
        .fullScreenCover(isPresented: $confirmDelete) {
            DeleteExpenseConfirmationSheet(expenseTitle: expense.title,
                                           showsSettlementWarning: deletionCreatesOverpayment) {
                confirmDelete = false
            } onDelete: {
                confirmDelete = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    deleteExpense()
                }
            }
        }
    }

    private func deleteExpense() {
        let actor = currentUsers.first
        let group = expense.group
        let expenseID = expense.id
        context.insert(ActivityItem(kind: .expenseDeleted,
                                    summary: "\(actor?.name ?? "You") deleted “\(expense.title)”",
                                    refID: expense.id, actorID: actor?.id,
                                    groupID: group?.id, groupName: group?.name))
        group?.expenses.removeAll { $0.id == expense.id }
        context.delete(expense)
        try? context.save()
        LedgerIntegrity.repairEmptyGroups(context: context)
        if let group {
            CloudCollaborationService.shared.expenseWasDeleted(expenseID, from: group)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        dismiss()
    }
}

private struct DeleteExpenseConfirmationSheet: View {
    let expenseTitle: String
    let showsSettlementWarning: Bool
    let cancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "Delete expense", close: cancel)

            VStack(spacing: 18) {
                Spacer(minLength: 28)
                MascotView(mascot: .grumpy, size: 190)
                Text("erase this receipt?\u{00A0}")
                    .font(BrandFont.hand(32, weight: .bold))
                    .foregroundStyle(Color.Brand.cobalt)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                Text(expenseTitle)
                    .font(BrandFont.type(18, bold: true))
                    .foregroundStyle(Color.Brand.cobalt)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                Text(showsSettlementWarning
                     ? "A payment has already been recorded. Deleting this expense creates a refund balance; if it is the last expense, those payments will be cleared."
                     : "This removes the expense and recalculates everyone’s balance. It cannot be undone.")
                    .font(BrandFont.body(12.5, weight: .semibold))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                Spacer()
                Button(action: cancel) {
                    Text("Keep expense")
                        .font(BrandFont.display(15, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2.5))
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Text("Delete expense")
                        .font(BrandFont.display(15, weight: .bold))
                        .foregroundStyle(Color.Brand.creamSoft)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.Brand.cobalt, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
    }
}

private struct SplitBreakdownRow: View {
    let name: String
    let amount: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(name)
                .font(BrandFont.type(11.5))
                .lineLimit(1)
            DottedRule()
                .frame(maxWidth: .infinity)
            Text(amount)
                .font(BrandFont.type(11.5, bold: true))
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

private struct EditExpenseSheet: View {
    @Bindable var expense: Expense
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String

    init(expense: Expense) {
        self.expense = expense
        _title = State(initialValue: expense.title)
        _notes = State(initialValue: expense.notes)
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "Edit expense") { dismiss() }

            VStack(alignment: .leading, spacing: 16) {
                BrandSectionLabel("EXPENSE NAME")
                HStack(spacing: 10) {
                    BrandIconView(icon: .receipti, size: 18)
                        .foregroundStyle(Color.Brand.cobalt)
                    TextField("Expense name", text: $title)
                        .textInputAutocapitalization(.sentences)
                        .font(BrandFont.type(15, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))

                BrandSectionLabel("NOTES")
                TextField("Notes", text: $notes, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(3...6)
                    .font(BrandFont.type(13))
                    .foregroundStyle(Color.Brand.cobalt)
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.Brand.cobalt, lineWidth: 2))

                Spacer()
                Button(action: save) {
                    Text("Save changes")
                        .font(BrandFont.display(15.5, weight: .bold))
                        .foregroundStyle(Color.Brand.creamSoft)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.Brand.cobalt, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
    }

    private func save() {
        expense.title = title.trimmingCharacters(in: .whitespacesAndNewlines).capitalizingFirstLetter
        expense.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).capitalizingFirstLetter
        let actor = currentUsers.first
        context.insert(ActivityItem(kind: .expenseEdited,
                                    summary: "\(actor?.name ?? "You") updated “\(expense.title)”",
                                    refID: expense.id, actorID: actor?.id,
                                    groupID: expense.group?.id, groupName: expense.group?.name))
        try? context.save()
        if let group = expense.group {
            CloudCollaborationService.shared.groupDidChange(group)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

struct SettlementCelebration: Identifiable {
    let id = UUID()
    let amount: Decimal
    let from: String
    let to: String
    let groupName: String
    let fullySettled: Bool
    let rewardOutcome: RewardOutcome?
}

struct RecordPaymentSheet: View {
    let group: Group
    let onSaved: (SettlementCelebration) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @State private var amount = ""
    @State private var fromID: UUID?
    @State private var toID: UUID?

    private var parsed: Decimal? {
        Money.parseInput(amount)
    }

    private var canSave: Bool {
        guard let parsed, let suggestedAmount else { return false }
        let payment = Money.whole(parsed)
        return payment > 0 && payment <= suggestedAmount
    }

    private var settlementPlan: [DebtTransfer] {
        BalanceMath.settleUpPlan(for: group)
    }

    private var suggestedAmount: Decimal? {
        guard let fromID, let toID, fromID != toID else { return nil }
        return BalanceEngine.suggestedPayment(
            from: fromID,
            to: toID,
            in: settlementPlan
        )
    }

    private var payers: [Person] {
        let ids = Set(settlementPlan.map(\.from))
        return sortedPeople(group.members.filter { ids.contains($0.id) })
    }

    private var recipients: [Person] {
        guard let fromID else { return [] }
        let ids = Set(settlementPlan.filter { $0.from == fromID }.map(\.to))
        return sortedPeople(group.members.filter { ids.contains($0.id) })
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "Settle up") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack(alignment: .bottomTrailing) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("record payment\u{00A0}")
                                .font(BrandFont.hand(29, weight: .bold))
                                .foregroundStyle(Color.Brand.cobalt)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .allowsTightening(true)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(.trailing, 10)
                            Text(group.name.uppercased())
                                .font(BrandFont.type(10, bold: true))
                                .tracking(1.5)
                                .foregroundStyle(Color.Brand.cobalt.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 82)
                        MascotView(mascot: .neutral, size: 82)
                            .padding(.bottom, -12)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)

                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.45))
                        .frame(height: 2)

                    personSelector(title: "FROM · WHO PAID", people: payers, selection: $fromID,
                                   identifierPrefix: "settlementFrom")
                    personSelector(title: "TO · WHO RECEIVED", people: recipients, selection: $toID,
                                   identifierPrefix: "settlementTo")

                    BrandSectionLabel("AMOUNT")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Money.symbol)
                            .font(BrandFont.display(29, weight: .bold))
                        TextField("0.00", text: $amount)
                            .font(BrandFont.display(42, weight: .bold))
                            .keyboardType(.decimalPad)
                            .foregroundStyle(Color.Brand.cobalt)
                            .accessibilityIdentifier("settlementAmountField")
                    }
                    .foregroundStyle(Color.Brand.cobalt)
                    .padding(.horizontal, 16)
                    .frame(height: 68)
                    .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))

                    if let parsed, let suggestedAmount, Money.whole(parsed) > suggestedAmount {
                        Text("Maximum outstanding payment: \(Money.currency(suggestedAmount)).")
                            .font(BrandFont.type(10, bold: true))
                            .foregroundStyle(Color.red.opacity(0.8))
                    }

                    Button(action: save) {
                        Text("Record payment")
                            .font(BrandFont.display(15.5, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
                }
                .padding(18)
            }
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .onAppear {
            let currentUserID = group.members.first(where: { $0.isCurrentUser })?.id
            if let initial = settlementPlan.first(where: { $0.from == currentUserID }) ?? settlementPlan.first {
                fromID = initial.from
                toID = initial.to
                syncSuggestedAmount()
            }
        }
        .onChange(of: fromID) { _, _ in
            if !recipients.contains(where: { $0.id == toID }) {
                toID = recipients.first?.id
            }
            syncSuggestedAmount()
        }
        .onChange(of: toID) { _, _ in syncSuggestedAmount() }
    }

    private func personSelector(title: String, people: [Person], selection: Binding<UUID?>,
                                identifierPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionLabel(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(people) { person in
                        Button { selection.wrappedValue = person.id } label: {
                            Text(compactName(person))
                                .font(BrandFont.body(11, weight: .extraBold))
                                .padding(.horizontal, 15)
                                .frame(height: 36)
                                .background(selection.wrappedValue == person.id ? Color.Brand.cobalt : .clear)
                                .foregroundStyle(selection.wrappedValue == person.id ? Color.Brand.creamSoft : Color.Brand.cobalt)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(identifierPrefix)-\(person.name)")
                    }
                }
                .padding(2)
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))
        }
    }

    private func compactName(_ person: Person) -> String {
        if person.isCurrentUser { return "You" }
        return person.name.split(separator: " ").first.map(String.init) ?? person.name
    }

    private func sortedPeople(_ people: [Person]) -> [Person] {
        people.sorted {
            if $0.isCurrentUser != $1.isCurrentUser { return $0.isCurrentUser }
            return $0.name < $1.name
        }
    }

    private func syncSuggestedAmount() {
        amount = suggestedAmount.map(Money.inputString) ?? ""
    }

    private func save() {
        guard let rawAmount = parsed, let suggestedAmount,
              let from = group.members.first(where: { $0.id == fromID }),
              let to = group.members.first(where: { $0.id == toID }),
              from.id != to.id else { return }
        let amount = Money.whole(rawAmount)
        guard amount > 0, amount <= suggestedAmount else { return }
        let settlement = Settlement(amount: amount, from: from, to: to, group: group)
        context.insert(settlement)
        if !group.settlements.contains(where: { $0.id == settlement.id }) {
            group.settlements.append(settlement)
        }
        context.insert(ActivityItem(kind: .settlementRecorded,
                                    summary: "\(currentUsers.first?.name ?? "You") recorded \(from.name) paid \(to.name) \(Money.currency(amount))",
                                    refID: settlement.id, actorID: currentUsers.first?.id,
                                    groupID: group.id, groupName: group.name))
        let rewardOutcome = group.members.first(where: \.isCurrentUser).flatMap { currentUser in
            try? RewardEngine.award(action: .settlementRecorded, eventID: settlement.id,
                                    personID: currentUser.id, context: context)
        }
        if let currentUser = group.members.first(where: \.isCurrentUser) {
            try? AchievementEngine.evaluateSettlementMilestone(personID: currentUser.id,
                                                                context: context)
        }
        do {
            try context.save()
        } catch {
            return
        }
        CloudCollaborationService.shared.groupDidChange(group)
        let fullySettled = BalanceMath.settleUpPlan(for: group).isEmpty
        let result = SettlementCelebration(amount: amount, from: from.name, to: to.name,
                                           groupName: group.name, fullySettled: fullySettled,
                                           rewardOutcome: rewardOutcome)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSaved(result) }
    }
}

struct SettlementCelebrationScreen: View {
    let result: SettlementCelebration
    let dismiss: () -> Void
    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.Brand.cobalt.ignoresSafeArea()
            ConfettiBurst(active: burst && !reduceMotion)
            VStack(spacing: 10) {
                Spacer()
                MascotView(mascot: .celebrating, size: 235, idle: false)
                    .scaleEffect(reduceMotion || burst ? 1 : 0.72)
                    .offset(y: reduceMotion || burst ? 0 : 28)
                Text(result.fullySettled ? "all squared away!" : "payment recorded!")
                    .font(BrandFont.hand(38, weight: .bold))
                Text("\(result.from) paid \(result.to)")
                    .font(BrandFont.display(15, weight: .medium))
                    .opacity(0.82)
                Text(Money.currency(result.amount))
                    .font(BrandFont.type(47, bold: true))
                Text(result.fullySettled ? "invoice fully settled" : "invoice balance updated")
                    .font(BrandFont.type(10, bold: true))
                    .opacity(0.6)
                if let reward = result.rewardOutcome {
                    VStack(spacing: 3) {
                        Text("+\(reward.xpAwarded) XP")
                            .font(BrandFont.display(16, weight: .bold))
                        if let pin = reward.unlockedAchievements.first {
                            Text("\(pin.title) unlocked")
                                .font(BrandFont.type(10, bold: true))
                        } else if reward.didLevelUp {
                            Text("Level \(reward.currentLevel.rawValue) · \(reward.currentLevel.title)")
                                .font(BrandFont.type(10, bold: true))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Color.Brand.creamSoft, lineWidth: 2))
                    .padding(.top, 4)
                    .accessibilityIdentifier("settlementRewardFeedback")
                }
                Spacer()
                Button(action: dismiss) {
                    Text("Back to \(result.groupName)")
                        .font(BrandFont.display(15, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .foregroundStyle(Color.Brand.creamSoft)
            .multilineTextAlignment(.center)
            .padding(22)
            .padding(.bottom, 18)
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.55)) {
                burst = true
            }
        }
    }
}

private struct ConfettiBurst: View {
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<24, id: \.self) { i in
                ConfettiPiece(index: i, active: active, canvas: proxy.size)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let active: Bool
    let canvas: CGSize

    private var isCoin: Bool { index.isMultiple(of: 3) }
    private var color: Color {
        [Color.Brand.creamSoft, .yellow, .orange, .mint][index % 4]
    }

    private var progressX: CGFloat {
        CGFloat((index * 37 + 11) % 100) / 100
    }

    private var drift: CGFloat {
        CGFloat((index % 7) - 3) * 11
    }

    var body: some View {
        let startX = max(12, min(canvas.width - 12, canvas.width * progressX))
        let endX = max(12, min(canvas.width - 12, startX + drift))
        let startY = -30 - CGFloat(index % 6) * 20
        let endY = canvas.height + 35 + CGFloat(index % 4) * 14
        let duration = 2.25 + Double(index % 5) * 0.12
        let delay = Double(index % 8) * 0.07
        return RoundedRectangle(cornerRadius: isCoin ? 7 : 1)
            .fill(color)
            .frame(width: isCoin ? 15 : 7, height: isCoin ? 15 : 12)
            .rotationEffect(.degrees(active ? Double(index * 95 + 220) : Double(index * 13)))
            .position(x: active ? endX : startX, y: active ? endY : startY)
            .opacity(0.92)
            .animation(.linear(duration: duration).delay(delay), value: active)
    }
}
