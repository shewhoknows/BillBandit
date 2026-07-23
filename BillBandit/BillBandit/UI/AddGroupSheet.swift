import SwiftUI
import SwiftData
import UIKit

struct AddGroupSheet: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: GroupIcon = .house
    @State private var selected = Set<UUID>()
    @State private var simplify = true
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var memberOptions: [Person] {
        ConnectedFriendIdentity.canonicalPeople(from: people)
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandModalHeader(title: "New group") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    BrandSectionLabel("NAME")
                    TextField("Group name", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { nameFocused = false }
                        .accessibilityIdentifier("groupNameField")
                        .font(BrandFont.type(15, bold: true))
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))

                    BrandSectionLabel("ICON")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                        ForEach(GroupIcon.allCases, id: \.self) { gi in
                            Button { icon = gi } label: {
                                BrandIconView(icon: gi.icon, size: 22)
                                    .foregroundStyle(icon == gi ? Color.Brand.creamSoft : Color.Brand.cobalt)
                                    .frame(width: 44, height: 44)
                                    .background(icon == gi ? Color.Brand.cobalt : .clear)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    BrandSectionLabel("MEMBERS")
                    VStack(spacing: 0) {
                        ForEach(Array(memberOptions.enumerated()), id: \.element.id) { index, person in
                            Button { toggle(person) } label: {
                                HStack {
                                    Text(person.isCurrentUser ? "\(person.name) · you" : person.name)
                                        .font(BrandFont.body(14, weight: .bold))
                                        .foregroundStyle(Color.Brand.cobalt)
                                    Spacer()
                                    BrandCheckmark(isOn: person.isCurrentUser || selected.contains(person.id))
                                }
                                .padding(.horizontal, 15)
                                .frame(height: 50)
                            }
                            .buttonStyle(.plain)
                            .disabled(person.isCurrentUser)
                            if index < memberOptions.count - 1 {
                                Rectangle().fill(Color.Brand.cobalt.opacity(0.18)).frame(height: 1)
                                    .padding(.horizontal, 15)
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.Brand.cobalt, lineWidth: 2))

                    Button { simplify.toggle() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Simplify debts")
                                    .font(BrandFont.display(14, weight: .semibold))
                                Text("Fewer payments between members")
                                    .font(BrandFont.type(9.5, bold: true))
                                    .opacity(0.58)
                            }
                            Spacer()
                            BrandCheckmark(isOn: simplify)
                        }
                        .foregroundStyle(Color.Brand.cobalt)
                        .padding(.horizontal, 16)
                        .frame(height: 62)
                    }
                    .buttonStyle(.plain)
                    .overlay(Capsule().stroke(Color.Brand.cobalt, lineWidth: 2))

                    Button(action: create) {
                        Text("Create group")
                            .font(BrandFont.display(15.5, weight: .bold))
                            .foregroundStyle(Color.Brand.creamSoft)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.Brand.cobalt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("createGroupButton")
                    .disabled(trimmedName.isEmpty)
                    .opacity(trimmedName.isEmpty ? 0.45 : 1)
                }
                .padding(18)
            }
            .background(Color.Brand.creamSoft)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .background(Color.Brand.cobalt.ignoresSafeArea())
    }

    private func toggle(_ person: Person) {
        guard !person.isCurrentUser else { return }
        if selected.contains(person.id) { selected.remove(person.id) }
        else { selected.insert(person.id) }
    }

    private func create() {
        var memberIDs = Set<UUID>()
        let members = people.compactMap { person -> Person? in
            guard person.isCurrentUser || selected.contains(person.id) else { return nil }
            let preferred = ConnectedFriendIdentity.preferredPerson(for: person, among: people)
            return memberIDs.insert(preferred.id).inserted ? preferred : nil
        }
        let finalName = trimmedName.capitalizingFirstLetter
        guard !finalName.isEmpty else { return }
        let group = Group(name: finalName, icon: icon, simplifyDebts: simplify, members: members)
        context.insert(group)
        let currentUser = people.first(where: \.isCurrentUser)
        context.insert(ActivityItem(kind: .groupCreated,
                                    summary: "\(currentUser?.name ?? "You") created “\(finalName)”",
                                    refID: group.id, actorID: currentUser?.id,
                                    groupID: group.id, groupName: group.name))
        let rewardOutcome = currentUser.flatMap { currentUser in
            try? RewardEngine.award(action: .groupCreated, eventID: group.id,
                                    personID: currentUser.id, context: context)
        }
        do {
            try context.save()
            CloudCollaborationService.shared.groupDidChange(group)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            if let rewardOutcome {
                RewardFeedbackCenter.shared.present(rewardOutcome)
            }
        } catch {
            return
        }
    }
}

struct BrandCheckmark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.Brand.cobalt : .clear)
                .overlay(Circle().stroke(Color.Brand.cobalt, lineWidth: 2))
            if isOn {
                Text("✓")
                    .font(BrandFont.body(13, weight: .extraBold))
                    .foregroundStyle(Color.Brand.creamSoft)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(isOn ? "Selected" : "Not selected")
    }
}
