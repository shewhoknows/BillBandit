import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    private let authRepository: any AuthRepository
    var user: UserProfile?
    var displayName = ""
    var preferredName = ""
    var upiID = ""
    var isLoading = false
    var errorMessage: String?

    init(authRepository: any AuthRepository, initialUser: UserProfile?) {
        self.authRepository = authRepository
        self.user = initialUser
        apply(initialUser)
    }

    var emailText: String {
        guard let email = user?.email, !email.contains(".billbandit.local") else {
            return "Private or synthetic email"
        }
        return email
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await authRepository.me()
            user = loaded
            apply(loaded)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isLoading = false
    }

    func saveProfile() async {
        isLoading = true
        errorMessage = nil
        do {
            let updated = try await authRepository.updateProfile(
                name: displayName.nilIfBlank,
                preferredName: preferredName.nilIfBlank,
                upiID: upiID.nilIfBlank
            )
            user = updated
            apply(updated)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isLoading = false
    }

    private func apply(_ user: UserProfile?) {
        displayName = user?.name ?? ""
        preferredName = user?.preferredName ?? ""
        upiID = user?.upiID ?? ""
    }
}

struct SettingsView: View {
    @State var model: SettingsViewModel
    let onSignOut: () async -> Void

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ReceiptScroll {
                ReceiptCard(eyebrow: "Account", title: "Profile", subtitle: model.emailText) {
                    VStack(spacing: BBSpacing.lg) {
                        HStack(spacing: BBSpacing.md) {
                            Text(model.user?.initials ?? "BB")
                                .font(BBFont.label(size: 18, weight: .bold, relativeTo: .title3))
                                .foregroundStyle(BBColor.cream)
                                .frame(width: 60, height: 60)
                                .background(BBColor.plum, in: Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.user?.displayName ?? "BillBandit user")
                                    .font(BBFont.display(size: 22, weight: .bold, relativeTo: .title3))
                                    .foregroundStyle(BBColor.textPrimary)
                                Text(model.emailText)
                                    .font(BBFont.label(size: 10, relativeTo: .caption2))
                                    .tracking(BBTracking.value(BBTracking.monoLabel, for: 10))
                                    .foregroundStyle(BBColor.textFaded)
                            }
                            Spacer()
                        }

                        ReceiptFormSection(title: "Display name") {
                            HandwrittenTextField(title: "Display name", placeholder: "Name", text: $model.displayName)
                        }

                        ReceiptFormSection(title: "Preferred name") {
                            HandwrittenTextField(title: "Preferred name", placeholder: "Short name", text: $model.preferredName)
                        }

                        ReceiptFormSection(title: "UPI ID") {
                            HandwrittenTextField(title: "UPI ID", placeholder: "name@upi", text: $model.upiID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        InlineErrorText(message: model.errorMessage)

                        PrimaryButton(title: "Save profile", systemImage: "checkmark", isLoading: model.isLoading) {
                            Task { await model.saveProfile() }
                        }
                    }
                }

                ReceiptCard(eyebrow: "App", title: "Details") {
                    VStack(alignment: .leading, spacing: BBSpacing.md) {
                        HStack {
                            Text("Version")
                                .font(BBFont.bodyRounded(size: 16, weight: .semibold, relativeTo: .body))
                                .foregroundStyle(BBColor.textPrimary)
                            Spacer()
                            Text(model.appVersion)
                                .font(BBFont.label(size: 11, relativeTo: .caption))
                                .tracking(BBTracking.value(BBTracking.monoLabel, for: 11))
                                .foregroundStyle(BBColor.textFaded)
                        }
                        .frame(minHeight: 44)
                        Text("Caveat font is bundled under the Open Font License.")
                            .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(BBColor.textFaded)
                    }
                }

                Button(role: .destructive) {
                    Task { await onSignOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(BBFont.bodyRounded(size: 16, weight: .bold, relativeTo: .body))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .navigationTitle("Settings")
            .task {
                await model.load()
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
