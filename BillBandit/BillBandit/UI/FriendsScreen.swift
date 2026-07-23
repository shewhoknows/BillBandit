import SwiftUI
import SwiftData
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Phase-2 CRUD screen (visual polish lands in Phase 3).
struct FriendsScreen: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var expenses: [Expense]
    @Query private var settlements: [Settlement]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdd = false

    init() {
        _showAdd = State(initialValue: ProcessInfo.processInfo.arguments.contains("-showAddFriend"))
    }

    private var friends: [Person] { people.filter { !$0.isCurrentUser } }

    /// Pairwise you↔friend balances (positive = they owe you).
    private var nets: [UUID: Decimal] {
        guard let you = people.first(where: { $0.isCurrentUser }) else { return [:] }
        return BalanceMath.pairwiseNets(you: you, expenses: expenses, settlements: settlements)
    }

    var body: some View {
        NavigationStack {
            List {
                if friends.isEmpty {
                    VStack(spacing: 10) {
                        MascotView(mascot: .greeting, size: 145)
                        Text("add a partner in crime")
                            .font(BrandFont.hand(24, weight: .bold))
                        Text("Friends you split with will show up here.")
                            .font(BrandFont.body(12, weight: .semibold))
                            .opacity(0.7)
                        Button("Invite a friend") { showAdd = true }
                            .font(BrandFont.display(13, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Color.Brand.creamSoft, in: Capsule())
                    }
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                    .listRowBackground(Color.Brand.cobalt)
                    .listRowSeparator(.hidden)
                }
                ForEach(friends) { friend in
                    HStack(spacing: 11) {
                        ProfileAvatarView(avatar: friend.profileAvatar, size: 38)
                        Text(friend.name)
                            .font(BrandFont.display(13.5))
                            .foregroundStyle(Color.Brand.creamSoft)
                        Spacer()
                        NetChip(net: nets[friend.id] ?? 0, style: .friend)
                    }
                    .listRowBackground(Color.Brand.cobalt)
                    .listRowSeparator(.hidden)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                .onDelete { idx in
                    for i in idx {
                        let f = friends[i]
                        context.delete(f)
                        let actor = people.first(where: \.isCurrentUser)
                        context.insert(ActivityItem(kind: .friendAdded,
                                                    summary: "\(actor?.name ?? "You") removed \(f.name)",
                                                    actorID: actor?.id))
                    }
                }
            }
            .listStyle(.plain)
            .animation(reduceMotion ? nil : BrandMotion.revealSpring, value: friends.map(\.id))
            .scrollContentBackground(.hidden)
            .background(Color.Brand.cobalt)
            .navigationTitle("Friends")
            .toolbar {
                Button { showAdd = true } label: {
                    BrandIconView(icon: .plus, size: 17).foregroundStyle(Color.Brand.creamSoft)
                }
            }
            .fullScreenCover(isPresented: $showAdd) { FriendInvitationSheet() }
        }
    }
}

/// The friends ledger now lives inside Profile so account, social and future
/// progression information share one destination.
struct ProfileFriendsSection: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var expenses: [Expense]
    @Query private var settlements: [Settlement]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdd: Bool

    init() {
        _showAdd = State(initialValue: ProcessInfo.processInfo.arguments.contains("-showAddFriend"))
    }

    private var friends: [Person] { people.filter { !$0.isCurrentUser } }

    private var nets: [UUID: Decimal] {
        guard let you = people.first(where: { $0.isCurrentUser }) else { return [:] }
        return BalanceMath.pairwiseNets(you: you, expenses: expenses, settlements: settlements)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrandSectionLabel("FRIENDS")
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showAdd = true
                } label: {
                    HStack(spacing: 5) {
                        BrandIconView(icon: .plus, size: 12)
                        Text("Invite friend")
                            .font(BrandFont.body(11.5, weight: .extraBold))
                    }
                    .foregroundStyle(Color.Brand.creamSoft)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(Color.Brand.cobalt, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Invite friend")
                .accessibilityIdentifier("profileAddFriendButton")
            }

            if friends.isEmpty {
                VStack(spacing: 6) {
                    MascotView(mascot: .greeting, size: 94)
                    Text("add a partner in crime")
                        .font(BrandFont.hand(21, weight: .bold))
                    Text("Friends you split with will show up here.")
                        .font(BrandFont.body(11.5, weight: .semibold))
                        .opacity(0.65)
                }
                .foregroundStyle(Color.Brand.cobalt)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.Brand.cobalt, lineWidth: 2.5))
            } else {
                ForEach(friends) { friend in
                    HStack(spacing: 10) {
                        ProfileAvatarView(avatar: friend.profileAvatar, size: 42)
                        Text(friend.name)
                            .font(BrandFont.body(13.5, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 5)
                        NetChip(net: nets[friend.id] ?? 0, style: .friend, onLight: true)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 17)
                        .stroke(Color.Brand.cobalt, lineWidth: 2.5))
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
        }
        .animation(reduceMotion ? nil : BrandMotion.revealSpring, value: friends.map(\.id))
        .fullScreenCover(isPresented: $showAdd) { FriendInvitationSheet() }
        .task { await FriendInvitationService.shared.refreshAcceptedInvites() }
    }
}

struct FriendInvitationSheet: View {
    private enum Mode: String, CaseIterable { case share = "send invite", join = "enter code" }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var invitations = FriendInvitationService.shared
    @State private var mode: Mode
    @State private var code: String
    @State private var acceptedFriendName: String?

    init(initialCode: String? = nil) {
        let normalized = initialCode.map(FriendInviteCode.normalize) ?? ""
        _mode = State(initialValue: normalized.isEmpty ? .share : .join)
        _code = State(initialValue: normalized)
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "Invite friend") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    MascotView(mascot: .greeting, size: 126)
                    Text("add a partner in crime")
                        .font(BrandFont.hand(25.5, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)

                    HStack(spacing: 0) {
                        ForEach(Mode.allCases, id: \.self) { option in
                            Button {
                                UISelectionFeedbackGenerator().selectionChanged()
                                invitations.message = nil
                                withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
                                    mode = option
                                }
                            } label: {
                                Text(option.rawValue)
                                    .font(BrandFont.body(11.5, weight: .extraBold))
                                    .foregroundStyle(mode == option ? Color.Brand.creamSoft : Color.Brand.cobalt)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(mode == option ? Color.Brand.cobalt : .clear,
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .overlay(Capsule().stroke(Color.Brand.cobalt,
                                              lineWidth: BrandOutline.control))

                    if let acceptedFriendName {
                        acceptedView(name: acceptedFriendName)
                            .transition(.scale(scale: 0.97).combined(with: .opacity))
                    } else if mode == .share {
                        sendInviteView
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        enterCodeView
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if let message = invitations.message, acceptedFriendName == nil {
                        Text(message)
                            .font(BrandFont.type(10.5, bold: true))
                            .foregroundStyle(Color.Brand.cobalt.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .task {
            if code.isEmpty, !invitations.incomingCode.isEmpty {
                code = invitations.incomingCode
                mode = .join
            }
            if mode == .share { _ = await invitations.createInvite() }
            await invitations.refreshAcceptedInvites()
        }
        .onChange(of: mode) { _, newValue in
            invitations.message = nil
            guard newValue == .share else { return }
            Task { _ = await invitations.createInvite() }
        }
    }

    @ViewBuilder
    private var sendInviteView: some View {
        if invitations.isWorking && invitations.currentUsableInvite == nil {
            ProgressView()
                .tint(Color.Brand.cobalt)
                .frame(height: 210)
        } else if let invite = invitations.currentUsableInvite {
            VStack(spacing: 12) {
                QRCodeView(text: "billbandit://friend?code=\(invite.code)")
                    .frame(width: 174, height: 174)
                    .accessibilityLabel("Friend invitation QR code")
                    .accessibilityIdentifier("friendInviteQRCode")

                Text(FriendInviteCode.formatted(invite.code))
                    .font(BrandFont.type(24, bold: true))
                    .tracking(2)
                    .foregroundStyle(Color.Brand.cobalt)
                    .accessibilityIdentifier("friendInviteCode")

                Text("Scan the code or send the invitation. It expires in 7 days.")
                    .font(BrandFont.body(11.5, weight: .semibold))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.66))
                    .multilineTextAlignment(.center)

                ShareLink(item: invitations.shareText(for: invite)) {
                    Text("Share invitation")
                        .font(BrandFont.display(15.5, weight: .bold))
                        .foregroundStyle(Color.Brand.creamSoft)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.Brand.cobalt, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shareFriendInvitationButton")

                Button {
                    UIPasteboard.general.string = FriendInviteCode.formatted(invite.code)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Text("Copy code")
                        .font(BrandFont.body(12.5, weight: .extraBold))
                        .foregroundStyle(Color.Brand.cobalt)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(Capsule().stroke(Color.Brand.cobalt,
                                                  lineWidth: BrandOutline.control))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                Task { _ = await invitations.createInvite() }
            } label: {
                Text("Create invitation")
                    .font(BrandFont.display(15.5, weight: .bold))
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.Brand.cobalt, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var enterCodeView: some View {
        VStack(spacing: 14) {
            Text("Enter the invitation code your friend sent you.")
                .font(BrandFont.body(12.5, weight: .semibold))
                .foregroundStyle(Color.Brand.cobalt.opacity(0.68))
                .multilineTextAlignment(.center)

            TextField("B4NDT-CREW2", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(BrandFont.type(20, bold: true))
                .tracking(2)
                .foregroundStyle(Color.Brand.cobalt)
                .multilineTextAlignment(.center)
                .frame(height: 58)
                .overlay(Capsule().stroke(Color.Brand.cobalt,
                                          lineWidth: BrandOutline.control))
                .accessibilityIdentifier("friendInviteCodeField")
                .onChange(of: code) { _, value in
                    let normalized = String(FriendInviteCode.normalize(value).prefix(10))
                    if code != normalized { code = normalized }
                }

            Button {
                Task {
                    if let friend = await invitations.accept(code: code) {
                        withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
                            acceptedFriendName = friend.name
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if invitations.isWorking { ProgressView().tint(Color.Brand.creamSoft) }
                    Text("Join their crew")
                        .font(BrandFont.display(15.5, weight: .bold))
                }
                .foregroundStyle(Color.Brand.creamSoft)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.Brand.cobalt, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!FriendInviteCode.isValid(code) || invitations.isWorking)
            .opacity(FriendInviteCode.isValid(code) ? 1 : 0.45)
            .accessibilityIdentifier("acceptFriendInvitationButton")
        }
        .padding(.top, 32)
    }

    private func acceptedView(name: String) -> some View {
        VStack(spacing: 12) {
            MascotView(mascot: .celebrating, size: 150, idle: false)
            Text("crew connected!")
                .font(BrandFont.hand(29, weight: .bold))
            Text("\(name) is now in your friends list and can be added to groups.")
                .font(BrandFont.body(12.5, weight: .semibold))
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(BrandFont.display(15.5, weight: .bold))
                .foregroundStyle(Color.Brand.creamSoft)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.Brand.cobalt, in: Capsule())
                .buttonStyle(.plain)
        }
        .foregroundStyle(Color.Brand.cobalt)
    }
}

private struct QRCodeView: View {
    let text: String

    private static let context = CIContext()

    var body: some View {
        if let image = image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.Brand.cobalt, lineWidth: BrandOutline.control))
        }
    }

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = Self.context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Shared balance chip — Courier Prime money text, always.
struct NetChip: View {
    enum Style { case group, friend }

    let net: Decimal
    var style: Style = .group
    var onLight = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let abs = net < 0 ? -net : net
        Text(label(abs: abs))
            .font(BrandFont.type(11, bold: true))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(width: chipWidth)
            .foregroundStyle(onLight ? Color.Brand.cobalt : Color.Brand.creamSoft)
            .overlay(Capsule().stroke(onLight ? Color.Brand.cobalt : Color.Brand.creamSoft,
                                     lineWidth: onLight ? 2.5 : 1.8))
            .contentTransition(.numericText(value: NSDecimalNumber(decimal: net).doubleValue))
            .animation(reduceMotion ? nil : BrandMotion.counter, value: net)
    }

    private func label(abs: Decimal) -> String {
        if abs < Decimal(1) / 200 { return "settled up" }
        let amount = Money.currency(abs)
        switch style {
        case .group:  return net > 0 ? "owed \(amount)" : "owe \(amount)"
        case .friend: return net > 0 ? "owes you \(amount)" : "you owe \(amount)"
        }
    }

    private var chipWidth: CGFloat {
        if style == .group { return 150 }
        return onLight ? 146 : 172
    }
}
