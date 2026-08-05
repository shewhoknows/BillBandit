import SwiftUI
import SwiftData
import UIKit
import AuthenticationServices

struct OnboardingScreen: View {
    let onComplete: () -> Void
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appleUserIdentifier") private var appleUserIdentifier = ""
    @AppStorage("applePrivateEmail") private var applePrivateEmail = ""
    @AppStorage("usernameHandleVerified") private var usernameHandleVerified = false
    @AppStorage("deferNextAppleCredentialStateCheck") private var deferNextAppleCredentialStateCheck = false
    @State private var page = 0
    @State private var name = ""
    @State private var mascotRaised = false
    @State private var authMessage: String?
    @State private var usernameValidationMessage: String?
    @State private var isCompleting = false
    @State private var hasUsernameSession = UsernameIdentityService.hasStoredSession
    /// A returning Apple account already has a server-owned handle. Keep that
    /// value through onboarding so we do not POST a second claim for it.
    @State private var authenticatedRemoteUsername: String?
    @FocusState private var usernameFocused: Bool

    private let pages: [(Mascot, String, String)] = [
        (.greeting, "split bills, not friendships.", "Keep every shared expense clear without making it awkward."),
        (.thinking, "the math gets handled.", "Equal, exact, percentage or shares — every rupee lands exactly."),
        (.celebrating, "settle up. stay friends.", "Record a payment and let the bandit celebrate the clean slate."),
    ]

    private var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-onboardingDemo")
    }

    private var isForcedSignedOutPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-forceSignedOutOnboarding")
    }

    private var isForcedConnectedIncompletePreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-onboardingConnectedIncomplete")
    }

    init(startAtSignIn: Bool = false, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-onboardingPage"), index + 1 < args.count,
           let requested = Int(args[index + 1]), (0...2).contains(requested) {
            _page = State(initialValue: requested)
        } else if startAtSignIn {
            _page = State(initialValue: 2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("0\(page + 1) / 03")
                    .font(BrandFont.display(15, weight: .semibold))
                Spacer()
                if page < 2 {
                    Button("Skip") { withAnimation(onboardingTransition) { page = 2 } }
                        .font(BrandFont.body(12, weight: .extraBold))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            HStack {
                Text("BillBandit")
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .font(BrandFont.display(44, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            TabView(selection: $page) {
                ForEach(0..<3, id: \.self) { index in
                    onboardingPage(index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.Brand.creamSoft.opacity(index == page ? 1 : 0.35))
                        .frame(width: index == page ? 24 : 7, height: 7)
                        .animation(reduceMotion ? nil : .spring(response: 0.35), value: page)
                }
            }
            .padding(.bottom, 16)

            ZStack {
                if page < 2 {
                    Button(action: advance) {
                        Text("Next")
                            .font(BrandFont.display(16, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.Brand.creamSoft,
                                        in: RoundedRectangle(cornerRadius: 13))
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 72, alignment: .top)
            .padding(.horizontal, 22)
        }
        .foregroundStyle(Color.Brand.creamSoft)
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .onAppear {
            hasUsernameSession = UsernameIdentityService.hasStoredSession
            name = if isForcedConnectedIncompletePreview {
                ""
            } else if isDemo {
                "Esha"
            } else {
                currentUsers.first?.name == "You" ? "" : (currentUsers.first?.name ?? "")
            }
            startMascotMotion()
        }
        .onChange(of: reduceMotion) { startMascotMotion() }
        .task {
            guard isDemo else { return }
            for target in 1...2 {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                withAnimation(onboardingTransition) {
                    page = target
                }
            }
        }
    }

    private func onboardingPage(_ index: Int) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 4)
            MascotView(mascot: pages[index].0, size: 178, idle: false)
                .offset(y: reduceMotion ? 0 : (mascotRaised ? -7 : 7))
                .frame(height: 194)
                .accessibilityIdentifier("onboardingMascot-\(index)")
            Text(pages[index].1)
                .font(BrandFont.hand(28, weight: .bold))
                .multilineTextAlignment(.center)
                .frame(height: 42)
                .accessibilityIdentifier("onboardingTitle-\(index)")
            Text(pages[index].2)
                .font(BrandFont.body(14, weight: .semibold))
                .multilineTextAlignment(.center)
                .opacity(0.78)
                .padding(.horizontal, 32)
                .frame(height: 44, alignment: .top)
                .accessibilityIdentifier("onboardingDescription-\(index)")
            if index == 2 {
                VStack(alignment: .leading, spacing: 9) {
                    Text(authenticatedRemoteUsername == nil
                         ? "Choose your unique handle"
                         : "Your unique handle")
                        .font(BrandFont.display(15, weight: .semibold))
                    TextField("@username", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($usernameFocused)
                        .onSubmit { usernameFocused = false }
                        .onChange(of: name) {
                            usernameValidationMessage = nil
                        }
                        .disabled(authenticatedRemoteUsername != nil)
                        .accessibilityIdentifier("onboardingUsernameField")
                        .font(BrandFont.body(17, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .background(Color.Brand.creamSoft, in: Capsule())

                    Text("Sign in before entering your ledger")
                        .font(BrandFont.display(13.5, weight: .semibold))
                        .padding(.top, 3)

                    if (appleUserIdentifier.isEmpty || !hasUsernameSession ||
                        isForcedSignedOutPreview) && !isForcedConnectedIncompletePreview {
                        if !appleUserIdentifier.isEmpty && !isForcedSignedOutPreview {
                            Text("Reconnect Apple to verify your unique handle.")
                                .font(BrandFont.type(9.5, bold: true))
                                .opacity(0.72)
                        }
                        SignInWithAppleButton(.continue) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            handleAppleSignIn(result)
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 48)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("onboardingSignInWithAppleButton")
                        .allowsHitTesting(!isCompleting)
                    } else {
                        HStack(spacing: 10) {
                            Text("")
                                .font(.system(size: 20, weight: .semibold))
                            Text("Apple account connected")
                                .font(BrandFont.body(13.5, weight: .bold))
                            Spacer()
                            Text("✓")
                                .font(BrandFont.display(17, weight: .bold))
                        }
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .background(Color.Brand.creamSoft, in: Capsule())
                        .accessibilityIdentifier("onboardingAppleConnected")

                        Button {
                            Task { await completeOnboardingIfReady() }
                        } label: {
                            Text(isCompleting ? "Checking handle…" : "Enter BillBandit")
                                .font(BrandFont.display(15.5, weight: .bold))
                                .foregroundStyle(Color.Brand.cobalt)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.Brand.creamSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboardingEnterBillBanditButton")
                        .disabled(isCompleting)
                    }

                    if let usernameValidationMessage {
                        Text(usernameValidationMessage)
                            .font(BrandFont.type(9.5, bold: true))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .accessibilityIdentifier("onboardingUsernameError")
                    }

                    if let authMessage {
                        Text(authMessage)
                            .font(BrandFont.type(9.5, bold: true))
                            .opacity(0.72)
                    }
                }
                .padding(.horizontal, 22)
                .frame(height: 246, alignment: .top)
            } else {
                Color.clear
                    .frame(height: 246)
            }
            Spacer(minLength: 4)
        }
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if page < 2 {
            withAnimation(onboardingTransition) { page += 1 }
        }
    }

    private var onboardingTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.46)
    }

    @MainActor
    private func completeOnboardingIfReady() async {
        guard !isCompleting else { return }
        guard !appleUserIdentifier.isEmpty else {
            authMessage = "Connect your Apple account before entering BillBandit."
            return
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            usernameValidationMessage = "Username is required to complete onboarding."
            return
        }

        let handle: UsernameHandle
        do {
            handle = try UsernameHandle(name)
        } catch {
            usernameValidationMessage = error.localizedDescription
            return
        }
        guard hasUsernameSession || isForcedConnectedIncompletePreview else {
            authMessage = "Reconnect your Apple account before entering BillBandit."
            return
        }

        usernameValidationMessage = nil
        isCompleting = true
        defer { isCompleting = false }
        do {
            let confirmedHandle: String
            if let existingHandle = UsernameOnboardingHandlePolicy.existingHandle(
                remoteUsername: authenticatedRemoteUsername,
                isForcedPreview: isForcedConnectedIncompletePreview
            ) {
                // The Apple authentication response is authoritative for an
                // existing account. The handle can be changed later from
                // Profile, but onboarding must not attempt to claim it again.
                confirmedHandle = existingHandle
            } else {
                confirmedHandle = isForcedConnectedIncompletePreview
                    ? handle.value
                    : try await UsernameIdentityService.claim(handle)
            }
            let current = AccountProfileIntegrity.canonicalize(
                appleUserIdentifier: appleUserIdentifier,
                cloudUserRecordName: nil,
                context: context
            )
            current.appleSessionStateRaw = "active"
            if current.name != confirmedHandle {
                current.name = confirmedHandle
                current.profileUpdatedAt = .now
            }
            try context.save()
            usernameHandleVerified = true
            Task { await CloudCollaborationService.shared.accountDidChange() }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onComplete()
        } catch {
            usernameValidationMessage = error.localizedDescription
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        Task { @MainActor in
            await finishAppleSignIn(result)
        }
    }

    @MainActor
    private func finishAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken else {
                authMessage = "Apple could not return an account credential."
                return
            }
            let fullName = credential.fullName.flatMap {
                let value = PersonNameComponentsFormatter().string(from: $0)
                return value.isEmpty ? nil : value
            }
            isCompleting = true
            defer { isCompleting = false }
            do {
                let remoteUser = try await UsernameIdentityService.authenticateWithApple(
                    identityToken: identityToken,
                    authorizationCode: credential.authorizationCode,
                    name: fullName,
                    email: credential.email
                )
                ServerLedgerSurfaceStore.shared.accountDidAuthenticate(remoteUser.id)
                deferNextAppleCredentialStateCheck = true
                appleUserIdentifier = credential.user
                if let email = credential.email { applePrivateEmail = email }
                hasUsernameSession = true
                switch UsernameAccountReconciliationPolicy.decision(
                    remoteUsername: remoteUser.username
                ) {
                case .verified(let username):
                    authenticatedRemoteUsername = username
                    name = username
                case .requiresClaim:
                    authenticatedRemoteUsername = nil
                    if let fullName,
                       name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = fullName
                    }
                }
                usernameValidationMessage = nil
                authMessage = nil
            } catch {
                hasUsernameSession = false
                authMessage = error.localizedDescription
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                authMessage = "Apple sign in could not be completed. Try again."
            }
        }
    }

    private func startMascotMotion() {
        guard !reduceMotion else {
            mascotRaised = false
            return
        }
        mascotRaised = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            mascotRaised = true
        }
    }
}

struct HomeScreen: View {
    let onSeeAllGroups: () -> Void
    let onOpenActivity: () -> Void
    let unreadActivityCount: Int
    let onOpenProfile: () -> Void

    @Query(sort: \Group.createdAt, order: .reverse) private var groups: [Group]
    @Query(sort: \ActivityItem.timestamp, order: .reverse) private var activity: [ActivityItem]
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var serverLedger = ServerLedgerSurfaceStore.shared
    @State private var showAddGroup = false
    @State private var showMotionLab = false

    init(onSeeAllGroups: @escaping () -> Void = {},
         onOpenActivity: @escaping () -> Void = {},
         unreadActivityCount: Int = 0,
         onOpenProfile: @escaping () -> Void = {}) {
        self.onSeeAllGroups = onSeeAllGroups
        self.onOpenActivity = onOpenActivity
        self.unreadActivityCount = unreadActivityCount
        self.onOpenProfile = onOpenProfile
        _showMotionLab = State(initialValue: ProcessInfo.processInfo.arguments.contains("-showMotionLab"))
    }

    private var sharedGroups: [Group] {
        groups.filter { $0.serverLedgerGroupID != nil }
    }

    private var localGroups: [Group] {
        groups.filter { $0.serverLedgerGroupID == nil }
    }

    private var localGroupNets: [(Group, Decimal)] {
        guard let me = currentUsers.first else { return [] }
        return localGroups.map { ($0, BalanceMath.nets(in: $0)[me.id] ?? 0) }
    }

    private var localOwed: Decimal {
        Money.cents(localGroupNets.reduce(0) { $0 + max($1.1, 0) })
    }

    private var localOwe: Decimal {
        Money.cents(localGroupNets.reduce(0) { $0 + max(-$1.1, 0) })
    }

    private var localNet: Decimal { Money.cents(localOwed - localOwe) }

    private var localActivity: [ActivityItem] {
        activity.filter { item in
            guard let groupID = item.groupID else { return true }
            return groups.first(where: { $0.id == groupID })?.serverLedgerGroupID == nil
        }
    }

    private var sharedActivity: [ServerLedgerSurfaceActivityItem] {
        serverLedger.snapshot?.activity ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    balanceHeader
                    groupGrid
                    recentActivity
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
            .background(Color.Brand.cobalt)
            .fullScreenCover(isPresented: $showAddGroup) { AddGroupSheet() }
            .fullScreenCover(isPresented: $showMotionLab) {
                MascotMotionLabScreen()
            }
            .navigationDestination(for: Group.self) { group in
                GroupDetailScreen(group: group)
            }
            .task(id: groups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
                await serverLedger.refresh(groups: groups)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("BillBandit")
                .font(BrandFont.display(18, weight: .semibold))
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onOpenActivity()
            } label: {
                ZStack(alignment: .topTrailing) {
                    BrandIconView(icon: .bell, size: 19)
                        .frame(width: 31, height: 31)
                    if unreadActivityCount > 0 {
                        Text(unreadActivityCount > 99 ? "99+" : "\(unreadActivityCount)")
                            .font(BrandFont.type(7.5, bold: true))
                            .foregroundStyle(Color.Brand.cobalt)
                            .frame(minWidth: 16, minHeight: 16)
                            .padding(.horizontal, unreadActivityCount > 9 ? 2 : 0)
                            .background(Color.Brand.creamSoft, in: Capsule())
                            .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 1.5))
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: unreadActivityCount)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(unreadActivityCount == 0
                ? "Open activity"
                : "Open activity, \(unreadActivityCount) unread")
            .accessibilityIdentifier("homeActivityBell")
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onOpenProfile()
            } label: {
                ProfileAvatarView(
                    avatar: currentUsers.first?.profileAvatar ?? .sunglasses,
                    size: 40
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile")
            .accessibilityIdentifier(
                "dashboardProfileAvatar-\((currentUsers.first?.profileAvatar ?? .sunglasses).rawValue)"
            )
        }
        .foregroundStyle(Color.Brand.creamSoft)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var balanceHeader: some View {
        VStack(spacing: 16) {
            if !sharedGroups.isEmpty {
                VStack(alignment: .center, spacing: 7) {
                    Text("shared ledger ")
                        .font(BrandFont.hand(20, weight: .semibold))
                    if let presentation = serverLedger.accountBalancePresentation() {
                        ServerLedgerBalanceChip(presentation: presentation)
                    } else {
                        Text(serverLedger.status.label)
                            .font(BrandFont.type(11, bold: true))
                            .multilineTextAlignment(.center)
                            .opacity(0.78)
                    }
                    ServerLedgerSurfaceStatusView(ledger: serverLedger) {
                        Task { await serverLedger.refresh(groups: groups) }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !localGroups.isEmpty {
                VStack(alignment: .center, spacing: 5) {
                    Text("on-device ledger ")
                        .font(BrandFont.hand(19, weight: .semibold))
                    Text(localNet >= 0 ? "you're owed overall" : "you owe overall")
                        .font(BrandFont.type(11, bold: true))
                        .opacity(0.86)
                    AnimatedCurrencyText(amount: abs(localNet), font: BrandFont.display(39, weight: .bold))
                    Squiggle()
                        .stroke(Color.Brand.creamSoft, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 112, height: 10)
                    HStack(spacing: 8) {
                        BalancePill(text: "you owe \(Money.currency(localOwe))", filled: false,
                                    onDark: true, animationValue: localOwe)
                        BalancePill(text: "owed \(Money.currency(localOwed))", filled: false,
                                    onDark: true, animationValue: localOwed)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if groups.isEmpty {
                Text("no groups yet ")
                    .font(BrandFont.hand(20, weight: .semibold))
                    .opacity(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .foregroundStyle(Color.Brand.creamSoft)
    }

    private var groupGrid: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Your groups")
                    .font(BrandFont.display(16, weight: .semibold))
                Spacer()
                Button(action: onSeeAllGroups) {
                    Text("see all")
                        .font(BrandFont.body(11, weight: .extraBold))
                        .opacity(0.65)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all groups")
            }
            .foregroundStyle(Color.Brand.creamSoft)
            .padding(.top, 15)

            if !sharedGroups.isEmpty {
                Text("shared groups")
                    .font(BrandFont.type(10, bold: true))
                    .foregroundStyle(Color.Brand.creamSoft.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
                groupCards(for: sharedGroups)
            }
            if !localGroups.isEmpty {
                Text("on-device groups")
                    .font(BrandFont.type(10, bold: true))
                    .foregroundStyle(Color.Brand.creamSoft.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
                groupCards(for: localGroups)
            }
            newGroupButton
        }
    }

    @ViewBuilder
    private func groupCards(for sourceGroups: [Group]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(sourceGroups.prefix(3), id: \.id) { group in
                groupCard(for: group)
            }
        }
        .animation(reduceMotion ? nil : BrandMotion.revealSpring, value: sourceGroups.map(\.id))
    }

    private var newGroupButton: some View {
        Button { showAddGroup = true } label: {
            VStack(spacing: 8) {
                BrandIconView(icon: .plus, size: 23)
                Text("New group")
                    .font(BrandFont.display(13, weight: .semibold))
            }
            .foregroundStyle(Color.Brand.creamSoft)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(RoundedRectangle(cornerRadius: 14).stroke(
                Color.Brand.creamSoft.opacity(0.65),
                style: StrokeStyle(lineWidth: 1.8, dash: [6, 5])
            ))
        }
    }

    @ViewBuilder
    private func groupCard(for group: Group) -> some View {
        let serverGroupID = group.serverLedgerGroupID
        let canonicalGroup = serverGroupID.flatMap { serverLedger.snapshot?.group(for: $0) }
        let presentation = serverGroupID.flatMap { serverLedger.groupBalancePresentation(for: $0) }
        let localNet: Decimal? = serverGroupID == nil
            ? currentUsers.first.map { BalanceMath.nets(in: group)[$0.id] ?? 0 }
            : nil
        NavigationLink(value: group) {
            GroupCard(
                group: group,
                balanceText: presentation?.label ?? (serverGroupID == nil
                    ? localNet.map { $0 >= 0 ? "owed \(Money.currency($0))" : "owe \(Money.currency(-$0))" }
                    : nil),
                balanceIsPositive: presentation?.isPositive ?? ((localNet ?? 0) >= 0),
                sourceLabel: ServerLedgerUserFacingCopy.groupSourceLabel(
                    isLocalOnly: serverGroupID == nil,
                    isLoading: serverGroupID != nil
                        && canonicalGroup == nil
                        && serverLedger.status.phase == .loading
                ),
                balanceIsLoading: serverGroupID != nil
                    && presentation == nil
                    && serverLedger.status.phase == .loading
            )
        }
        .buttonStyle(.plain)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.92).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private var recentActivity: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent activity")
                    .font(BrandFont.display(14, weight: .semibold))
                    .padding(.bottom, 4)
                if !sharedGroups.isEmpty {
                    Text("shared ledger")
                        .font(BrandFont.type(9, bold: true))
                        .opacity(0.58)
                        .padding(.top, 4)
                    if sharedActivity.isEmpty {
                        if serverLedger.snapshot == nil {
                            ServerLedgerSurfaceStatusView(
                                ledger: serverLedger,
                                includeEmpty: true
                            ) {
                                Task { await serverLedger.refresh(groups: groups) }
                            }
                            .padding(.vertical, 7)
                        } else {
                            Text("No shared activity yet")
                                .font(BrandFont.type(11))
                                .opacity(0.55)
                                .padding(.vertical, 8)
                        }
                    } else {
                        ForEach(Array(sharedActivity.prefix(3))) { item in
                            ServerLedgerActivityRow(item: item, compact: true)
                        }
                    }
                }
                if !localActivity.isEmpty {
                    Text("on-device activity")
                        .font(BrandFont.type(9, bold: true))
                        .opacity(0.58)
                        .padding(.top, 7)
                    ForEach(Array(localActivity.prefix(3))) { item in
                        ActivityLedgerRow(item: item, compact: true)
                    }
                }
                if sharedGroups.isEmpty && localActivity.isEmpty {
                    Text("No sightings yet")
                        .font(BrandFont.type(11))
                        .opacity(0.55)
                        .padding(.vertical, 12)
                }
            }
            .foregroundStyle(Color.Brand.cobalt)
            .padding(13)
            .padding(.top, 2)
            .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 15))
            .padding(.top, 22)

            MascotView(mascot: .confused, size: 58)
                .padding(.trailing, 12)
        }
        .padding(.top, 2)
    }
}

private struct VerticalCollapseLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(width: proposal.width ?? natural.width,
                      height: natural.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let natural = content.sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        )
        content.place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width,
                                                 height: natural.height))
    }
}

private final class ProfileNameUITextField: UITextField {
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        if offset(from: position, to: endOfDocument) == 0 {
            rect.origin.x += 4
        }
        return rect
    }
}

private struct ProfileNameTextField: UIViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEditingEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ProfileNameUITextField {
        let field = ProfileNameUITextField()
        let baseFont = UIFont(name: "Caveat-Bold", size: 24 * BrandFont.scale)
            ?? .systemFont(ofSize: 24 * BrandFont.scale, weight: .bold)
        field.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: baseFont)
        field.adjustsFontForContentSizeCategory = true
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = baseFont.pointSize * 0.65
        field.textAlignment = .center
        field.textColor = UIColor(Color.Brand.cobalt)
        field.tintColor = UIColor(Color.Brand.cobalt)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.textChanged(_:)),
                        for: .editingChanged)
        field.accessibilityIdentifier = "profileNameField"
        return field
    }

    func updateUIView(_ field: ProfileNameUITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        guard !field.isFirstResponder else { return }
        DispatchQueue.main.async { field.becomeFirstResponder() }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ProfileNameTextField

        init(parent: ProfileNameTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onEditingEnded()
        }
    }
}

private enum BillBanditLegalLinks {
    static let privacyPolicy = URL(string: "https://shewhoknows.github.io/BillBandit/billbandit/")!
    static let support = URL(string: "https://shewhoknows.github.io/BillBandit/billbandit/support/")!
}

struct ProfileScreen: View {
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Query private var groups: [Group]
    @Query private var expenses: [Expense]
    @Query private var progressRecords: [UserProgress]
    @Query private var achievementUnlocks: [AchievementUnlock]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var serverLedger = ServerLedgerSurfaceStore.shared
    @AppStorage("appleUserIdentifier") private var appleUserIdentifier = ""
    @AppStorage("applePrivateEmail") private var applePrivateEmail = ""
    @AppStorage("accountOnboardingComplete") private var accountOnboardingComplete = false
    @AppStorage("usernameHandleVerified") private var usernameHandleVerified = false
    @AppStorage("deferNextAppleCredentialStateCheck") private var deferNextAppleCredentialStateCheck = false
    @State private var name: String
    @State private var selectedAvatar: ProfileAvatar
    @State private var authMessage: String?
    @State private var showAvatarPicker: Bool
    @State private var isEditingName = false
    @State private var isSavingUsername = false
    @State private var hasUsernameSession = UsernameIdentityService.hasStoredSession
    @State private var showSignOutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false

    init(presentAvatarPicker: Bool = false) {
        _name = State(initialValue: "")
        _selectedAvatar = State(initialValue: .sunglasses)
        _showAvatarPicker = State(initialValue: presentAvatarPicker)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentPersonID: UUID? { currentUsers.first?.id }

    private var currentProgress: UserProgress? {
        guard let currentPersonID else { return nil }
        return progressRecords.first { $0.personID == currentPersonID }
    }

    private var progressEnabled: Bool { currentProgress?.isEnabled ?? true }
    private var lifetimeXP: Int { currentProgress?.lifetimeXP ?? 0 }

    private var sharedGroups: [Group] {
        groups.filter { $0.serverLedgerGroupID != nil }
    }

    private var localGroups: [Group] {
        groups.filter { $0.serverLedgerGroupID == nil }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Profile")
                .font(BrandFont.display(29, weight: .bold))
                .foregroundStyle(Color.Brand.creamSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            if showAvatarPicker {
                                confirmAvatarSelection()
                            } else {
                                withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
                                    showAvatarPicker = true
                                }
                            }
                        } label: {
                            ProfileAvatarView(avatar: selectedAvatar, size: 132, isSelected: true)
                                .padding(.top, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAvatarPicker ? "Save avatar choice" : "Change avatar")
                        .accessibilityIdentifier("profileAvatarButton")

                        if isEditingName {
                            ProfileNameTextField(
                                text: $name,
                                onSubmit: { commitNameEdit() },
                                onEditingEnded: {
                                    if isEditingName { commitNameEdit() }
                                }
                            )
                                .frame(maxWidth: 300, minHeight: 48)
                                .padding(.horizontal, 12)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.Brand.cobalt)
                                        .frame(height: 2)
                                }
                        } else {
                            Button {
                                beginNameEdit()
                            } label: {
                                Text((trimmedName.isEmpty ? "your profile" : trimmedName) + " ")
                                    .font(BrandFont.hand(24, weight: .bold))
                                    .foregroundStyle(Color.Brand.cobalt)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .frame(maxWidth: 300, minHeight: 48)
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: 324, minHeight: 48)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Edit username")
                            .accessibilityIdentifier("profileNameButton")
                        }

                        Text(isSavingUsername ? "reserving your handle…" :
                             (isEditingName ? "press done to save" :
                             (showAvatarPicker ? "choose freely · tap big avatar to save" :
                                "tap username to edit · tap avatar to change")))
                            .font(BrandFont.type(9.5, bold: true))
                            .foregroundStyle(Color.Brand.cobalt.opacity(0.58))
                    }

                    if showAvatarPicker {
                        avatarPickerSection
                            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                    }

                    VStack(spacing: 8) {
                        gamificationSection
                        ProfileFriendsSection()
                    }
                    if !sharedGroups.isEmpty {
                        sharedLedgerSection
                    }
                    appleAccountSection
                    legalSection

                    VStack(alignment: .leading, spacing: 10) {
                        BrandSectionLabel("YOUR LEDGER")
                        profileRow(leading: "#", title: "\(groups.count) groups", detail: "\(expenses.count) expenses")
                    }
                    accountSection

                }
                .padding(22)
            }
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .onAppear {
            hasUsernameSession = UsernameIdentityService.hasStoredSession
            loadCurrentProfileIfNeeded()
        }
        .onChange(of: currentUsers.count) { loadCurrentProfileIfNeeded() }
        .task(id: groups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
            await serverLedger.refresh(groups: groups)
        }
        .alert("Sign out of BillBandit?", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { signOut() }
        } message: {
            Text("You will need to sign in with Apple again before using the app.")
        }
        .alert("Delete your BillBandit account?", isPresented: $showDeleteAccountConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) { deleteAccount() }
        } message: {
            Text("This permanently removes your account and personal data. Shared ledger amounts remain for the other members, with your profile and authored text anonymized.")
        }
    }

    private var sharedLedgerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            BrandSectionLabel("SHARED LEDGER")
            if let presentation = serverLedger.accountBalancePresentation() {
                profileRow(
                    leading: "↗",
                    title: presentation.label,
                    detail: "Shared balances"
                )
                ServerLedgerSurfaceStatusView(ledger: serverLedger, onLight: true) {
                    Task { await serverLedger.refresh(groups: groups) }
                }
            } else {
                HStack(spacing: 9) {
                    ServerLedgerUnavailableChip(
                        onLight: true,
                        isLoading: serverLedger.status.phase == .loading
                    )
                    Spacer(minLength: 0)
                }
                ServerLedgerSurfaceStatusView(ledger: serverLedger, includeEmpty: true, onLight: true) {
                    Task { await serverLedger.refresh(groups: groups) }
                }
            }
            if !localGroups.isEmpty {
                Text("On-device-only groups remain separate from the shared ledger.")
                    .font(BrandFont.type(9.5, bold: true))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.62))
            }
        }
    }

    private var avatarPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandSectionLabel("CHOOSE YOUR AVATAR")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 12) {
                ForEach(ProfileAvatar.allCases) { avatar in
                    Button {
                        selectAvatar(avatar)
                    } label: {
                        ProfileAvatarView(avatar: avatar, size: 62,
                                          isSelected: selectedAvatar == avatar)
                            .frame(width: 68, height: 68)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(avatar.displayName) avatar")
                    .accessibilityIdentifier("profileAvatar-\(avatar.rawValue)")
                    .accessibilityAddTraits(selectedAvatar == avatar ? .isSelected : [])
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Color.Brand.cobalt, lineWidth: 2.5))
        }
    }

    private var gamificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrandSectionLabel("LEVEL & ACHIEVEMENTS")
                Spacer()
                Button(action: toggleProgress) {
                    ZStack {
                        Capsule()
                            .fill(progressEnabled ? Color.Brand.cobalt : Color.Brand.creamSoft)
                        Text(progressEnabled ? "ON" : "OFF")
                            .font(BrandFont.type(8, bold: true))
                            .foregroundStyle(progressEnabled ? Color.Brand.creamSoft : Color.Brand.cobalt)
                            .offset(x: progressEnabled ? -9 : 9)
                        Circle()
                            .fill(progressEnabled ? Color.Brand.creamSoft : Color.Brand.cobalt)
                            .frame(width: 20, height: 20)
                            .offset(x: progressEnabled ? 13 : -13)
                    }
                    .frame(width: 54, height: 28)
                    .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))
                    .animation(reduceMotion ? nil : BrandMotion.progressReveal,
                               value: progressEnabled)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(progressEnabled ? "Turn progress rewards off" : "Turn progress rewards on")
                .accessibilityIdentifier("progressRewardsToggle")
            }

            VerticalCollapseLayout(progress: progressEnabled ? 1 : 0) {
                VStack(alignment: .leading, spacing: 6) {
                    levelProgressCard
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 11) {
                            ForEach(StarterAchievement.allCases) { achievement in
                                StarterPinView(achievement: achievement,
                                               isUnlocked: hasUnlocked(achievement))
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("achievementPinShelf")
                    .accessibilityHidden(!progressEnabled)
                }
            }
            .clipped()
            .opacity(progressEnabled ? 1 : 0)
            .allowsHitTesting(progressEnabled)
            .accessibilityHidden(!progressEnabled)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : BrandMotion.progressReveal,
                   value: progressEnabled)
    }

    private var levelProgressCard: some View {
        let level = ProgressLevel.level(for: lifetimeXP)
        let next = level.nextThreshold
        let progress: CGFloat
        if let next {
            progress = CGFloat(lifetimeXP - level.minimumXP) /
                CGFloat(next - level.minimumXP)
        } else {
            progress = 1
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Text("\(level.rawValue)")
                    .font(BrandFont.display(20, weight: .bold))
                    .foregroundStyle(Color.Brand.creamSoft)
                    .frame(width: 44, height: 44)
                    .background(Color.Brand.cobalt, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Level \(level.rawValue) · \(level.title)")
                        .font(BrandFont.display(15, weight: .bold))
                    Text(next.map { "\(lifetimeXP) / \($0) XP" } ?? "\(lifetimeXP) XP · top early level")
                        .font(BrandFont.type(9.5, bold: true))
                        .opacity(0.62)
                }
                Spacer()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Brand.cobalt.opacity(0.14))
                    Capsule().fill(Color.Brand.cobalt)
                        .frame(width: max(8, proxy.size.width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 9)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Color.Brand.cobalt, lineWidth: BrandOutline.control))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profileLevelCard")
    }

    private func hasUnlocked(_ achievement: StarterAchievement) -> Bool {
        guard let currentPersonID else { return false }
        return achievementUnlocks.contains {
            $0.personID == currentPersonID && $0.achievement == achievement
        }
    }

    private func toggleProgress() {
        UISelectionFeedbackGenerator().selectionChanged()
        guard let currentPersonID else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : BrandMotion.progressReveal) {
            if let currentProgress {
                currentProgress.isEnabled.toggle()
            } else {
                context.insert(UserProgress(personID: currentPersonID, isEnabled: false))
            }
        }
        try? context.save()
    }

    private var appleAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionLabel("APPLE ACCOUNT")
            if appleUserIdentifier.isEmpty || !hasUsernameSession {
                if !appleUserIdentifier.isEmpty {
                    Text("Reconnect Apple to verify your unique handle.")
                        .font(BrandFont.type(9.5, bold: true))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.65))
                }
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(Capsule())
                .accessibilityIdentifier("signInWithAppleButton")
                .allowsHitTesting(!isSavingUsername)
            } else {
                HStack(spacing: 12) {
                    Text("")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(Color.Brand.creamSoft)
                        .background(Color.Brand.cobalt, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in with Apple")
                            .font(BrandFont.body(13.5, weight: .bold))
                        if !applePrivateEmail.isEmpty {
                            Text(applePrivateEmail)
                                .font(BrandFont.type(9.5))
                                .lineLimit(1)
                                .opacity(0.58)
                        }
                    }
                    Spacer()
                    Button("Sign out") { showSignOutConfirmation = true }
                    .font(BrandFont.type(9.5, bold: true))
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.horizontal, 14)
                .frame(height: 62)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Brand.cobalt, lineWidth: 2))
            }
            if let authMessage {
                Text(authMessage)
                    .font(BrandFont.type(9.5, bold: true))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.65))
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            BrandSectionLabel("ACCOUNT")
            VStack(alignment: .leading, spacing: 10) {
                Text("Permanently remove your account and personal data.")
                    .font(BrandFont.type(9.5, bold: true))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.64))

                Button {
                    showDeleteAccountConfirmation = true
                } label: {
                    Label(
                        isDeletingAccount ? "Deleting account…" : "Delete account",
                        systemImage: "trash"
                    )
                    .font(BrandFont.body(14, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 58)
                }
                .foregroundStyle(.red)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.red, lineWidth: 2)
                )
                .buttonStyle(.plain)
                .disabled(isDeletingAccount)
                .accessibilityLabel("Delete account")
                .accessibilityHint("Permanently deletes your account and personal data")
                .accessibilityIdentifier("deleteAccountButton")
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            BrandSectionLabel("LEGAL & SUPPORT")
            VStack(spacing: 8) {
                Link(destination: BillBanditLegalLinks.privacyPolicy) {
                    legalRow(title: "Privacy Policy", detail: "How BillBandit handles your data")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("privacyPolicyLink")

                Link(destination: BillBanditLegalLinks.support) {
                    legalRow(title: "Support", detail: "Get help or contact us")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("supportLink")
            }
        }
    }

    private func legalRow(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text("↗")
                .font(BrandFont.display(18, weight: .bold))
                .frame(width: 38, height: 38)
                .background(Color.Brand.cobalt)
                .foregroundStyle(Color.Brand.creamSoft)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandFont.body(14, weight: .bold))
                Text(detail)
                    .font(BrandFont.type(9.5, bold: true))
                    .opacity(0.58)
            }
            Spacer()
            Text("→")
                .font(BrandFont.body(17, weight: .bold))
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Brand.cobalt, lineWidth: 2))
    }

    private func profileRow(leading: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(leading)
                .font(BrandFont.display(18, weight: .bold))
                .frame(width: 38, height: 38)
                .background(Color.Brand.cobalt)
                .foregroundStyle(Color.Brand.creamSoft)
                .clipShape(Circle())
            Text(title)
                .font(BrandFont.body(14, weight: .bold))
            Spacer()
            Text(detail)
                .font(BrandFont.type(11, bold: true))
                .opacity(0.58)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(.horizontal, 14)
        .frame(height: 58)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Brand.cobalt, lineWidth: 2))
    }

    private func beginNameEdit() {
        guard !isSavingUsername else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        authMessage = nil
        isEditingName = true
    }

    private func commitNameEdit() {
        guard isEditingName else { return }
        isEditingName = false
        guard !trimmedName.isEmpty else {
            name = currentUsers.first?.name ?? "You"
            return
        }
        let handle: UsernameHandle
        do {
            handle = try UsernameHandle(trimmedName)
        } catch {
            name = currentUsers.first?.name ?? "You"
            authMessage = error.localizedDescription
            return
        }
        guard hasUsernameSession else {
            name = currentUsers.first?.name ?? "You"
            authMessage = "Reconnect your Apple account before changing your username."
            return
        }

        isSavingUsername = true
        Task { @MainActor in
            defer { isSavingUsername = false }
            do {
                let confirmedHandle = try await UsernameIdentityService.rename(handle)
                let activePerson = AccountProfileIntegrity.canonicalize(
                    appleUserIdentifier: appleUserIdentifier,
                    cloudUserRecordName: nil,
                    context: context
                )
                activePerson.name = confirmedHandle
                activePerson.profileUpdatedAt = .now
                try context.save()
                name = confirmedHandle
                usernameHandleVerified = true
                authMessage = nil
                CloudCollaborationService.shared.currentPersonDidChange()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                name = currentUsers.first?.name ?? "You"
                hasUsernameSession = UsernameIdentityService.hasStoredSession
                authMessage = error.localizedDescription
            }
        }
    }

    private func loadCurrentProfileIfNeeded() {
        guard let current = currentUsers.first else { return }
        if trimmedName.isEmpty { name = current.name }
        selectedAvatar = current.profileAvatar
    }

    private func selectAvatar(_ avatar: ProfileAvatar) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
            selectedAvatar = avatar
        }
    }

    private func confirmAvatarSelection() {
        let activePerson = AccountProfileIntegrity.canonicalize(
            appleUserIdentifier: appleUserIdentifier,
            cloudUserRecordName: nil,
            context: context
        )
        activePerson.profileAvatar = selectedAvatar
        activePerson.profileUpdatedAt = .now
        try? context.save()
        CloudCollaborationService.shared.currentPersonDidChange()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
            showAvatarPicker = false
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        Task { @MainActor in
            await finishAppleSignIn(result)
        }
    }

    @MainActor
    private func finishAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken else {
                authMessage = "Apple could not return an account credential."
                return
            }
            let fullName = credential.fullName.flatMap {
                let value = PersonNameComponentsFormatter().string(from: $0)
                return value.isEmpty ? nil : value
            }
            isSavingUsername = true
            defer { isSavingUsername = false }
            do {
                let remoteUser = try await UsernameIdentityService.authenticateWithApple(
                    identityToken: identityToken,
                    authorizationCode: credential.authorizationCode,
                    name: fullName,
                    email: credential.email
                )
                ServerLedgerSurfaceStore.shared.accountDidAuthenticate(remoteUser.id)
                deferNextAppleCredentialStateCheck = true
                appleUserIdentifier = credential.user
                accountOnboardingComplete = true
                hasUsernameSession = true
                if let email = credential.email { applePrivateEmail = email }
                let profile = AccountProfileIntegrity.canonicalize(
                    appleUserIdentifier: credential.user,
                    cloudUserRecordName: nil,
                    context: context
                )
                profile.appleSessionStateRaw = "active"
                if let username = remoteUser.username, !username.isEmpty {
                    profile.name = username
                    profile.profileUpdatedAt = .now
                    usernameHandleVerified = true
                }
                try context.save()
                name = profile.name
                selectedAvatar = profile.profileAvatar
                authMessage = remoteUser.username == nil
                    ? "Apple connected. Choose your unique username above."
                    : "Apple account connected securely."
                Task { await CloudCollaborationService.shared.accountDidChange() }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                hasUsernameSession = false
                authMessage = error.localizedDescription
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                authMessage = "Apple sign in could not be completed."
            }
        }
    }

    private func signOut() {
        ServerLedgerSurfaceStore.shared.accountDidSignOut()
        for person in currentUsers where person.appleUserIdentifier == appleUserIdentifier {
            person.appleSessionStateRaw = "userSignedOut"
        }
        try? context.save()
        appleUserIdentifier = ""
        applePrivateEmail = ""
        accountOnboardingComplete = false
        usernameHandleVerified = false
        hasUsernameSession = false
        UsernameIdentityService.signOut()
        CloudCollaborationService.shared.accountDidSignOut()
        authMessage = nil
    }

    private func deleteAccount() {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        authMessage = nil
        Task { @MainActor in
            do {
                await CloudCollaborationService.shared.deleteAccountData()
                try await UsernameIdentityService.deleteAccount()
                ServerLedgerSurfaceStore.shared.accountDidSignOut()
                CloudCollaborationService.shared.accountDidSignOut()
                try LocalAccountDataCleanup.deleteAll(context: context)
                appleUserIdentifier = ""
                applePrivateEmail = ""
                accountOnboardingComplete = false
                usernameHandleVerified = false
                deferNextAppleCredentialStateCheck = false
                hasUsernameSession = false
                name = ""
                selectedAvatar = .sunglasses
                isDeletingAccount = false
                authMessage = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                isDeletingAccount = false
                hasUsernameSession = UsernameIdentityService.hasStoredSession
                authMessage = error.localizedDescription
            }
        }
    }
}

private struct StarterPinView: View {
    let achievement: StarterAchievement
    let isUnlocked: Bool

    var body: some View {
        VStack(spacing: 5) {
            AchievementBadgeView(achievement: achievement, isUnlocked: isUnlocked)
            Text(achievement.title)
                .font(BrandFont.body(10, weight: .extraBold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(isUnlocked ? "unlocked" : achievement.requirement)
                .font(BrandFont.type(8, bold: true))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .opacity(0.62)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .frame(width: 116, height: 142, alignment: .top)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(achievement.title), \(isUnlocked ? "unlocked" : achievement.requirement)")
        .accessibilityIdentifier("achievement-\(achievement.rawValue)")
    }
}

private enum MascotMotionIdea: Int, CaseIterable, Identifiable {
    case blink, wave, hop, crossfade, peek, look, feedback, tap, unlock, parallax
    case billFidget, overdueRing, couchSearch, sleepyDoze

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .blink: return "Blink + eye dart"
        case .wave: return "Tail + hand wave"
        case .hop: return "Save hop"
        case .crossfade: return "Pose crossfade"
        case .peek: return "Card peek"
        case .look: return "Look at the change"
        case .feedback: return "Shake + nod"
        case .tap: return "Tap reaction"
        case .unlock: return "Pin unlock"
        case .parallax: return "Scroll parallax"
        case .billFidget: return "Receipt fidget"
        case .overdueRing: return "Overdue bell ring"
        case .couchSearch: return "Couch search sweep"
        case .sleepyDoze: return "Sleepy breathing"
        }
    }

    var placement: String {
        switch self {
        case .blink: return "Home, Profile and quiet empty states"
        case .wave: return "Add Friend, welcomes and invitations"
        case .hop: return "After saving an expense, group or friend"
        case .crossfade: return "Thinking → celebrating after a completed action"
        case .peek: return "Behind invoice cards and group empty states"
        case .look: return "When a balance changes or an expense row arrives"
        case .feedback: return "Shake for validation; nod for successful input"
        case .tap: return "Optional delight on Profile and empty-state mascots"
        case .unlock: return "First-time achievement and level-up moments"
        case .parallax: return "Onboarding and the tall group invoice"
        case .billFidget: return "Split review, pending receipts and expense drafts"
        case .overdueRing: return "Payment reminders, overdue dues and settle-up nudges"
        case .couchSearch: return "Searching expenses or friends and empty results"
        case .sleepyDoze: return "No activity, all settled and quiet empty states"
        }
    }

    var fidelity: String {
        switch self {
        case .blink, .wave, .look: return "Layered art needed for final"
        case .billFidget: return "Separate receipt layer recommended for final"
        case .overdueRing: return "Separate bell/arm layer recommended for final"
        default: return "Works with current pose assets"
        }
    }
}

private struct MascotMotionLabScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: MascotMotionIdea = .blink
    @State private var replayToken = 0

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let marker = arguments.firstIndex(of: "-motionLabIdea"),
           arguments.indices.contains(marker + 1),
           let rawValue = Int(arguments[marker + 1]),
           let idea = MascotMotionIdea(rawValue: rawValue) {
            _selected = State(initialValue: idea)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "Motion lab") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    selector

                    MotionPrototypeStage(idea: selected)
                        .id("\(selected.rawValue)-\(replayToken)-\(reduceMotion)")
                        .frame(height: 330)
                        .frame(maxWidth: .infinity)
                        .background(Color.Brand.cobalt,
                                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .onTapGesture { replay() }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(selected.title)
                                .font(BrandFont.display(19, weight: .bold))
                            Spacer()
                            Text("\(selected.rawValue + 1) / \(MascotMotionIdea.allCases.count)")
                                .font(BrandFont.type(10, bold: true))
                        }
                        Text(selected.placement)
                            .font(BrandFont.body(13, weight: .bold))
                        Text(selected.fidelity)
                            .font(BrandFont.type(10, bold: true))
                            .opacity(0.58)
                        if reduceMotion {
                            Text("Reduce Motion is on · this preview stays still")
                                .font(BrandFont.type(10, bold: true))
                                .opacity(0.58)
                        }
                    }
                    .foregroundStyle(Color.Brand.cobalt)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button("Previous") { move(-1) }
                            .motionLabButton(filled: false)
                        Button("Replay") { replay() }
                            .motionLabButton(filled: true)
                        Button("Next") { move(1) }
                            .motionLabButton(filled: false)
                    }
                }
                .padding(20)
            }
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
    }

    private var selector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MascotMotionIdea.allCases) { idea in
                        Button {
                            selected = idea
                            replayToken += 1
                        } label: {
                            Text("\(idea.rawValue + 1)")
                                .font(BrandFont.type(11, bold: true))
                                .foregroundStyle(selected == idea ? Color.Brand.creamSoft : Color.Brand.cobalt)
                                .frame(width: 40, height: 40)
                                .background(selected == idea ? Color.Brand.cobalt : .clear, in: Circle())
                                .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .id(idea.id)
                        .accessibilityLabel(idea.title)
                        .accessibilityAddTraits(selected == idea ? .isSelected : [])
                    }
                }
            }
            .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
            .onChange(of: selected) {
                withAnimation(reduceMotion ? nil : BrandMotion.quick) {
                    proxy.scrollTo(selected.id, anchor: .center)
                }
            }
        }
    }

    private func replay() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        replayToken += 1
    }

    private func move(_ direction: Int) {
        let ideas = MascotMotionIdea.allCases
        let next = (selected.rawValue + direction + ideas.count) % ideas.count
        selected = ideas[next]
        replayToken += 1
    }
}

private extension View {
    func motionLabButton(filled: Bool) -> some View {
        self
            .font(BrandFont.display(12.5, weight: .bold))
            .foregroundStyle(filled ? Color.Brand.creamSoft : Color.Brand.cobalt)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(filled ? Color.Brand.cobalt : .clear, in: Capsule())
            .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2.5))
            .buttonStyle(.plain)
    }
}

private struct MotionPrototypeStage: View {
    let idea: MascotMotionIdea
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            prototype(elapsed: reduceMotion ? 4 : timeline.date.timeIntervalSince(startedAt))
        }
        .clipped()
        .onAppear { startedAt = .now }
        .accessibilityLabel("Live preview: \(idea.title)")
    }

    @ViewBuilder
    private func prototype(elapsed t: Double) -> some View {
        switch idea {
        case .blink:
            blinkPrototype(t)
        case .wave:
            wavePrototype(t)
        case .hop:
            hopPrototype(t)
        case .crossfade:
            crossfadePrototype(t)
        case .peek:
            peekPrototype(t)
        case .look:
            lookPrototype(t)
        case .feedback:
            feedbackPrototype(t)
        case .tap:
            tapPrototype(t)
        case .unlock:
            unlockPrototype(t)
        case .parallax:
            parallaxPrototype(t)
        case .billFidget:
            billFidgetPrototype(t)
        case .overdueRing:
            overdueRingPrototype(t)
        case .couchSearch:
            couchSearchPrototype(t)
        case .sleepyDoze:
            sleepyDozePrototype(t)
        }
    }

    private func blinkPrototype(_ t: Double) -> some View {
        let blink = max(pulse(t, center: 0.78, width: 0.13),
                        pulse(t, center: 1.05, width: 0.11))
        let dart = smooth(t, start: 1.35, duration: 0.4)
        return ZStack {
            MascotView(mascot: .greeting, size: 235, idle: false)
                .offset(x: 4 * dart)
            HStack(spacing: 13) {
                eyelid(blink)
                eyelid(blink)
            }
            .offset(x: -2 + 4 * dart, y: -79)
            .opacity(blink)
        }
    }

    private func eyelid(_ amount: Double) -> some View {
        ZStack {
            Capsule().fill(Color.Brand.cobalt).frame(width: 17, height: 14)
            Capsule().fill(Color.Brand.creamSoft).frame(width: 11, height: max(2, 3 * amount))
        }
    }

    private func wavePrototype(_ t: Double) -> some View {
        let envelope = smooth(t, start: 0.25, duration: 0.25) * (1 - smooth(t, start: 2.0, duration: 0.35))
        let swing = sin(t * 10) * 3.8 * envelope
        return MascotView(mascot: .greeting, size: 240, idle: false)
            .rotationEffect(.degrees(swing), anchor: .bottomTrailing)
            .offset(y: -abs(swing) * 0.7)
    }

    private func hopPrototype(_ t: Double) -> some View {
        let p = smooth(t, start: 0.35, duration: 1.0)
        let lift = sin(Double.pi * p)
        let landing = pulse(t, center: 1.38, width: 0.2)
        return MascotView(mascot: .thinking, size: 235, idle: false)
            .scaleEffect(x: 1 + 0.08 * landing, y: 1 - 0.09 * landing, anchor: .bottom)
            .offset(y: -42 * lift)
    }

    private func crossfadePrototype(_ t: Double) -> some View {
        let p = smooth(t, start: 0.55, duration: 0.8)
        return ZStack {
            MascotView(mascot: .thinking, size: 230, idle: false)
                .opacity(1 - p)
                .scaleEffect(1 - 0.08 * p)
                .rotationEffect(.degrees(-4 * p))
            MascotView(mascot: .celebrating, size: 245, idle: false)
                .opacity(p)
                .scaleEffect(0.82 + 0.18 * p)
                .rotationEffect(.degrees(5 * (1 - p)))
        }
    }

    private func peekPrototype(_ t: Double) -> some View {
        let p = backEase(smooth(t, start: 0.3, duration: 1.0))
        return ZStack(alignment: .bottom) {
            MascotView(mascot: .confused, size: 205, idle: false)
                .offset(x: -82 + 82 * p, y: 12)
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.Brand.creamSoft)
                .frame(width: 275, height: 92)
                .overlay(Text("NEW EXPENSE")
                    .font(BrandFont.type(13, bold: true))
                    .foregroundStyle(Color.Brand.cobalt))
                .offset(y: 88)
        }
    }

    private func lookPrototype(_ t: Double) -> some View {
        let p = smooth(t, start: 0.35, duration: 0.65)
        return ZStack {
            MascotView(mascot: .neutral, size: 225, idle: false)
                .rotationEffect(.degrees(4.5 * p), anchor: .bottom)
                .offset(x: 10 * p)
            Text("₹142")
                .font(BrandFont.type(23, bold: true))
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Color.Brand.creamSoft, in: Capsule())
                .scaleEffect(0.8 + 0.2 * p)
                .opacity(p)
                .offset(x: 105, y: -95)
        }
    }

    private func feedbackPrototype(_ t: Double) -> some View {
        let shakeEnvelope = max(0, 1 - abs(t - 0.75) / 0.5)
        let shake = sin(t * 38) * 11 * shakeEnvelope
        let nodP = smooth(t, start: 1.35, duration: 0.75)
        let nod = -sin(Double.pi * nodP) * 12
        return MascotView(mascot: t < 1.3 ? .grumpy : .neutral, size: 230, idle: false)
            .offset(x: shake, y: nod)
            .rotationEffect(.degrees(shake * 0.18))
    }

    private func tapPrototype(_ t: Double) -> some View {
        let ring = smooth(t, start: 0.3, duration: 0.7)
        let pop = pulse(t, center: 0.58, width: 0.35)
        return ZStack {
            Circle()
                .stroke(Color.Brand.creamSoft.opacity(1 - ring), lineWidth: 3)
                .frame(width: 95 + 130 * ring, height: 95 + 130 * ring)
            MascotView(mascot: .neutral, size: 230, idle: false)
                .scaleEffect(1 + 0.12 * pop, anchor: .bottom)
                .rotationEffect(.degrees(-3 * pop))
            Text("tap to replay")
                .font(BrandFont.type(10, bold: true))
                .foregroundStyle(Color.Brand.creamSoft.opacity(0.7))
                .offset(y: 140)
        }
    }

    private func unlockPrototype(_ t: Double) -> some View {
        let p = backEase(smooth(t, start: 0.25, duration: 0.9))
        return ZStack {
            ForEach(0..<10, id: \.self) { index in
                Circle()
                    .fill(index.isMultiple(of: 2) ? Color.Brand.creamSoft : .yellow)
                    .frame(width: 8, height: 8)
                    .offset(x: cos(Double(index) * .pi / 5) * 125 * p,
                            y: sin(Double(index) * .pi / 5) * 125 * p)
                    .opacity(p)
            }
            MascotView(mascot: .celebrating, size: 230, idle: false)
                .scaleEffect(0.55 + 0.45 * p)
                .rotationEffect(.degrees(-10 + 10 * p))
            Text("PIN UNLOCKED")
                .font(BrandFont.type(12, bold: true))
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Color.Brand.creamSoft, in: Capsule())
                .opacity(p)
                .offset(y: 134)
        }
    }

    private func parallaxPrototype(_ t: Double) -> some View {
        let travel = sin(t * 1.35)
        return ZStack {
            VStack(spacing: 17) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.Brand.creamSoft.opacity(0.15))
                        .frame(width: 275 - CGFloat(index % 2) * 35, height: 30)
                }
            }
            .offset(y: travel * 20)
            MascotView(mascot: .greeting, size: 220, idle: false)
                .offset(x: travel * 12, y: -travel * 14)
                .rotationEffect(.degrees(travel * 1.7), anchor: .bottom)
        }
    }

    private func billFidgetPrototype(_ t: Double) -> some View {
        let worry = sin(t * 14) * max(0, 1 - abs(t - 1.0) / 0.85)
        let exhale = sin(t * 2.1)
        return ZStack {
            MascotSceneView(scene: .bill, width: 280)
                .scaleEffect(x: 1 - exhale * 0.006, y: 1 + exhale * 0.012, anchor: .bottom)
                .rotationEffect(.degrees(worry * 0.75), anchor: .bottom)
                .offset(x: worry * 1.5, y: 10)

            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.Brand.creamSoft.opacity(0.8))
                    .frame(width: 13, height: 2)
                    .rotationEffect(.degrees(Double(index - 1) * 24))
                    .offset(x: CGFloat(index - 1) * 18, y: -47 + abs(worry) * -2)
                    .opacity(abs(worry) * 0.75)
            }
        }
    }

    private func overdueRingPrototype(_ t: Double) -> some View {
        let envelope = max(0, 1 - abs(t - 1.05) / 0.9)
        let ring = sin(t * 17) * envelope
        let echo = smooth(t, start: 0.35, duration: 1.15)
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.Brand.creamSoft.opacity((1 - echo) * 0.6), lineWidth: 2)
                    .frame(width: 45 + CGFloat(index) * 24 + echo * 45,
                           height: 45 + CGFloat(index) * 24 + echo * 45)
                    .offset(x: -88, y: -75)
            }

            MascotSceneView(scene: .overdue, width: 270)
                .rotationEffect(.degrees(ring * 2.4), anchor: .bottom)
                .offset(x: ring * 2, y: 8)
        }
    }

    private func couchSearchPrototype(_ t: Double) -> some View {
        let sweep = sin(t * 1.8)
        return ZStack {
            MascotSceneView(scene: .searching, width: 300)
                .rotationEffect(.degrees(sweep * 1.3), anchor: .bottom)
                .offset(x: sweep * 11, y: 12)

            Circle()
                .fill(Color.Brand.creamSoft.opacity(0.12))
                .frame(width: 115, height: 115)
                .blur(radius: 3)
                .offset(x: sweep * 105, y: 38)
        }
    }

    private func sleepyDozePrototype(_ t: Double) -> some View {
        let breath = (sin(t * 1.65) + 1) / 2
        return ZStack {
            MascotSceneView(scene: .sleepy, width: 310)
                .scaleEffect(x: 1 + breath * 0.006,
                             y: 0.99 + breath * 0.018,
                             anchor: .bottom)
                .offset(y: 18 - breath * 2)

            ForEach(0..<3, id: \.self) { index in
                let phase = (t * 0.28 + Double(index) * 0.27).truncatingRemainder(dividingBy: 1)
                Text("Z")
                    .font(BrandFont.display(13 + CGFloat(index) * 3, weight: .bold))
                    .foregroundStyle(Color.Brand.creamSoft)
                    .opacity(1 - phase)
                    .offset(x: 13 + CGFloat(index) * 18 + phase * 20,
                            y: -56 - phase * 78)
            }
        }
    }

    private func pulse(_ t: Double, center: Double, width: Double) -> Double {
        max(0, 1 - abs(t - center) / width)
    }

    private func smooth(_ t: Double, start: Double, duration: Double) -> Double {
        let p = max(0, min(1, (t - start) / duration))
        return p * p * (3 - 2 * p)
    }

    private func backEase(_ p: Double) -> Double {
        let c = 1.45
        let x = p - 1
        return 1 + (c + 1) * x * x * x + c * x * x
    }
}

private struct GroupCard: View {
    let group: Group
    let balanceText: String?
    let balanceIsPositive: Bool
    let sourceLabel: String
    var balanceIsLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Circle()
                .fill(Color.Brand.cobalt)
                .frame(width: 34, height: 34)
                .overlay(BrandIconView(icon: group.icon.icon, size: 17)
                    .foregroundStyle(Color.Brand.creamSoft))
            Text(group.name)
                .font(BrandFont.display(13.5, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 2)
            if let balanceText {
                BalancePill(
                    text: balanceText,
                    filled: balanceIsPositive
                )
            } else {
                ServerLedgerUnavailableChip(onLight: true, isLoading: balanceIsLoading)
            }
            Text(sourceLabel)
                .font(BrandFont.type(8.5, bold: true))
                .opacity(0.56)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(11)
        .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ServerLedgerActivityRow: View {
    let item: ServerLedgerSurfaceActivityItem
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(compact ? Color.Brand.cobalt : Color.Brand.creamSoft)
                .frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.type) in \(item.groupName)")
                    .font(BrandFont.type(compact ? 10.5 : 12, bold: true))
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    Text(item.at.formatted(date: .omitted, time: .shortened))
                        .font(BrandFont.type(9))
                        .opacity(0.55)
                }
            }
            Spacer(minLength: 4)
            Text(item.amount.absoluteDisplayText)
                .font(BrandFont.type(compact ? 9.5 : 10.5, bold: true))
                .lineLimit(1)
        }
        .padding(.vertical, compact ? 6 : 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill((compact ? Color.Brand.cobalt : Color.Brand.creamSoft).opacity(0.14)).frame(height: 1)
        }
    }
}

struct ActivityScreen: View {
    @Query(sort: \ActivityItem.timestamp, order: .reverse) private var items: [ActivityItem]
    @Query private var groups: [Group]
    @ObservedObject private var serverLedger = ServerLedgerSurfaceStore.shared

    private var sharedGroups: [Group] {
        groups.filter { $0.serverLedgerGroupID != nil }
    }

    private var localItems: [ActivityItem] {
        items.filter { item in
            guard let groupID = item.groupID else { return true }
            return groups.first(where: { $0.id == groupID })?.serverLedgerGroupID == nil
        }
    }

    private var localSections: [ActivitySection] {
        ActivitySectioning.sections(from: localItems)
    }

    private var sharedItems: [ServerLedgerSurfaceActivityItem] {
        serverLedger.snapshot?.activity ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("recent activity ")
                        .font(BrandFont.hand(21, weight: .bold))
                        .padding(.bottom, 2)
                    if !sharedGroups.isEmpty {
                        Text("shared ledger")
                            .font(BrandFont.type(10, bold: true))
                            .opacity(0.68)
                        ServerLedgerSurfaceStatusView(ledger: serverLedger) {
                            Task { await serverLedger.refresh(groups: groups) }
                        }
                        if sharedItems.isEmpty {
                            if serverLedger.snapshot == nil {
                                ServerLedgerSurfaceStatusView(ledger: serverLedger, includeEmpty: true) {
                                    Task { await serverLedger.refresh(groups: groups) }
                                }
                            } else {
                                Text("no shared activity yet")
                                    .font(BrandFont.type(11))
                                    .opacity(0.62)
                            }
                        } else {
                            ForEach(Array(sharedItems.prefix(20))) { item in
                                ServerLedgerActivityRow(item: item)
                            }
                        }
                    }
                    if !localItems.isEmpty {
                        Text("on-device activity")
                            .font(BrandFont.type(10, bold: true))
                            .opacity(0.68)
                            .padding(.top, 8)
                        ForEach(localSections) { section in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(section.date.map(dayLabel) ?? "Earlier activity")
                                    .font(BrandFont.display(13, weight: .bold))
                                    .padding(.bottom, 7)
                                ForEach(section.items) { ActivityLedgerRow(item: $0) }
                            }
                        }
                    }
                    if sharedGroups.isEmpty && localItems.isEmpty {
                        VStack(spacing: 10) {
                            MascotView(mascot: .neutral, size: 160)
                            Text("nothing in the ledger yet ")
                                .font(BrandFont.hand(22, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                }
                .foregroundStyle(Color.Brand.creamSoft)
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(Color.Brand.cobalt)
            .navigationTitle("Activity")
            .task(id: groups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
                await serverLedger.refresh(groups: groups)
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}

struct ActivityLedgerRow: View {
    let item: ActivityItem
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(compact ? Color.Brand.cobalt : Color.Brand.creamSoft)
                .frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displaySummary)
                    .font(BrandFont.type(compact ? 10.5 : 12, bold: item.kind == .settlementRecorded))
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(BrandFont.type(9))
                        .opacity(0.55)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, compact ? 6 : 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill((compact ? Color.Brand.cobalt : Color.Brand.creamSoft).opacity(0.14)).frame(height: 1)
        }
    }
}

struct BalancePill: View {
    let text: String
    let filled: Bool
    var onDark = false
    var animationValue: Decimal? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(BrandFont.type(10, bold: true))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(filled || onDark ? Color.Brand.creamSoft : Color.Brand.cobalt)
            .background(filled ? Color.Brand.cobalt : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(onDark ? Color.Brand.creamSoft : Color.Brand.cobalt,
                                      lineWidth: filled ? 0 : 1.5))
            .contentTransition(.numericText(value: NSDecimalNumber(decimal: animationValue ?? 0).doubleValue))
            .animation(reduceMotion ? nil : BrandMotion.counter, value: text)
    }
}

private struct Squiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        let step = rect.width / 6
        for i in 0..<6 {
            path.addCurve(
                to: CGPoint(x: step * CGFloat(i + 1), y: rect.midY),
                control1: CGPoint(x: step * (CGFloat(i) + 0.25), y: i.isMultiple(of: 2) ? 0 : rect.height),
                control2: CGPoint(x: step * (CGFloat(i) + 0.75), y: i.isMultiple(of: 2) ? rect.height : 0)
            )
        }
        return path
    }
}
