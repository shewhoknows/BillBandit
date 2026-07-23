import SwiftUI
import SwiftData
import UIKit
import AuthenticationServices

struct AppRootView: View {
    private enum AccountGateState: Equatable { case checking, signedOut, authorized }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("accountOnboardingComplete") private var accountOnboardingComplete = false
    @AppStorage("appleUserIdentifier") private var appleUserIdentifier = ""
    @AppStorage("applePrivateEmail") private var applePrivateEmail = ""
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accountGateState: AccountGateState = .checking

    private var bypassOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-skipOnboarding") || args.contains("-tab") ||
            args.contains("-showAdd") || args.contains("-showAddFriend") ||
            args.contains("-showProfile") || args.contains("-showMotionLab") ||
            args.contains("-openGroup")
    }

    private var forceSignedOutOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-forceSignedOutOnboarding")
    }

    var body: some View {
        SwiftUI.Group {
            if bypassOnboarding {
                RootTabView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else if accountGateState == .authorized && accountOnboardingComplete {
                RootTabView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else if accountGateState == .checking {
                accountCheckView
                    .transition(.opacity)
            } else {
                OnboardingScreen(startAtSignIn: hasCompletedOnboarding) {
                    withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
                        hasCompletedOnboarding = true
                        accountOnboardingComplete = true
                        accountGateState = .authorized
                    }
                }
                .transition(.opacity)
            }
        }
        .task { AppStore.seedIfNeeded(context: context) }
        .task(id: appleUserIdentifier) { verifyAppleCredential() }
    }

    private var accountCheckView: some View {
        ZStack {
            Color.Brand.cobalt.ignoresSafeArea()
            VStack(spacing: 16) {
                MascotView(mascot: .thinking, size: 152, idle: false)
                Text("checking your lookout pass…")
                    .font(BrandFont.hand(25, weight: .bold))
                    .foregroundStyle(Color.Brand.creamSoft)
                ProgressView().tint(Color.Brand.creamSoft)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checking Apple sign in")
    }

    private func verifyAppleCredential() {
        if forceSignedOutOnboarding {
            accountGateState = .signedOut
            return
        }
        guard !bypassOnboarding else {
            accountGateState = .authorized
            return
        }
        guard !appleUserIdentifier.isEmpty else {
            accountGateState = .signedOut
            accountOnboardingComplete = false
            return
        }
        accountGateState = .checking
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserIdentifier) { state, _ in
            DispatchQueue.main.async {
                if state == .authorized {
                    accountGateState = .authorized
                } else {
                    appleUserIdentifier = ""
                    applePrivateEmail = ""
                    accountOnboardingComplete = false
                    accountGateState = .signedOut
                }
            }
        }
    }
}

/// App shell — cobalt tab bar with a raised cream FAB, mirroring the mockup board.
struct RootTabView: View {
    enum Tab: Int, CaseIterable {
        case home, groups, activity, profile

        var title: String {
            switch self {
            case .home: return "Home"
            case .groups: return "Groups"
            case .activity: return "Activity"
            case .profile: return "Profile"
            }
        }

        var icon: BrandIcon {
            switch self {
            case .home: return .home
            case .groups: return .users
            case .activity: return .pulse
            case .profile: return .user
            }
        }
    }

    @State private var tab: Tab = .home
    @State private var showAdd = false
    @State private var movesForward = true
    @State private var profilePickerRequested = false
    @StateObject private var rewardFeedback = RewardFeedbackCenter.shared
    @StateObject private var collaboration = CloudCollaborationService.shared
    @StateObject private var friendInvitations = FriendInvitationService.shared
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Query(sort: \ActivityItem.timestamp, order: .reverse) private var activityItems: [ActivityItem]
    @AppStorage("activityLastReadTimestamp") private var activityLastReadTimestamp = 0.0
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Screenshot support: `-tab N` selects the initial tab, `-showAdd` opens the add sheet.
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count,
           let n = Int(args[i + 1]), let t = Tab(rawValue: n) {
            _tab = State(initialValue: t)
        } else if args.contains("-showProfile") || args.contains("-showMotionLab") ||
                    args.contains("-showAddFriend") {
            _tab = State(initialValue: .profile)
        }
        if args.contains("-showAdd") { _showAdd = State(initialValue: true) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.Brand.cobalt.ignoresSafeArea()

            SwiftUI.Group {
                switch tab {
                case .home:     HomeScreen(onSeeAllGroups: { selectTab(.groups) },
                                           onOpenActivity: { selectTab(.activity) },
                                           unreadActivityCount: unreadActivityCount,
                                           onOpenProfile: {
                                               selectTab(.profile, showAvatarPicker: true)
                                           })
                case .groups:   GroupsScreen()
                case .activity: ActivityScreen()
                case .profile:  ProfileScreen(presentAvatarPicker: profilePickerRequested)
                }
            }
            .id(tab.rawValue)
            .transition(tabTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 76) // keep content clear of the floating dock

            tabBar

            if let groupID = collaboration.pendingMemberClaimGroupID {
                MemberClaimView(groupID: groupID)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(50)
            }
        }
        .overlay(alignment: .bottom) {
            if let outcome = rewardFeedback.current {
                RewardToastView(outcome: outcome)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 76)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : BrandMotion.revealSpring,
                   value: rewardFeedback.current?.id)
        .fullScreenCover(isPresented: $showAdd) {
            AddExpenseSheet()
        }
        .fullScreenCover(isPresented: $friendInvitations.shouldPresentInviteSheet) {
            FriendInvitationSheet(initialCode: friendInvitations.incomingCode)
        }
        .task { AppStore.seedIfNeeded(context: context) }
        .task { await friendInvitations.refreshAcceptedInvites() }
        .onAppear {
            if tab == .activity { markActivityRead() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.home)
            tabButton(.groups)
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showAdd = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.Brand.creamSoft)
                        .frame(width: 48, height: 48)
                        .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
                    BrandIconView(icon: .plus, size: 23)
                        .foregroundStyle(Color.Brand.cobalt)
                }
            }
            .frame(width: 64)
            .buttonStyle(.plain)
            .accessibilityLabel("Add expense")

            tabButton(.activity)
            tabButton(.profile)
        }
        .padding(.horizontal, 12)
        .frame(height: 66)
        .background(
            Color.Brand.cobaltDeep.opacity(0.90),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .shadow(color: Color.Brand.cobaltDeep.opacity(0.34), radius: 12, y: 6)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func tabButton(_ t: Tab) -> some View {
        Button {
            guard tab != t else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selectTab(t)
        } label: {
            VStack(spacing: 3) {
                if t == .profile {
                    ProfileAvatarView(
                        avatar: currentUsers.first?.profileAvatar ?? .sunglasses,
                        size: 23
                    )
                    .opacity(t == tab ? 1 : 0.48)
                } else {
                    BrandIconView(icon: t.icon, size: 22)
                }
                Text(t.title)
                    .font(BrandFont.body(9.5, weight: .extraBold))
            }
            .foregroundStyle(Color.Brand.creamSoft.opacity(t == tab ? 1 : 0.4))
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(
            t == .profile
                ? "profileTabAvatar-\((currentUsers.first?.profileAvatar ?? .sunglasses).rawValue)"
                : "tab-\(t.title.lowercased())"
        )
    }

    private var tabTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let entering: Edge = movesForward ? .trailing : .leading
        let leaving: Edge = movesForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: entering).combined(with: .opacity),
            removal: .move(edge: leaving).combined(with: .opacity)
        )
    }

    private func selectTab(_ newTab: Tab, showAvatarPicker: Bool = false) {
        if newTab == .activity { markActivityRead() }
        guard tab != newTab else { return }
        movesForward = newTab.rawValue > tab.rawValue
        profilePickerRequested = newTab == .profile && showAvatarPicker
        withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
            tab = newTab
        }
    }

    private var unreadActivityCount: Int {
        guard let currentUserID = currentUsers.first?.id else { return 0 }
        let lastRead = Date(timeIntervalSince1970: activityLastReadTimestamp)
        return ActivityData.unreadCount(in: activityItems, currentUserID: currentUserID,
                                        lastRead: lastRead)
    }

    private func markActivityRead() {
        activityLastReadTimestamp = Date.now.timeIntervalSince1970
    }
}

private struct MemberClaimView: View {
    let groupID: UUID

    @Query private var groups: [Group]
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var group: Group? { groups.first { $0.id == groupID } }
    private var current: Person? { currentUsers.first }
    private var availableMembers: [Person] {
        group?.members.filter { $0.cloudUserRecordName == nil && !$0.isCurrentUser } ?? []
    }

    var body: some View {
        ZStack {
            Color.Brand.cobalt.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 12)
                MascotView(mascot: .greeting, size: 154, idle: false)
                VStack(spacing: 7) {
                    Text("which member are you?")
                        .font(BrandFont.hand(30, weight: .bold))
                    Text("Match your profile to the name used on \(group?.name ?? "this shared bill").")
                        .font(BrandFont.body(14, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .opacity(0.72)
                }

                VStack(spacing: 10) {
                    ForEach(availableMembers) { member in
                        claimButton(member.name) {
                            claim(as: member.id)
                        }
                    }
                    if let current {
                        claimButton("Join as \(current.name)", outlined: true) {
                            claim(as: nil)
                        }
                    }
                }
                Spacer()
            }
            .foregroundStyle(Color.Brand.cobalt)
            .padding(.horizontal, 26)
            .padding(.vertical, 26)
            .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.vertical, 56)
        }
        .accessibilityIdentifier("memberClaimScreen")
    }

    private func claimButton(_ title: String, outlined: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.display(16, weight: .bold))
                .foregroundStyle(outlined ? Color.Brand.cobalt : Color.Brand.creamSoft)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(outlined ? Color.clear : Color.Brand.cobalt, in: Capsule())
                .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
    }

    private func claim(as memberID: UUID?) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
            CloudCollaborationService.shared.claimCurrentUser(in: groupID, as: memberID)
        }
    }
}

private struct RewardToastView: View {
    let outcome: RewardOutcome

    private var unlocked: StarterAchievement? { outcome.unlockedAchievements.first }

    var body: some View {
        HStack(spacing: 12) {
            if let unlocked {
                AchievementBadgeView(achievement: unlocked, size: 48)
            } else {
                Text("+\(outcome.xpAwarded)")
                    .font(BrandFont.type(14, bold: true))
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(width: 46, height: 46)
                    .background(Color.Brand.cobalt, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(unlocked?.title ?? (outcome.didLevelUp
                    ? "Level up · \(outcome.currentLevel.title)"
                    : "+\(outcome.xpAwarded) XP"))
                    .font(BrandFont.display(14, weight: .bold))
                Text(unlocked == nil
                    ? "\(outcome.totalXP) lifetime XP"
                    : "+\(outcome.xpAwarded) XP · pin unlocked")
                    .font(BrandFont.type(9.5, bold: true))
                    .opacity(0.62)
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(Color.Brand.cobalt, lineWidth: 2.5))
        .shadow(color: Color.black.opacity(0.22), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rewardToast")
    }
}

#Preview {
    RootTabView()
}
