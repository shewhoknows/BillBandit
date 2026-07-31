import SwiftUI

struct BBPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BBFont.bodyRounded(size: 16, weight: .bold, relativeTo: .body))
            .foregroundStyle(BBColor.textOnBlue)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, BBSpacing.lg)
            .background(configuration.isPressed ? BBColor.blueXDark : BBColor.accent, in: Capsule())
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.04 : 0.12), radius: 10, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct BBSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BBFont.bodyRounded(size: 16, weight: .bold, relativeTo: .body))
            .foregroundStyle(BBColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, BBSpacing.lg)
            .background(configuration.isPressed ? BBColor.divider : BBColor.cream.opacity(0.78), in: Capsule())
            .overlay {
                Capsule().stroke(BBColor.chipBorder, style: BBBorder.chip)
            }
    }
}

struct PrimaryButton: View {
    var title: String
    var systemImage: String?
    var isLoading = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BBSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .tint(BBColor.textOnBlue)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(BBPrimaryButtonStyle())
        .disabled(isLoading)
    }
}

struct SecondaryButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BBSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(BBSecondaryButtonStyle())
    }
}

struct EmptyState: View {
    var mascot: MascotView.Asset = .thinking
    var title: String
    var message: String
    var primaryActionTitle: String?
    var primaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: BBSpacing.md) {
            MascotView(asset: mascot, size: 132)

            VStack(spacing: BBSpacing.xs) {
                Text(title)
                    .font(BBFont.display(size: 22, weight: .bold, relativeTo: .title3))
                    .foregroundStyle(BBColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(BBFont.bodyRounded(size: 15, relativeTo: .body))
                    .foregroundStyle(BBColor.textFaded)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let primaryActionTitle, let primaryAction {
                PrimaryButton(title: primaryActionTitle, systemImage: "plus", action: primaryAction)
                    .padding(.top, BBSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(BBSpacing.xl)
        .background(BBColor.surface, in: RoundedRectangle(cornerRadius: BBRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBRadius.panel, style: .continuous)
                .stroke(BBColor.receiptBorder, style: BBBorder.receipt)
        }
    }
}

struct MascotView: View {
    enum Asset: String, CaseIterable, Identifiable {
        case raccoon = "BillBanditRaccoon"
        case welcome = "MascotWelcome"
        case peek = "MascotPeek"
        case thinking = "MascotThinking"
        case ledger = "MascotLedger"
        case badge = "MascotBadge"
        case final = "MascotFinal"
        case stampFinal = "StampFinal"

        var id: String { rawValue }
    }

    var asset: Asset
    var size: CGFloat = 96
    var contentMode: ContentMode = .fit

    var body: some View {
        Image(asset.rawValue)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview("Actions") {
    ZStack {
        BBColor.background.ignoresSafeArea()
        VStack(spacing: BBSpacing.md) {
            PrimaryButton(title: "Split the bill", systemImage: "receipt") {}
            SecondaryButton(title: "Invite friends", systemImage: "person.badge.plus") {}
            EmptyState(
                mascot: .welcome,
                title: "No expenses yet",
                message: "Add the first bill and BillBandit will keep the receipt trail tidy.",
                primaryActionTitle: "Add expense"
            ) {}
        }
        .padding()
    }
}
