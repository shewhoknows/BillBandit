import SwiftUI

struct ReceiptCard<Content: View>: View {
    var eyebrow: String?
    var title: String?
    var subtitle: String?
    var barcodeValue: String?
    var showsPerforatedEdges = true
    var minHeight: CGFloat?

    @ViewBuilder var content: Content

    init(
        eyebrow: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        barcodeValue: String? = nil,
        showsPerforatedEdges: Bool = true,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.barcodeValue = barcodeValue
        self.showsPerforatedEdges = showsPerforatedEdges
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BBSpacing.md) {
            if hasHeader {
                header
                PerforationDivider()
            }

            content

            if let barcodeValue {
                PerforationDivider()
                ReceiptBarcode(value: barcodeValue)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(BBColor.surface, in: RoundedRectangle(cornerRadius: BBRadius.receipt, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBRadius.receipt, style: .continuous)
                .stroke(BBColor.receiptBorder, style: BBBorder.receipt)
        }
        .bbShadow(.card)
        .modifier(ReceiptEdgeTreatment(isEnabled: showsPerforatedEdges))
    }

    private var hasHeader: Bool {
        eyebrow != nil || title != nil || subtitle != nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(BBFont.label(size: 10, relativeTo: .caption2))
                    .tracking(BBTracking.value(BBTracking.sectionLabel, for: 10))
                    .foregroundStyle(BBColor.accent)
            }

            if let title {
                Text(title)
                    .font(BBFont.display(size: 22, weight: .bold, relativeTo: .title3))
                    .foregroundStyle(BBColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let subtitle {
                Text(subtitle)
                    .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(BBColor.textFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ReceiptFormSection<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BBSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(BBFont.label(size: 12, relativeTo: .caption))
                    .tracking(BBTracking.value(BBTracking.sectionLabel, for: 12))
                    .foregroundStyle(BBColor.accent)

                if let subtitle {
                    Text(subtitle)
                        .font(BBFont.body(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(BBColor.textFaded)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AmountRow: View {
    var title: String
    var amount: Money
    var subtitle: String?
    var tone: Color = BBColor.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BBSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BBFont.bodyRounded(size: 16, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(BBColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(BBFont.label(size: 10, relativeTo: .caption2))
                        .tracking(BBTracking.value(BBTracking.monoLabel, for: 10))
                        .foregroundStyle(BBColor.textFaded)
                }
            }

            Spacer(minLength: BBSpacing.sm)

            Text(amount.formatted())
                .font(BBFont.amount(size: 18, relativeTo: .headline))
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct BalanceRow: View {
    var name: String
    var net: Money
    var detail: String?

    private var isPositive: Bool { net.minorUnits >= 0 }

    var body: some View {
        AmountRow(
            title: name,
            amount: net,
            subtitle: detail ?? (isPositive ? "GETS BACK" : "OWES"),
            tone: isPositive ? BBColor.success : BBColor.danger
        )
    }
}

struct SettlementRow: View {
    var payerName: String
    var recipientName: String
    var amount: Money
    var caption: String = "SETTLEMENT"
    var isLoading: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: BBSpacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(payerName) pays \(recipientName)")
                        .font(BBFont.bodyRounded(size: 16, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(BBColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption)
                        .font(BBFont.label(size: 10, relativeTo: .caption2))
                        .tracking(BBTracking.value(BBTracking.monoLabel, for: 10))
                        .foregroundStyle(BBColor.textFaded)
                }

                Spacer(minLength: BBSpacing.sm)

                if isLoading {
                    ProgressView()
                        .tint(BBColor.accent)
                } else {
                    Text(amount.formatted())
                        .font(BBFont.amount(size: 16, relativeTo: .headline))
                        .foregroundStyle(BBColor.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil || isLoading)
        .accessibilityLabel("\(payerName) pays \(recipientName) \(amount.formatted())")
    }
}

struct PerforationDivider: View {
    var body: some View {
        DashedLine()
            .stroke(BBColor.divider, style: BBBorder.divider)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct ReceiptEdgeTreatment: ViewModifier {
    var isEnabled: Bool
    var notchDiameter: CGFloat = 12
    var spacing: CGFloat = 22

    func body(content: Content) -> some View {
        content.overlay {
            if isEnabled {
                GeometryReader { proxy in
                    let count = max(2, Int(proxy.size.height / spacing))
                    let step = proxy.size.height / CGFloat(count + 1)

                    ZStack {
                        ForEach(1...count, id: \.self) { index in
                            punchedHole(x: 0, y: CGFloat(index) * step)
                            punchedHole(x: proxy.size.width, y: CGFloat(index) * step)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func punchedHole(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(BBColor.background)
            .frame(width: notchDiameter, height: notchDiameter)
            .position(x: x, y: y)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct ReceiptBarcode: View {
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: BBSpacing.xs) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(value.enumerated()), id: \.offset) { index, character in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(BBColor.textPrimary.opacity(character.isNumber ? 0.82 : 0.45))
                        .frame(width: index.isMultiple(of: 3) ? 3 : 2, height: CGFloat(18 + (index % 5) * 5))
                }
            }
            .frame(height: 42, alignment: .bottom)
            .accessibilityHidden(true)

            Text(value.uppercased())
                .font(BBFont.label(size: 10, relativeTo: .caption2))
                .tracking(BBTracking.value(BBTracking.monoLabel, for: 10))
                .foregroundStyle(BBColor.textFaded)
        }
    }
}

#Preview("Receipt Card") {
    ZStack {
        BBColor.background.ignoresSafeArea()
        ReceiptCard(
            eyebrow: "Trip receipt",
            title: "Goa Food Run",
            subtitle: "Three friends, one final bill.",
            barcodeValue: "BB-2026-GOA"
        ) {
            ReceiptFormSection(title: "Totals", subtitle: "Ready to settle") {
                AmountRow(title: "Grand total", amount: Money(minorUnits: 184250), subtitle: "PAID ACROSS 12 EXPENSES")
                BalanceRow(name: "Prateek", net: Money(minorUnits: -42150))
                SettlementRow(payerName: "Asha", recipientName: "Maya", amount: Money(minorUnits: 120000))
            }
        }
        .padding()
    }
}
