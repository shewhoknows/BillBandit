import SwiftUI

struct ReceiptBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            BBColor.background.ignoresSafeArea()
            content
        }
        .scrollContentBackground(.hidden)
    }
}

struct ReceiptScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ReceiptBackground {
            ScrollView {
                VStack(spacing: BBSpacing.lg) {
                    content
                }
                .padding(BBSpacing.lg)
            }
        }
    }
}

struct LoadingReceiptView: View {
    var title: String = "Printing receipt..."

    var body: some View {
        ReceiptBackground {
            ProgressView(title)
                .font(BBFont.bodyRounded(size: 15, weight: .semibold))
                .foregroundStyle(BBColor.textOnBlue)
                .tint(BBColor.textOnBlue)
        }
    }
}

struct ErrorReceiptView: View {
    var title: String = "That did not print right"
    var message: String
    var retryTitle: String = "Try again"
    var retry: () -> Void

    var body: some View {
        ReceiptScroll {
            EmptyState(
                mascot: .thinking,
                title: title,
                message: message,
                primaryActionTitle: retryTitle,
                primaryAction: retry
            )
        }
    }
}

struct InlineErrorText: View {
    var message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(BBFont.bodyRounded(size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(BBColor.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MonoLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(BBFont.label(size: 12, relativeTo: .caption))
            .tracking(BBTracking.value(BBTracking.sectionLabel, for: 12))
            .foregroundStyle(BBColor.accent)
    }
}

struct ReceiptTextField: View {
    var title: String
    var text: Binding<String>
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var isSecure = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
            }
        }
        .keyboardType(keyboardType)
        .textContentType(textContentType)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(BBFont.bodyRounded(size: 16, relativeTo: .body))
        .foregroundStyle(BBColor.textPrimary)
        .padding(.horizontal, BBSpacing.sm)
        .frame(minHeight: 48)
        .background(BBColor.cream.opacity(0.62), in: RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous)
                .stroke(BBColor.fieldBorder, style: BBBorder.field)
        }
    }
}

extension APIError {
    var humanMessage: String {
        switch self {
        case .unauthorized:
            "Your session has expired. Sign in again to keep splitting."
        case .notFound:
            "We could not find that receipt."
        case .conflict(let message):
            message == "Group is finalized" ? "This trip is finalized, so expenses and members cannot be changed." : message
        case .validation(let message), .network(let message), .server(_, let message), .decoding(let message):
            message
        }
    }
}

extension Error {
    var billBanditMessage: String {
        (self as? APIError)?.humanMessage ?? localizedDescription
    }
}

extension TripParticipant {
    var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

extension UserProfile {
    var displayName: String {
        preferredName ?? name ?? email ?? "Bandit"
    }

    var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

extension Date {
    var receiptDate: String {
        formatted(.dateTime.day().month(.abbreviated).year())
    }
}

extension Decimal {
    var plainString: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}

func moneyFromMajorText(_ text: String, currency: Currency = .inr) -> Money? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return Decimal(string: normalized).map { Money(majorUnits: $0, currency: currency) }
}

func participantName(_ id: ParticipantID, in participants: [TripParticipant]) -> String {
    participants.first(where: { $0.id == id })?.displayName ?? "Someone"
}
