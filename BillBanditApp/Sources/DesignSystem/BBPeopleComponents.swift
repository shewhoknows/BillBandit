import SwiftUI

struct FriendRow: View {
    var name: String
    var subtitle: String?
    var initials: String
    var avatarColor: Color = BBColor.plum
    var trailingText: String?
    var badge: AnyView?
    var onTap: (() -> Void)?

    init(
        name: String,
        subtitle: String? = nil,
        initials: String,
        avatarColor: Color = BBColor.plum,
        trailingText: String? = nil,
        badge: AnyView? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.name = name
        self.subtitle = subtitle
        self.initials = initials
        self.avatarColor = avatarColor
        self.trailingText = trailingText
        self.badge = badge
        self.onTap = onTap
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: BBSpacing.sm) {
                avatar

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(BBFont.bodyRounded(size: 16, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(BBColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(BBFont.body(size: 13, relativeTo: .caption))
                            .foregroundStyle(BBColor.textFaded)
                    }
                }

                Spacer(minLength: BBSpacing.sm)

                if let badge {
                    badge
                } else if let trailingText {
                    Text(trailingText)
                        .font(BBFont.label(size: 11, relativeTo: .caption))
                        .tracking(BBTracking.value(BBTracking.monoLabel, for: 11))
                        .foregroundStyle(BBColor.textFaded)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        Text(initials.prefix(2).uppercased())
            .font(BBFont.label(size: 14, weight: .bold, relativeTo: .subheadline))
            .foregroundStyle(BBColor.cream)
            .frame(width: 44, height: 44)
            .background(avatarColor, in: Circle())
            .overlay {
                Circle().stroke(BBColor.cream.opacity(0.55), lineWidth: 1)
            }
    }
}

struct ParticipantChip: View {
    var name: String
    var initials: String?
    var isSelected = false
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: BBSpacing.xs) {
                if let initials {
                    Text(initials.prefix(2).uppercased())
                        .font(BBFont.label(size: 10, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(isSelected ? BBColor.textOnBlue : BBColor.accent)
                        .frame(width: 24, height: 24)
                        .background(isSelected ? BBColor.blueDark.opacity(0.34) : BBColor.blue.opacity(0.10), in: Circle())
                }

                Text(name)
                    .font(BBFont.bodyRounded(size: 14, weight: .semibold, relativeTo: .subheadline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? BBColor.textOnBlue : BBColor.textPrimary)
            .padding(.horizontal, BBSpacing.sm)
            .frame(minHeight: 44)
            .background(isSelected ? BBColor.accent : BBColor.cream.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().stroke(BBColor.chipBorder, style: BBBorder.chip)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct GuestBadge: View {
    var body: some View {
        PillBadge(text: "Guest", tone: BBColor.faded)
    }
}

struct InvitedBadge: View {
    var body: some View {
        PillBadge(text: "Invited", tone: BBColor.teal)
    }
}

struct StampBadge: View {
    var text: String
    var systemImage: String?
    var tone: Color = BBColor.accent
    var rotation: Angle = .degrees(-6)

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text.uppercased())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .font(BBFont.label(size: 12, weight: .heavy, relativeTo: .caption))
        .tracking(BBTracking.value(BBTracking.stamp, for: 12))
        .foregroundStyle(tone)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(BBColor.cream, in: RoundedRectangle(cornerRadius: BBRadius.stamp, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBRadius.stamp, style: .continuous)
                .stroke(tone, style: BBBorder.stamp)
        }
        .rotationEffect(rotation)
        .accessibilityLabel(text)
    }
}

private struct PillBadge: View {
    var text: String
    var tone: Color

    var body: some View {
        Text(text.uppercased())
            .font(BBFont.label(size: 10, weight: .bold, relativeTo: .caption2))
            .tracking(BBTracking.value(BBTracking.monoLabel, for: 10))
            .foregroundStyle(tone)
            .padding(.horizontal, BBSpacing.xs)
            .frame(minHeight: 28)
            .background(tone.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().stroke(tone.opacity(0.35), lineWidth: 1)
            }
    }
}

#Preview("People") {
    ReceiptCard(eyebrow: "Crew", title: "Participants") {
        VStack(alignment: .leading, spacing: BBSpacing.md) {
            FriendRow(
                name: "Maya Rao",
                subtitle: "Friend since the Jaipur trip",
                initials: "MR",
                avatarColor: BBColor.coral,
                badge: AnyView(InvitedBadge())
            )
            FriendRow(
                name: "Guest 2",
                subtitle: "Added for this bill",
                initials: "G2",
                avatarColor: BBColor.teal,
                badge: AnyView(GuestBadge())
            )
            HStack {
                ParticipantChip(name: "Prateek", initials: "PR", isSelected: true) {}
                ParticipantChip(name: "Asha", initials: "AS") {}
            }
            StampBadge(text: "Final", systemImage: "checkmark.seal.fill", tone: BBColor.success)
        }
    }
    .padding()
    .background(BBColor.background)
}
