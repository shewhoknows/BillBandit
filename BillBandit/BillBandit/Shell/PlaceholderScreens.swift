import SwiftUI
import SwiftData
import UIKit
import AuthenticationServices
import CryptoKit
import OSLog
import Security

private enum AppleSignInSupport {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.billbandit.app",
        category: "apple-sign-in"
    )
    private static let nonceCharacters = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
    )

    static func prepare(_ request: ASAuthorizationAppleIDRequest) -> String? {
        request.requestedScopes = [.fullName, .email]
        do {
            let nonce = try randomNonce()
            let hashedNonce = sha256(nonce)
            request.nonce = hashedNonce
            logger.info("Apple authorization requested nonce=true")
            return hashedNonce
        } catch {
            let nsError = error as NSError
            logger.error(
                "Apple nonce generation failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            return nil
        }
    }

    static func logCredential(_ credential: ASAuthorizationAppleIDCredential) {
        logger.info(
            "Apple credential received identityToken=\(credential.identityToken != nil) authorizationCode=\(credential.authorizationCode != nil) name=\(credential.fullName != nil) email=\(credential.email != nil)"
        )
    }

    static func logBackendExchangeStarted() {
        logger.info("BillBandit Apple credential exchange started")
    }

    static func logBackendExchangeSucceeded() {
        logger.info("BillBandit Apple credential exchange succeeded")
    }

    @discardableResult
    static func logFailure(_ error: Error, stage: String) -> String {
        let reference = String(UUID().uuidString.prefix(8)).uppercased()
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        logger.error(
            "Apple sign-in failed reference=\(reference, privacy: .public) stage=\(stage, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) underlyingDomain=\(underlying?.domain ?? "none", privacy: .public) underlyingCode=\(underlying?.code ?? 0, privacy: .public)"
        )
        return reference
    }

    private static func randomNonce(length: Int = 32) throws -> String {
        precondition(length > 0)
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }

            for byte in randomBytes where remaining > 0 {
                guard byte < UInt8(nonceCharacters.count) else { continue }
                result.append(nonceCharacters[Int(byte)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct OnboardingScreen: View {
    let onComplete: () -> Void
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appleUserIdentifier") private var appleUserIdentifier = ""
    @AppStorage("reviewAccountID") private var reviewAccountID = ""
    @AppStorage("applePrivateEmail") private var applePrivateEmail = ""
    @AppStorage("usernameHandleVerified") private var usernameHandleVerified = false
    @AppStorage("deferNextAppleCredentialStateCheck") private var deferNextAppleCredentialStateCheck = false
    /// Set when the app picks a handle for a new account; Home shows a
    /// one-time note so the person knows their handle and can change it.
    @AppStorage("showNewHandleNote") private var showNewHandleNote = false
    @State private var page = 0
    @State private var mascotRaised = false
    @State private var authMessage: String?
    @State private var isCompleting = false
    @State private var hasUsernameSession = UsernameIdentityService.hasStoredSession
    @State private var currentAppleNonce: String?
    @State private var isAuthorizingWithApple = false
    @State private var reviewCodeEnabled = false
    @State private var showReviewCode = false
    @State private var reviewCode = ""
    @State private var reviewCodeError = false
    @State private var isReviewSigningIn = false
    @FocusState private var reviewCodeFocused: Bool
    @State private var appleAuthorizationAttemptID = UUID()
    /// A returning Apple account already has a server-owned handle. Keep that
    /// value so we do not POST a second claim for it.
    @State private var authenticatedRemoteUsername: String?

    private static let lastPage = 2

    /// Every headline is two lines, so the headline and body sit at the same
    /// height on all three pages and nothing jumps when the user swipes.
    private let pages: [(Mascot, String, String)] = [
        (.greeting, "he used to steal.\nnow he settles.", "Meet the Bandit. Reformed, exact, and very serious about who owes what."),
        (.thinking, "every last coin accounted for.\nold habits.", "Split equally, exactly, by percentage or by shares. The Bandit checks every amount."),
        (.celebrating, "clean slate.\nno getaway needed.", "Record a payment and the Bandit closes the case."),
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

    private var needsAppleSignIn: Bool {
        (appleUserIdentifier.isEmpty || !hasUsernameSession ||
         isForcedSignedOutPreview) && !isForcedConnectedIncompletePreview
    }

    /// The name we start a new handle from: Apple's name on first sign-in,
    /// otherwise the name already saved on this device.
    private var savedPreferredName: String? {
        guard let name = currentUsers.first?.name, name != "You" else { return nil }
        return name
    }

    init(startAtSignIn: Bool = false, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-onboardingAuthBusyPreview") {
            _isAuthorizingWithApple = State(initialValue: true)
            _authMessage = State(initialValue: "Connecting to Apple…")
        } else if args.contains("-onboardingAuthErrorPreview") {
            _authMessage = State(initialValue: "Apple sign-in could not be completed. Try again.")
        }
        if let index = args.firstIndex(of: "-onboardingPage"), index + 1 < args.count,
           let requested = Int(args[index + 1]), (0...Self.lastPage).contains(requested) {
            _page = State(initialValue: requested)
        } else if startAtSignIn {
            _page = State(initialValue: Self.lastPage)
        }
    }

    var body: some View {
        ZStack {
            Color.Brand.cobalt
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("0\(page + 1) / 03")
                        .font(BrandFont.display(15, weight: .semibold))
                    Spacer()
                    if page < Self.lastPage {
                        Button("Skip") {
                            withAnimation(onboardingTransition) { page = Self.lastPage }
                        }
                        .font(BrandFont.body(12, weight: .extraBold))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .environment(\.dynamicTypeSize, dynamicTypeSize.isAccessibilitySize ? .xxxLarge : dynamicTypeSize)

                if !dynamicTypeSize.isAccessibilitySize {
                    HStack {
                        Text("BillBandit")
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .font(BrandFont.display(44, weight: .bold))
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    TabView(selection: $page) {
                        ForEach(0...Self.lastPage, id: \.self) { index in
                            onboardingPage(index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .clipped()

                    VStack(spacing: 0) {
                        Color.Brand.creamSoft.opacity(0.45)
                            .frame(height: 1)
                            .padding(.horizontal, 22)
                        bottomControls
                        pageIndicator
                    }
                    .background(Color.Brand.cobalt)
                    .environment(\.dynamicTypeSize, .xxxLarge)
                } else {
                    TabView(selection: $page) {
                        ForEach(0...Self.lastPage, id: \.self) { index in
                            onboardingPage(index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    bottomControls
                    pageIndicator
                }
            }
            .foregroundStyle(Color.Brand.creamSoft)
        }
        .onAppear {
            hasUsernameSession = UsernameIdentityService.hasStoredSession
            startMascotMotion()
        }
        .task(id: "\(page)-\(scenePhase)") {
            reviewCodeEnabled = false
            guard page == Self.lastPage, scenePhase == .active, needsAppleSignIn else { return }
            let enabled = await UsernameIdentityService.reviewCodeIsEnabled()
            guard !Task.isCancelled else { return }
            reviewCodeEnabled = enabled
        }
        .sheet(isPresented: $showReviewCode) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Review code")
                            .font(BrandFont.display(28, weight: .bold))
                        TextField("Review code", text: $reviewCode)
                            .font(BrandFont.body(16, weight: .semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($reviewCodeFocused)
                            .accessibilityIdentifier("reviewCodeField")
                            .padding(14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        if reviewCodeError {
                            Text("That code did not work.")
                                .font(BrandFont.body(14, weight: .semibold))
                                .accessibilityIdentifier("reviewCodeError")
                        }
                        Button(isReviewSigningIn ? "Signing in…" : "Sign in") {
                            Task { await signInWithReviewCode() }
                        }
                        .font(BrandFont.display(16, weight: .bold))
                        .foregroundStyle(Color.Brand.creamSoft)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.Brand.cobalt, in: Capsule())
                        .disabled(isReviewSigningIn)
                        .accessibilityIdentifier("reviewCodeSubmit")
                    }
                    .foregroundStyle(Color.Brand.cobalt)
                    .padding(24)
                }
                .background(Color.Brand.creamSoft.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showReviewCode = false }
                    }
                }
                .onAppear { reviewCodeFocused = true }
            }
        }
        .onChange(of: reduceMotion) {
            startMascotMotion()
        }
        .task(id: appleAuthorizationAttemptID) {
            guard isAuthorizingWithApple else { return }
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, isAuthorizingWithApple else { return }
            let error = NSError(domain: "BillBandit.AppleSignIn", code: 2)
            let reference = AppleSignInSupport.logFailure(error, stage: "callback-timeout")
            isAuthorizingWithApple = false
            currentAppleNonce = nil
            authMessage = "Apple sign-in didn't finish. Please try again. Reference \(reference)."
        }
        .task {
            guard isDemo else { return }
            for target in 1...Self.lastPage {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                withAnimation(onboardingTransition) {
                    page = target
                }
            }
        }
    }

    @ViewBuilder
    private func onboardingPage(_ index: Int) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        Text("BillBandit")
                            .font(BrandFont.display(20, weight: .bold))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .id("onboardingTop-\(index)")
                        Text(BrandFont.handText(pages[index].1))
                            .font(BrandFont.hand(28, weight: .bold))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("onboardingTitle-\(index)")
                        Text("Scroll for more ↓")
                            .font(BrandFont.body(12, weight: .semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        Text(pages[index].2)
                            .font(BrandFont.body(15, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 32)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("onboardingDescription-\(index)")
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: page) { _, selected in
                    if selected == index {
                        proxy.scrollTo("onboardingTop-\(index)", anchor: .top)
                    }
                }
            }
        } else {
            onboardingStandardPage(index)
        }
    }

    private func onboardingStandardPage(_ index: Int) -> some View {
        GeometryReader { geometry in
            // Small phones (and very large text) get a smaller raccoon so the
            // copy always fits. The same size is used on all three pages.
            let roomy = geometry.size.height >= 420
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                MascotView(mascot: pages[index].0, size: roomy ? 178 : 128, idle: false)
                    .offset(y: reduceMotion ? 0 : (mascotRaised ? -7 : 7))
                    .frame(height: roomy ? 194 : 142)
                    .accessibilityIdentifier("onboardingMascot-\(index)")
                Text(BrandFont.handText(pages[index].1))
                    .font(BrandFont.hand(28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                    .accessibilityIdentifier("onboardingTitle-\(index)")
                Text(pages[index].2)
                    .font(BrandFont.body(15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 66, alignment: .top)
                    .accessibilityIdentifier("onboardingDescription-\(index)")
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if page == Self.lastPage, let authMessage {
                Text(authMessage)
                    .font(BrandFont.body(12.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("onboardingAppleSignInMessage")
            }
            if page < Self.lastPage {
                nextButton
            } else {
                onboardingPrimaryAction
                if needsAppleSignIn {
                    ZStack {
                        Text("Have a review code?")
                            .hidden()
                            .accessibilityHidden(true)
                        if reviewCodeEnabled {
                            Button("Have a review code?") {
                                reviewCode = ""
                                reviewCodeError = false
                                showReviewCode = true
                            }
                            .accessibilityIdentifier("reviewCodeLink")
                        }
                    }
                    .font(BrandFont.body(12, weight: .semibold))
                    .foregroundStyle(Color.Brand.creamSoft)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var nextButton: some View {
        Button {
            withAnimation(onboardingTransition) {
                page = min(page + 1, Self.lastPage)
            }
        } label: {
            HStack(spacing: 8) {
                Text("Next")
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .font(BrandFont.display(15.5, weight: .bold))
            .foregroundStyle(Color.Brand.cobalt)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.Brand.creamSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next")
        .accessibilityIdentifier("onboardingNextButton")
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0...Self.lastPage, id: \.self) { index in
                Capsule()
                    .fill(Color.Brand.creamSoft.opacity(index == page ? 1 : 0.35))
                    .frame(width: index == page ? 24 : 7, height: 7)
                    .animation(reduceMotion ? nil : .spring(response: 0.35), value: page)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of 3")
        .accessibilityIdentifier("onboardingPageIndicator")
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var onboardingPrimaryAction: some View {
        if needsAppleSignIn {
            SignInWithAppleButton(.continue) { request in
                authMessage = "Connecting to Apple…"
                isAuthorizingWithApple = true
                appleAuthorizationAttemptID = UUID()
                currentAppleNonce = AppleSignInSupport.prepare(request)
            } onCompletion: { result in
                handleAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            .clipShape(Capsule())
            .accessibilityIdentifier("onboardingSignInWithAppleButton")
            .allowsHitTesting(!isCompleting && !isAuthorizingWithApple)
        } else {
            // Apple is connected but setup did not finish (for example, the
            // network dropped). This button finishes it and opens Home.
            Button {
                Task { await completeOnboarding(preferredName: savedPreferredName) }
            } label: {
                Text(isCompleting ? "Setting up…" : "Enter BillBandit")
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
    }

    private var onboardingTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.46)
    }

    @MainActor
    private func signInWithReviewCode() async {
        guard !isReviewSigningIn else { return }
        isReviewSigningIn = true
        defer { isReviewSigningIn = false }
        do {
            let user = try await UsernameIdentityService.authenticateWithReviewCode(reviewCode)
            guard user.id == "billbandit-review-account-v1",
                  let username = user.username else { throw UsernameIdentityService.ServiceError.missingSession }
            ServerLedgerSurfaceStore.shared.accountDidAuthenticate(user.id)
            let current = AccountProfileIntegrity.canonicalize(
                appleUserIdentifier: nil, cloudUserRecordName: nil, context: context
            )
            current.name = username
            current.appleSessionStateRaw = "active"
            try context.save()
            appleUserIdentifier = ""
            applePrivateEmail = ""
            reviewAccountID = user.id
            CloudCollaborationService.shared.beginReviewSession()
            usernameHandleVerified = true
            hasUsernameSession = true
            showReviewCode = false
            onComplete()
        } catch {
            reviewCodeError = true
        }
    }

    /// Finishes setup and opens Home. A returning account keeps its handle.
    /// A new account gets an automatic handle (from its name, or "bandit"
    /// plus digits); the person can change it later in Profile.
    @MainActor
    private func completeOnboarding(preferredName: String?) async {
        guard !appleUserIdentifier.isEmpty || isForcedConnectedIncompletePreview else {
            authMessage = "Connect your Apple account before entering BillBandit."
            return
        }
        guard hasUsernameSession || isForcedConnectedIncompletePreview else {
            authMessage = "Reconnect your Apple account before entering BillBandit."
            return
        }

        isCompleting = true
        defer { isCompleting = false }
        authMessage = "Setting up your ledger…"
        do {
            let confirmedHandle: String
            var isAutomaticHandle = true
            if let existingHandle = UsernameOnboardingHandlePolicy.existingHandle(
                remoteUsername: authenticatedRemoteUsername,
                isForcedPreview: isForcedConnectedIncompletePreview
            ) {
                confirmedHandle = existingHandle
                isAutomaticHandle = false
            } else if isForcedConnectedIncompletePreview {
                confirmedHandle = UsernameAutoHandle.candidates(from: preferredName).first?.value
                    ?? UsernameAutoHandle.fallbackBase
            } else {
                confirmedHandle = try await UsernameIdentityService.claimAutomaticHandle(
                    preferredName: preferredName
                )
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
            showNewHandleNote = isAutomaticHandle
            authMessage = nil
            Task { await CloudCollaborationService.shared.accountDidChange() }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onComplete()
        } catch {
            authMessage = error.localizedDescription
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        Task { @MainActor in
            await finishAppleSignIn(result)
        }
    }

    @MainActor
    private func finishAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard isAuthorizingWithApple else { return }
        isAuthorizingWithApple = false
        defer { currentAppleNonce = nil }
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken else {
                let error = NSError(domain: "BillBandit.AppleSignIn", code: 1)
                let reference = AppleSignInSupport.logFailure(error, stage: "credential")
                authMessage = "Apple did not return an account credential. Reference \(reference)."
                return
            }
            AppleSignInSupport.logCredential(credential)
            let fullName = credential.fullName.flatMap {
                let value = PersonNameComponentsFormatter().string(from: $0)
                return value.isEmpty ? nil : value
            }
            isCompleting = true
            authMessage = "Checking your Apple account…"
            do {
                AppleSignInSupport.logBackendExchangeStarted()
                let remoteUser = try await UsernameIdentityService.authenticateWithApple(
                    identityToken: identityToken,
                    authorizationCode: credential.authorizationCode,
                    nonce: currentAppleNonce,
                    name: fullName,
                    email: credential.email
                )
                AppleSignInSupport.logBackendExchangeSucceeded()
                ServerLedgerSurfaceStore.shared.accountDidAuthenticate(remoteUser.id)
                reviewAccountID = ""
                deferNextAppleCredentialStateCheck = true
                appleUserIdentifier = credential.user
                if let email = credential.email { applePrivateEmail = email }
                hasUsernameSession = true
                switch UsernameAccountReconciliationPolicy.decision(
                    remoteUsername: remoteUser.username
                ) {
                case .verified(let username):
                    authenticatedRemoteUsername = username
                case .requiresClaim:
                    authenticatedRemoteUsername = nil
                }
                isCompleting = false
                // Go straight to Home. No username step.
                await completeOnboarding(
                    preferredName: fullName ?? remoteUser.preferredName ?? remoteUser.name ?? savedPreferredName
                )
            } catch {
                isCompleting = false
                hasUsernameSession = false
                let reference = AppleSignInSupport.logFailure(error, stage: "backend")
                authMessage = "\(error.localizedDescription) Reference \(reference)."
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                authMessage = nil
            } else {
                let reference = AppleSignInSupport.logFailure(error, stage: "authorization")
                authMessage = "Apple sign-in could not be completed. Try again. Reference \(reference)."
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
    @AppStorage("showNewHandleNote") private var showNewHandleNote = false
    @AppStorage("reviewAccountID") private var reviewAccountID = ""

    init(onSeeAllGroups: @escaping () -> Void = {},
         onOpenActivity: @escaping () -> Void = {},
         unreadActivityCount: Int = 0,
         onOpenProfile: @escaping () -> Void = {}) {
        self.onSeeAllGroups = onSeeAllGroups
        self.onOpenActivity = onOpenActivity
        self.unreadActivityCount = unreadActivityCount
        self.onOpenProfile = onOpenProfile
    }

    private var visibleGroups: [Group] {
        groups.filter {
            $0.isVisible(toServerAccountID: serverLedger.activeAccountIdentifier)
        }
    }

    private var sharedGroups: [Group] {
        visibleGroups.filter { $0.serverLedgerGroupID != nil }
    }

    private var localGroups: [Group] {
        visibleGroups.filter { $0.serverLedgerGroupID == nil }
    }

    private var sharedGroupIDs: Set<String> {
        Set(sharedGroups.compactMap(\.serverLedgerGroupID))
    }

    private var canonicalBalanceSummaries: [ServerLedgerSurfaceAccountBalanceSummary]? {
        guard let snapshot = serverLedger.snapshot,
              snapshot.coversExactly(serverGroupIDs: sharedGroupIDs) else { return nil }
        return snapshot.accountBalanceSummaries
    }

    private var localActivity: [ActivityItem] {
        ActivityData.localItems(activity, groups: groups)
    }

    private var sharedActivity: [ServerLedgerSurfaceActivityItem] {
        serverLedger.snapshot?.activity ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if showNewHandleNote, let handle = currentUsers.first?.name,
                       !handle.isEmpty {
                        newHandleNote(handle)
                    }
                    balanceHeader
                    groupGrid
                    recentActivity
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
            .background(Color.Brand.cobalt)
            .fullScreenCover(isPresented: $showAddGroup) { AddGroupSheet() }
            .navigationDestination(for: Group.self) { group in
                GroupDetailScreen(group: group)
            }
            .navigationDestination(for: ServerLedgerSurfaceActivityItem.self) { item in
                SharedActivityDestination(item: item, groups: visibleGroups)
            }
            .task(id: visibleGroups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
                await serverLedger.refresh(groups: visibleGroups)
            }
        }
    }

    /// One-time note for a new account: shows the automatic handle.
    /// Tap opens Profile to change it; the cross closes the note.
    private func newHandleNote(_ handle: String) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
                    showNewHandleNote = false
                }
                onOpenProfile()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BrandFont.handText("you're @\(handle)."))
                        .font(BrandFont.hand(22, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Tap to change your handle in Profile.")
                        .font(BrandFont.body(13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("homeNewHandleNote")
            Button {
                withAnimation(BrandMotion.page(reduceMotion: reduceMotion)) {
                    showNewHandleNote = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("homeNewHandleNoteClose")
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 18))
        .padding(.bottom, 12)
        .transition(.opacity)
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
                            .font(BrandFont.type(11, bold: true))
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
        // An iPhone app in iPad compatibility mode can still report phone traits.
        // Clear the host window controls without shifting the iPhone layout.
        .padding(.top, UIDevice.current.model.hasPrefix("iPad") ? 40 : 8)
        .padding(.bottom, 10)
    }

    private var balanceHeader: some View {
        VStack(spacing: 16) {
            if !sharedGroups.isEmpty {
                if let summaries = canonicalBalanceSummaries {
                    if summaries.isEmpty {
                        canonicalSettledBalanceSummary
                    } else {
                        ForEach(summaries) { summary in
                            canonicalBalanceSummary(
                                summary,
                                showsCurrencyCode: summaries.count > 1
                            )
                        }
                        HomeDefaultCurrencyEstimate(summaries: summaries)
                    }
                } else {
                    ServerLedgerUnavailableChip(
                        isLoading: serverLedger.status.phase == .loading
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            if visibleGroups.isEmpty {
                Text(BrandFont.handText("no jobs yet. start a crew."))
                    .font(BrandFont.hand(20, weight: .semibold))
                    .opacity(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .foregroundStyle(Color.Brand.creamSoft)
    }

    private func canonicalBalanceSummary(
        _ summary: ServerLedgerSurfaceAccountBalanceSummary,
        showsCurrencyCode: Bool
    ) -> some View {
        VStack(alignment: .center, spacing: 5) {
            Text(BrandFont.handText(summary.headline))
                .font(BrandFont.hand(20, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .center)

            if showsCurrencyCode {
                Text(summary.net.currencyCode)
                    .font(BrandFont.type(11, bold: true))
                    .opacity(0.9)
            }

            Text(summary.net.absoluteDisplayText)
                .font(BrandFont.display(43, weight: .bold))
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : BrandMotion.counter,
                           value: summary.net.minorUnits)

            Squiggle()
                .stroke(Color.Brand.creamSoft,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 122, height: 12)

            HStack(spacing: 8) {
                BalancePill(
                    text: "you owe \(summary.owe.absoluteDisplayText)",
                    filled: false,
                    onDark: true
                )
                BalancePill(
                    text: "owed \(summary.owed.absoluteDisplayText)",
                    filled: false,
                    onDark: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeOverallBalance-\(summary.net.currencyCode)")
    }

    private var canonicalSettledBalanceSummary: some View {
        VStack(alignment: .center, spacing: 5) {
            Text(BrandFont.handText("all settled up"))
                .font(BrandFont.hand(20, weight: .semibold))

            Text("0")
                .font(BrandFont.display(43, weight: .bold))

            Squiggle()
                .stroke(Color.Brand.creamSoft,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 122, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeOverallBalance-settled")
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
                        .opacity(0.7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all groups")
            }
            .foregroundStyle(Color.Brand.creamSoft)
            .padding(.top, 15)

            if !visibleGroups.isEmpty {
                groupCards(for: GroupRecency.sorted(visibleGroups, snapshot: serverLedger.snapshot))
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
        let reviewNames = group.members.filter { !$0.isCurrentUser }.map(\.name).sorted()
        let memberLabel = !reviewAccountID.isEmpty && !reviewNames.isEmpty
            ? reviewNames.joined(separator: ", ") : GroupCopy.memberCount(group.members.count)
        let presentation = serverGroupID == nil ? nil : serverLedger.groupBalancePresentation(for: group)
        let localNet: Decimal? = serverGroupID == nil
            ? currentUsers.first.map { BalanceMath.nets(in: group)[$0.id] ?? 0 }
            : nil
        NavigationLink(value: group) {
            GroupCard(
                group: group,
                balanceText: presentation?.label ?? (serverGroupID == nil
                    ? localNet.map { $0 >= 0 ? "owed \(Money.currency($0, currencyCode: group.resolvedCurrencyCode))" : "owe \(Money.currency(-$0, currencyCode: group.resolvedCurrencyCode))" }
                    : nil),
                balanceIsPositive: presentation?.isPositive ?? ((localNet ?? 0) >= 0),
                sourceLabel: memberLabel,
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
                let merged = UnifiedActivity.merged(shared: sharedActivity, local: localActivity)
                if merged.isEmpty, !sharedGroups.isEmpty {
                    if serverLedger.snapshot == nil {
                        ServerLedgerSurfaceStatusView(
                            ledger: serverLedger,
                            includeEmpty: true
                        ) {
                            Task { await serverLedger.refresh(groups: visibleGroups) }
                        }
                        .padding(.vertical, 7)
                    } else {
                        Text("No activity yet")
                            .font(BrandFont.type(11))
                            .opacity(0.7)
                            .padding(.vertical, 8)
                    }
                }
                ForEach(Array(merged.prefix(3))) { item in
                    UnifiedActivityRow(item: item, groups: visibleGroups, compact: true)
                }
                if sharedGroups.isEmpty && localActivity.isEmpty {
                    Text("No sightings yet")
                        .font(BrandFont.type(11))
                        .opacity(0.7)
                        .padding(.vertical, 12)
                }
            }
            .foregroundStyle(Color.Brand.cobalt)
            .padding(13)
            .padding(.top, 2)
            .background(Color.Brand.creamSoft, in: RoundedRectangle(cornerRadius: 15))
            .padding(.top, 22)

            MascotView(mascot: .confused, size: 58, idle: false)
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
    private let glyphInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        super.textRect(forBounds: bounds.inset(by: glyphInsets))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        super.editingRect(forBounds: bounds.inset(by: glyphInsets))
    }

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
    @Query private var groups: [Group]
    @ObservedObject private var serverLedger = ServerLedgerSurfaceStore.shared
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var currentUsers: [Person]
    @Query private var progressRecords: [UserProgress]
    @Query private var achievementUnlocks: [AchievementUnlock]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appleUserIdentifier") private var appleUserIdentifier = ""
    @AppStorage("reviewAccountID") private var reviewAccountID = ""
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
    @State private var isSavingAvatar = false
    @State private var hasUsernameSession = UsernameIdentityService.hasStoredSession
    @State private var currentAppleNonce: String?
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

    private var profileBalances: [ServerLedgerSurfaceAccountBalanceSummary]? {
        let sharedIDs = Set(groups.filter {
            $0.isVisible(toServerAccountID: serverLedger.activeAccountIdentifier)
        }.compactMap(\.serverLedgerGroupID))
        guard !sharedIDs.isEmpty, let snapshot = serverLedger.snapshot,
              snapshot.accountID == serverLedger.activeAccountIdentifier,
              snapshot.coversExactly(serverGroupIDs: sharedIDs) else { return nil }
        return snapshot.accountBalanceSummaries
    }

    private var profileCurrencyCodes: [String] {
        let visible = groups.filter { $0.isVisible(toServerAccountID: serverLedger.activeAccountIdentifier) }
        // Offer the trip currency before the first VND group exists.
        return Array(Set(visible.map(\.resolvedCurrencyCode) + ["INR", "VND"])).sorted()
    }

    /// The on/off switch was removed from Profile, so the level and pins always show.
    private var progressEnabled: Bool { true }
    private var lifetimeXP: Int { currentProgress?.lifetimeXP ?? 0 }

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
                        .disabled(isSavingAvatar)

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
                                Text(BrandFont.handText(trimmedName.isEmpty ? "your profile" : trimmedName))
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

                        if let profileStatusText {
                            Text(profileStatusText)
                                .font(BrandFont.type(11, bold: true))
                                .foregroundStyle(Color.Brand.cobalt.opacity(0.9))
                        }
                    }

                    if showAvatarPicker {
                        avatarPickerSection
                            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                    }

                    ProfileCurrencySettingsSection(sourceCodes: profileCurrencyCodes, balances: profileBalances)

                    VStack(spacing: 8) {
                        gamificationSection
                        ProfileFriendsSection()
                    }
                    appleAccountSection
                    legalSection
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
            Text("This permanently removes your account and personal data. Group amounts remain for the other members. Your profile and authored text become anonymous.")
        }
    }

    /// Shows only while something is happening. The idle hint was removed.
    private var profileStatusText: String? {
        if isSavingAvatar { return "saving your avatar…" }
        if isSavingUsername { return "reserving your handle…" }
        if isEditingName { return "press done to save" }
        if showAvatarPicker { return "choose freely · tap big avatar to save" }
        return nil
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
            BrandSectionLabel("LEVEL & ACHIEVEMENTS")

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
                        .font(BrandFont.type(11, bold: true))
                        .opacity(0.7)
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

    private var appleAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if (appleUserIdentifier.isEmpty && reviewAccountID.isEmpty) || !hasUsernameSession {
                if !appleUserIdentifier.isEmpty {
                    Text("Reconnect Apple to verify your unique handle.")
                        .font(BrandFont.type(11, bold: true))
                        .foregroundStyle(Color.Brand.cobalt.opacity(0.9))
                }
                SignInWithAppleButton(.continue) { request in
                    authMessage = nil
                    isSavingUsername = true
                    currentAppleNonce = AppleSignInSupport.prepare(request)
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
                    SwiftUI.Group {
                        if reviewAccountID.isEmpty {
                            Text("")
                        } else {
                            Image(systemName: "person.fill")
                        }
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(Color.Brand.creamSoft)
                    .background(Color.Brand.cobalt, in: Circle())
                    // One line only, also with large text sizes. No email.
                    Text(reviewAccountID.isEmpty ? "Signed in with Apple" : "Signed in as App Reviewer")
                        .font(BrandFont.body(13.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier(reviewAccountID.isEmpty ? "profileSignedInWithApple" : "profileSignedInAsReviewer")
                    Spacer(minLength: 8)
                    Button("Sign out") { showSignOutConfirmation = true }
                    .font(BrandFont.type(11, bold: true))
                    .lineLimit(1)
                    .fixedSize()
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.horizontal, 14)
                .frame(minHeight: 62)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Brand.cobalt, lineWidth: 2))
            }
            if let authMessage {
                Text(authMessage)
                    .font(BrandFont.type(11, bold: true))
                    .foregroundStyle(Color.Brand.cobalt.opacity(0.9))
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 10) {
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
            // Two pills on one line, to save screen space.
            HStack(spacing: 10) {
                Link(destination: BillBanditLegalLinks.privacyPolicy) {
                    legalRow(title: "Privacy Policy")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("privacyPolicyLink")

                Link(destination: BillBanditLegalLinks.support) {
                    legalRow(title: "Support")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("supportLink")
            }
        }
    }

    private func legalRow(title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(BrandFont.body(14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.bold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.Brand.cobalt)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48)
        .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))
        .contentShape(Capsule())
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
        guard !isSavingAvatar else { return }
        let avatar = selectedAvatar
        isSavingAvatar = true
        authMessage = nil
        Task { @MainActor in
            defer { isSavingAvatar = false }
            do {
                if UsernameIdentityService.hasStoredSession {
                    _ = try await UsernameIdentityService.updateAvatar(avatar)
                }
                let activePerson = AccountProfileIntegrity.canonicalize(
                    appleUserIdentifier: appleUserIdentifier,
                    cloudUserRecordName: nil,
                    context: context
                )
                activePerson.profileAvatar = avatar
                activePerson.profileUpdatedAt = .now
                try context.save()
                CloudCollaborationService.shared.currentPersonDidChange()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(BrandMotion.reveal(reduceMotion: reduceMotion)) {
                    showAvatarPicker = false
                }
            } catch {
                selectedAvatar = currentUsers.first?.profileAvatar ?? avatar
                authMessage = error.localizedDescription
            }
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        Task { @MainActor in
            await finishAppleSignIn(result)
        }
    }

    @MainActor
    private func finishAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        defer {
            isSavingUsername = false
            currentAppleNonce = nil
        }
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken else {
                let error = NSError(domain: "BillBandit.AppleSignIn", code: 1)
                let reference = AppleSignInSupport.logFailure(error, stage: "profile-credential")
                authMessage = "Apple did not return an account credential. Reference \(reference)."
                return
            }
            AppleSignInSupport.logCredential(credential)
            let fullName = credential.fullName.flatMap {
                let value = PersonNameComponentsFormatter().string(from: $0)
                return value.isEmpty ? nil : value
            }
            do {
                AppleSignInSupport.logBackendExchangeStarted()
                let remoteUser = try await UsernameIdentityService.authenticateWithApple(
                    identityToken: identityToken,
                    authorizationCode: credential.authorizationCode,
                    nonce: currentAppleNonce,
                    name: fullName,
                    email: credential.email
                )
                AppleSignInSupport.logBackendExchangeSucceeded()
                ServerLedgerSurfaceStore.shared.accountDidAuthenticate(remoteUser.id)
                deferNextAppleCredentialStateCheck = true
                appleUserIdentifier = credential.user
                reviewAccountID = ""
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
                let reference = AppleSignInSupport.logFailure(error, stage: "profile-backend")
                authMessage = "\(error.localizedDescription) Reference \(reference)."
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                authMessage = nil
            } else {
                let reference = AppleSignInSupport.logFailure(error, stage: "profile-authorization")
                authMessage = "Apple sign-in could not be completed. Reference \(reference)."
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
        reviewAccountID = ""
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
                reviewAccountID = ""
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
                .font(BrandFont.body(11, weight: .extraBold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            // The colored badge already shows "unlocked"; only locked pins need a hint.
            if !isUnlocked {
                Text(achievement.requirement)
                    .font(BrandFont.type(11, bold: true))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(Color.Brand.cobalt)
        .frame(width: 116, height: 142, alignment: .top)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(achievement.title), \(isUnlocked ? "unlocked" : achievement.requirement)")
        .accessibilityIdentifier("achievement-\(achievement.rawValue)")
    }
}

private struct HomeDefaultCurrencyEstimate: View {
    let summaries: [ServerLedgerSurfaceAccountBalanceSummary]
    @ObservedObject private var store = BaseCurrencyEstimateStore.shared

    private var foreign: [AppCurrency] {
        summaries.compactMap { AppCurrency(rawValue: $0.net.currencyCode) }
            .filter { $0 != store.selectedBaseCurrency }
    }

    private var netEstimate: Decimal? {
        var total = Decimal.zero
        for summary in summaries {
            guard let amount = summary.net.majorUnits,
                  let converted = store.estimate(amount: amount, sourceCurrency: summary.net.currencyCode) else {
                return nil
            }
            total += converted
        }
        return total
    }

    var body: some View {
        if !foreign.isEmpty {
            VStack(spacing: 4) {
                if let net = netEstimate {
                    let text = BaseCurrencyEstimateFormatting.amount(net < 0 ? -net : net, currency: store.selectedBaseCurrency)
                    Text(net == 0 ? "≈ all square in \(store.selectedBaseCurrency.rawValue)"
                         : net > 0 ? "≈ \(text) owed to you in all"
                         : "≈ \(text) you owe in all")
                        .font(BrandFont.type(12, bold: true))
                        .accessibilityIdentifier("homeDefaultCurrencyEstimate")
                }
                ForEach(foreign) { currency in
                    if let rate = store.rate(for: currency) {
                        Text(BaseCurrencyEstimateFormatting.rateLine(rate))
                            .font(BrandFont.type(11))
                            .opacity(0.78)
                    }
                }
                Text("Estimates only. Each balance is settled in its own currency.")
                    .font(BrandFont.type(11))
                    .opacity(0.9)
            }
            .foregroundStyle(Color.Brand.creamSoft)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .task(id: foreign.map(\.rawValue).joined(separator: ",") + store.selectedBaseCurrency.rawValue) {
                for currency in foreign { await store.ensureRate(sourceCurrency: currency) }
            }
        }
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
                .accessibilityIdentifier("groupMembers-\(group.name)")
                .font(BrandFont.type(11, bold: true))
                .opacity(0.9)
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

    private var summary: String { item.displaySummary }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(compact ? Color.Brand.cobalt : Color.Brand.creamSoft)
                .frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(BrandFont.type(compact ? 11 : 12, bold: true))
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text(item.at.formatted(date: .omitted, time: .shortened))
                        .font(BrandFont.type(11))
                        .opacity(0.9)
                }
            }
            Spacer(minLength: 4)
            if item.showsAmount && item.type != "expense" {
                Text(item.amount.absoluteDisplayText)
                    .font(BrandFont.type(compact ? 11 : 11, bold: true))
                    .lineLimit(1)
            }
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

    private var visibleGroups: [Group] {
        groups.filter {
            $0.isVisible(toServerAccountID: serverLedger.activeAccountIdentifier)
        }
    }

    private var sharedGroups: [Group] {
        visibleGroups.filter { $0.serverLedgerGroupID != nil }
    }

    private var localItems: [ActivityItem] {
        ActivityData.localItems(items, groups: groups)
    }

    private var sharedItems: [ServerLedgerSurfaceActivityItem] {
        serverLedger.snapshot?.activity ?? []
    }

    @State private var visibleCount = 60

    private var allItems: [UnifiedActivity] {
        UnifiedActivity.merged(shared: sharedItems, local: localItems)
    }

    /// Long histories draw in pages so the tab opens fast.
    private var visibleItems: [UnifiedActivity] {
        Array(allItems.prefix(visibleCount))
    }

    /// Today, Yesterday, weekday, Last week, then months.
    private var sections: [RecencySection<UnifiedActivity>] {
        RecencySectioning.sections(visibleItems) { $0.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visibleItems.isEmpty, !sharedGroups.isEmpty, serverLedger.status.phase != .loading {
                        Text("no activity yet")
                            .font(BrandFont.type(11))
                            .opacity(0.7)
                    }
                    // Newest first, under day headers. No dots or icons:
                    // what happened, then group and time, your amount on the right.
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(BrandFont.type(15, bold: true))
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in
                            UnifiedActivityRow(item: item, groups: visibleGroups)
                        }
                    }
                    if allItems.count > visibleCount {
                        Button {
                            visibleCount += 60
                        } label: {
                            Text("Show older activity")
                                .font(BrandFont.display(14, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .overlay(Capsule().stroke(Color.Brand.creamSoft, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                        .accessibilityIdentifier("activityShowOlder")
                    }
                    if sharedGroups.isEmpty && localItems.isEmpty {
                        VStack(spacing: 10) {
                            MascotView(mascot: .neutral, size: 160)
                            Text(BrandFont.handText("nothing in the ledger yet"))
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
            .navigationDestination(for: ServerLedgerSurfaceActivityItem.self) { item in
                SharedActivityDestination(item: item, groups: visibleGroups)
            }
            .task(id: visibleGroups.map { "\($0.id.uuidString):\($0.serverLedgerGroupID ?? "")" }) {
                await serverLedger.refresh(groups: visibleGroups)
            }
        }
    }

}

/// Shared (server) and older on-phone activity in one list, newest first.
enum UnifiedActivity: Identifiable {
    case shared(ServerLedgerSurfaceActivityItem)
    case local(ActivityItem)

    var id: String {
        switch self {
        case .shared(let item): return "shared-\(item.groupID)-\(item.id)"
        case .local(let item): return "local-\(item.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .shared(let item): return item.at
        case .local(let item): return item.timestamp
        }
    }

    static func merged(
        shared: [ServerLedgerSurfaceActivityItem],
        local: [ActivityItem]
    ) -> [UnifiedActivity] {
        (shared.map(UnifiedActivity.shared) + local.map(UnifiedActivity.local))
            .sorted { $0.date > $1.date }
    }
}

struct UnifiedActivityRow: View {
    let item: UnifiedActivity
    let groups: [Group]
    var compact = false

    var body: some View {
        switch item {
        case .shared(let shared):
            ExpenseActivityNavigation(item: shared, groups: groups) {
                if compact {
                    ServerLedgerActivityRow(item: shared, compact: true)
                } else {
                    ActivityLineRow(line: shared.lineText,
                                    groupName: ["expense", "settlement", "reversal"].contains(shared.type) ? shared.groupName : nil,
                                    date: shared.at, amount: shared.lineAmount,
                                    isDeleted: shared.isDeletedExpense)
                }
            }
        case .local(let local):
            LocalExpenseActivityNavigation(item: local, groups: groups) {
                if compact {
                    ActivityLedgerRow(item: local, compact: true)
                } else {
                    ActivityLineRow(line: local.lineText, groupName: nil,
                                    date: local.timestamp, amount: nil,
                                    isDeleted: local.kind == .expenseDeleted)
                }
            }
        }
    }
}

/// Who paid whom, how much, and when, with a way into the group.
private struct PaymentActivityDetailScreen: View {
    let item: ServerLedgerSurfaceActivityItem
    let group: Group

    private var title: String {
        item.type == "reversal" ? "Payment undone" : "Payment"
    }

    /// This user's name in the group, so the page can say "you".
    private var currentMemberName: String? {
        guard let surface = ServerLedgerSurfaceStore.shared.snapshot?.group(for: item.groupID) else { return nil }
        return surface.members.first { $0.memberID == surface.currentMemberID }?.displayName
    }

    private var headline: String {
        let you = currentMemberName
        let payerName = item.payerName ?? item.actorName ?? "Someone"
        let recipientName = item.recipientName ?? "the group"
        let payerIsYou = payerName == you
        let recipient = recipientName == you ? "you" : recipientName
        if item.type == "reversal" {
            return payerIsYou
                ? "Your payment to \(recipient) was undone"
                : "\(payerName)'s payment to \(recipient) was undone"
        }
        return "\(payerIsYou ? "You" : payerName) paid \(recipient)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text(group.name)
                        .font(BrandFont.body(12, weight: .semibold))
                        .opacity(0.7)
                    Text(item.amount.absoluteDisplayText)
                        .font(BrandFont.type(34, bold: true))
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                    Text(headline)
                        .font(BrandFont.display(20, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(item.at.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
                        .font(BrandFont.type(11))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.Brand.creamSoft)

                NavigationLink {
                    GroupDetailScreen(group: group)
                } label: {
                    Text("Open \(group.name)")
                        .font(BrandFont.display(15, weight: .bold))
                        .foregroundStyle(Color.Brand.cobalt)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.Brand.creamSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paymentOpenGroupButton")
            }
            .padding(20)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExpenseActivityNavigation<Content: View>: View {
    let item: ServerLedgerSurfaceActivityItem
    let groups: [Group]
    let content: Content

    init(item: ServerLedgerSurfaceActivityItem, groups: [Group], @ViewBuilder content: () -> Content) {
        self.item = item
        self.groups = groups
        self.content = content()
    }

    var body: some View {
        if groups.contains(where: { $0.serverLedgerGroupID == item.groupID }) {
            NavigationLink(value: item) { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityHint("Open activity")
        } else {
            content
        }
    }
}

private struct SharedActivityDestination: View {
    let item: ServerLedgerSurfaceActivityItem
    let groups: [Group]

    var body: some View {
        if let group = groups.first(where: { $0.serverLedgerGroupID == item.groupID }) {
            if item.type == "expense", let expenseID = item.expenseID {
                SharedExpenseOverviewScreen(group: group, expenseID: expenseID)
            } else if item.type == "settlement" || item.type == "reversal" {
                PaymentActivityDetailScreen(item: item, group: group)
            } else {
                GroupDetailScreen(group: group)
            }
        } else {
            Text("Group unavailable")
        }
    }
}

private struct LocalExpenseActivityNavigation<Content: View>: View {
    let item: ActivityItem
    let groups: [Group]
    let content: Content

    init(item: ActivityItem, groups: [Group], @ViewBuilder content: () -> Content) {
        self.item = item
        self.groups = groups
        self.content = content()
    }

    private var expense: Expense? {
        guard item.kind == .expenseAdded || item.kind == .expenseEdited,
              let groupID = item.groupID, let expenseID = item.refID,
              let group = groups.first(where: { $0.id == groupID && $0.serverLedgerGroupID == nil }) else { return nil }
        return group.expenses.first(where: { $0.id == expenseID })
    }
    private var group: Group? {
        guard let groupID = item.groupID else { return nil }
        return groups.first { $0.id == groupID }
    }

    var body: some View {
        if let expense {
            NavigationLink { ExpenseDetailScreen(expense: expense) } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open expense")
        } else if let group {
            NavigationLink { GroupDetailScreen(group: group) } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open group")
        } else {
            content
        }
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
                    .font(BrandFont.type(compact ? 11 : 12, bold: item.kind == .settlementRecorded))
                    .lineLimit(2)
                if !compact {
                    Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(BrandFont.type(11))
                        .opacity(0.9)
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
            .font(BrandFont.type(11, bold: true))
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

// MARK: - Activity feed rows

/// Activity tab row, laid out like Splitwise: an icon tile, a sentence that
/// says who did what, the effect on your balance, then the full date.
/// Uses only the brand cobalt and cream: "you get back" is a filled cream
/// pill, "you owe" is an outlined pill, and deleted items are struck through.
struct ActivityFeedRow: View {
    let icon: String
    let sentence: AttributedString
    let impact: ActivityFeedImpact?
    let date: Date
    var isDeleted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.Brand.creamSoft)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.Brand.cobalt)
                }
                .opacity(isDeleted ? 0.6 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(sentence)
                    .fixedSize(horizontal: false, vertical: true)
                if let impact {
                    ActivityFeedImpactView(impact: impact, isDeleted: isDeleted)
                }
                Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(BrandFont.type(11))
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .foregroundStyle(Color.Brand.creamSoft)
        .accessibilityElement(children: .combine)
    }
}

enum ActivityFeedImpact {
    case filled(String)
    case outlined(String)
    case neutral(String)
}

private struct ActivityFeedImpactView: View {
    let impact: ActivityFeedImpact
    let isDeleted: Bool

    var body: some View {
        switch impact {
        case .filled(let text):
            label(text)
                .foregroundStyle(Color.Brand.cobalt)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.Brand.creamSoft, in: Capsule())
        case .outlined(let text):
            label(text)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.Brand.creamSoft, lineWidth: 1.5))
        case .neutral(let text):
            label(text).opacity(0.85)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.type(12, bold: true))
            .strikethrough(isDeleted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .opacity(isDeleted ? 0.7 : 1)
    }
}

/// Builds the sentence with bold names, like "**Esha** added **“Goa hotel”** in **Trip**."
struct ActivitySentence {
    private var text = AttributedString()

    mutating func plain(_ value: String) {
        var run = AttributedString(value)
        run.font = BrandFont.body(15)
        text += run
    }

    mutating func bold(_ value: String) {
        var run = AttributedString(value)
        run.font = BrandFont.body(15, weight: .extraBold)
        text += run
    }

    var value: AttributedString { text }
}

extension ServerLedgerSurfaceActivityItem {
    var feedIcon: String {
        switch type {
        case "expense": return "list.bullet.rectangle.portrait"
        case "settlement": return "banknote"
        case "reversal": return "arrow.uturn.backward"
        case "group": return "person.3"
        case "membership": return action == "removed" ? "person.badge.minus" : "person.badge.plus"
        default: return "sparkles"
        }
    }

    var isDeletedExpense: Bool { type == "expense" && action == "deleted" }

    var feedSentence: AttributedString {
        var s = ActivitySentence()
        let actor = (actorName?.isEmpty == false ? actorName : nil) ?? "Someone"
        switch type {
        case "expense":
            let title = description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = title.flatMap { $0.isEmpty ? nil : $0 } ?? "an expense"
            let verb = action == "updated" ? "updated" : action == "deleted" ? "deleted" : "added"
            s.bold(actor); s.plain(" \(verb) "); s.bold("“\(subject)”")
            s.plain(" in "); s.bold("“\(groupName)”"); s.plain(".")
        case "settlement":
            s.bold(actor); s.plain(" recorded a payment in "); s.bold("“\(groupName)”"); s.plain(".")
        case "reversal":
            s.bold(actor); s.plain(" undid a payment in "); s.bold("“\(groupName)”"); s.plain(".")
        default:
            s.plain(displaySummary + ".")
        }
        return s.value
    }

    var feedImpact: ActivityFeedImpact? {
        let money = amount.absoluteDisplayText
        switch type {
        case "expense":
            guard let viewerNet else { return .neutral("Total \(money)") }
            if viewerNet.isZero { return .neutral("You do not owe anything") }
            return viewerNet.isPositive
                ? .filled("You get back \(viewerNet.absoluteDisplayText)")
                : .outlined("You owe \(viewerNet.absoluteDisplayText)")
        case "settlement":
            if payerName == "You" { return .filled("You paid \(money)") }
            if recipientName == "You" { return .outlined("You received \(money)") }
            if let payerName, let recipientName {
                return .neutral("\(payerName) paid \(recipientName) \(money)")
            }
            return .neutral(money)
        case "reversal":
            return .neutral("\(money) payment undone")
        default:
            return nil
        }
    }
}

extension ActivityItem {
    var feedIcon: String {
        switch kind {
        case .expenseAdded, .expenseEdited, .expenseDeleted: return "list.bullet.rectangle.portrait"
        case .settlementRecorded: return "banknote"
        case .groupCreated: return "person.3"
        case .memberAdded, .friendAdded: return "person.badge.plus"
        }
    }

    var feedSentence: AttributedString {
        var s = ActivitySentence()
        s.plain(displaySummary.hasSuffix(".") ? displaySummary : displaySummary + ".")
        return s.value
    }
}


// MARK: - Activity list rows (calm style)

/// One Activity row: "Arjun added *Scooter rental*" on the first line,
/// "*Goa trip* · 09:18" below, and your amount (+ you get, − you owe) on the right.
struct ActivityLineRow: View {
    let line: AttributedString
    let groupName: String?
    let date: Date
    let amount: String?
    var isDeleted = false

    private var timeText: String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: .now)).day ?? 0
        return days <= 6
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated))
    }

    private var contextText: Text {
        let time = Text(timeText).font(BrandFont.type(13))
        guard let groupName, !groupName.isEmpty else { return time }
        return Text(BrandFont.handText(groupName)).font(BrandFont.hand(15)) + Text(" · ").font(BrandFont.type(13)) + time
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                contextText
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.8)
            }
            Spacer(minLength: 8)
            if let amount {
                Text(amount)
                    .font(BrandFont.type(15, bold: true))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .opacity(isDeleted ? 0.6 : 1)
        .foregroundStyle(Color.Brand.creamSoft)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private enum ActivityLine {
    static func plain(_ value: String) -> AttributedString {
        var run = AttributedString(value)
        run.font = BrandFont.body(16)
        return run
    }

    /// Names the user typed (expenses) use the handwriting font.
    static func hand(_ value: String, struck: Bool = false) -> AttributedString {
        var run = AttributedString(BrandFont.handText(value))
        run.font = BrandFont.hand(19)
        if struck { run.strikethroughStyle = .single }
        return run
    }
}

extension ServerLedgerSurfaceActivityItem {
    private var actorLabel: String {
        (actorName?.isEmpty == false ? actorName : nil) ?? "Someone"
    }

    var lineText: AttributedString {
        switch type {
        case "expense":
            let title = description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = title.flatMap { $0.isEmpty ? nil : $0 } ?? "an expense"
            let verb = action == "updated" ? "changed" : action == "deleted" ? "deleted" : "added"
            return ActivityLine.plain("\(actorLabel) \(verb) ")
                + ActivityLine.hand(subject, struck: action == "deleted")
        case "settlement":
            if let payerName, let recipientName {
                let to = recipientName == "You" ? "you" : recipientName
                return ActivityLine.plain("\(payerName) paid \(to)")
            }
            return ActivityLine.plain("\(actorLabel) recorded a payment")
        case "reversal":
            return ActivityLine.plain("\(actorLabel) undid a payment")
        default:
            return ActivityLine.plain(displaySummary)
        }
    }

    /// Your effect as one signed number: + you get money, − you owe.
    var lineAmount: String? {
        switch type {
        case "expense":
            guard !isDeletedExpense, let viewerNet, !viewerNet.isZero else { return nil }
            return (viewerNet.isPositive ? "+" : "−") + viewerNet.absoluteDisplayText
        case "settlement":
            if recipientName == "You" { return "+" + amount.absoluteDisplayText }
            if payerName == "You" { return "−" + amount.absoluteDisplayText }
            return nil
        default:
            return nil
        }
    }
}

extension ActivityItem {
    var lineText: AttributedString {
        let summary = displaySummary.hasSuffix(".") ? String(displaySummary.dropLast()) : displaySummary
        return ActivityLine.plain(summary)
    }
}
