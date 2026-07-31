import SwiftUI

@MainActor
@Observable
final class FinalBillViewModel {
    private let tripRepository: any TripRepository
    let tripId: String
    var detail: TripDetail?
    var isLoading = false
    var errorMessage: String?

    init(tripRepository: any TripRepository, tripId: String) {
        self.tripRepository = tripRepository
        self.tripId = tripId
    }

    var total: Money {
        detail?.expenses.reduce(.zero(currency: detail?.trip.currency ?? .inr)) { $0 + $1.amount } ?? .zero()
    }

    var perPerson: Money {
        let count = max(detail?.trip.participants.count ?? 1, 1)
        return Money(minorUnits: total.minorUnits / count, currency: total.currency)
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

    func shareSummary() -> String {
        guard let detail else { return "BillBandit final bill" }
        let trip = detail.trip
        var lines: [String] = [
            "BillBandit final bill",
            trip.name,
            "Total: \(total.formatted())",
            "Per-person average: \(perPerson.formatted())",
            "",
            "Balances:"
        ]

        if detail.settlementSummary.balances.isEmpty {
            lines.append("All square.")
        } else {
            for balance in detail.settlementSummary.balances {
                let name = participantName(balance.participantId, in: trip.participants)
                lines.append("\(name): \(balance.net.formatted())")
            }
        }

        lines.append("")
        lines.append("Settlement instructions:")
        if detail.settlementSummary.simplifiedInstructions.isEmpty {
            lines.append("No payments needed.")
        } else {
            for instruction in detail.settlementSummary.simplifiedInstructions {
                lines.append("\(participantName(instruction.from, in: trip.participants)) pays \(participantName(instruction.to, in: trip.participants)) \(instruction.amount.formatted())")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct FinalBillView: View {
    @State var model: FinalBillViewModel

    var body: some View {
        Group {
            if model.isLoading && model.detail == nil {
                LoadingReceiptView(title: "Preparing final bill...")
            } else if let error = model.errorMessage, model.detail == nil {
                ErrorReceiptView(message: error) {
                    Task { await model.load() }
                }
            } else if let detail = model.detail {
                content(detail)
            } else {
                ErrorReceiptView(message: "We could not prepare this final bill.") {
                    Task { await model.load() }
                }
            }
        }
        .navigationTitle("Final Bill")
        .task {
            await model.load()
        }
    }

    private func content(_ detail: TripDetail) -> some View {
        let trip = detail.trip
        return ReceiptScroll {
            ReceiptCard(eyebrow: "Shareable receipt", title: trip.name, subtitle: "Final bill") {
                VStack(spacing: BBSpacing.lg) {
                    HStack {
                        MascotView(asset: .final, size: 112)
                        Spacer()
                        MascotView(asset: .stampFinal, size: 112)
                    }

                    AmountRow(title: "Total", amount: model.total, subtitle: "\(detail.expenses.count) EXPENSES")
                    AmountRow(title: "Per-person average", amount: model.perPerson, subtitle: "\(trip.participants.count) MEMBERS")

                    if let firstDate = detail.expenses.map(\.date).min(), let lastDate = detail.expenses.map(\.date).max() {
                        Text("\(firstDate.receiptDate) - \(lastDate.receiptDate)")
                            .font(BBFont.label(size: 11, relativeTo: .caption))
                            .tracking(BBTracking.value(BBTracking.monoLabel, for: 11))
                            .foregroundStyle(BBColor.textFaded)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            ReceiptCard(eyebrow: "Balances", title: "Final positions") {
                VStack(spacing: BBSpacing.sm) {
                    if detail.settlementSummary.balances.isEmpty {
                        EmptyState(mascot: .badge, title: "All square", message: "No final balances to show.")
                    } else {
                        ForEach(detail.settlementSummary.balances, id: \.participantId) { balance in
                            BalanceRow(
                                name: participantName(balance.participantId, in: trip.participants),
                                net: balance.net,
                                detail: balance.net.minorUnits >= 0 ? "GETS BACK" : "OWES"
                            )
                        }
                    }
                }
            }

            ReceiptCard(eyebrow: "Instructions", title: "Who pays whom") {
                VStack(spacing: BBSpacing.sm) {
                    if detail.settlementSummary.simplifiedInstructions.isEmpty {
                        EmptyState(mascot: .badge, title: "No payments needed", message: "The trip is settled.")
                    } else {
                        ForEach(detail.settlementSummary.simplifiedInstructions, id: \.self) { instruction in
                            SettlementRow(
                                payerName: participantName(instruction.from, in: trip.participants),
                                recipientName: participantName(instruction.to, in: trip.participants),
                                amount: instruction.amount,
                                onTap: nil
                            )
                        }
                    }
                }
            }

            ShareLink(item: model.shareSummary()) {
                Label("Share final bill", systemImage: "square.and.arrow.up")
                    .font(BBFont.bodyRounded(size: 16, weight: .bold, relativeTo: .body))
                    .foregroundStyle(BBColor.textOnBlue)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, BBSpacing.lg)
                    .background(BBColor.accent, in: Capsule())
            }
        }
    }
}
