import SwiftUI
import SwiftData

/// Phase-2 CRUD screen (invoice-style group detail lands in Phase 3).
struct GroupsScreen: View {
    @Query(sort: \Group.createdAt) private var groups: [Group]
    @Query(filter: #Predicate<Person> { $0.isCurrentUser }) private var me: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdd = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if groups.isEmpty {
                    VStack(spacing: 10) {
                        MascotView(mascot: .neutral, size: 145)
                        Text("no crews yet")
                            .font(BrandFont.hand(24, weight: .bold))
                        Text("Start a group for a home, trip, or shared ritual.")
                            .font(BrandFont.body(12, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .opacity(0.7)
                        Button("Create a group") { showAdd = true }
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
                ForEach(groups) { group in
                    NavigationLink(value: group.id) {
                        HStack(spacing: 11) {
                            Circle()
                                .fill(Color.Brand.creamSoft)
                                .frame(width: 36, height: 36)
                                .overlay(BrandIconView(icon: group.icon.icon, size: 17)
                                    .foregroundStyle(Color.Brand.cobalt))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .font(BrandFont.display(13.5))
                                Text("\(group.members.count) members")
                                    .font(BrandFont.type(9.5))
                                    .opacity(0.65)
                            }
                            .foregroundStyle(Color.Brand.creamSoft)
                            Spacer()
                            if let me = me.first {
                                NetChip(net: BalanceMath.nets(in: group)[me.id] ?? 0)
                            }
                        }
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
                        CloudCollaborationService.shared.groupWasDeleted(groups[i])
                        context.delete(groups[i])
                    }
                    try? context.save()
                }
            }
            .listStyle(.plain)
            .animation(reduceMotion ? nil : BrandMotion.revealSpring, value: groups.map(\.id))
            .scrollContentBackground(.hidden)
            .background(Color.Brand.cobalt)
            .navigationTitle("Groups")
            .toolbar {
                Button { showAdd = true } label: {
                    BrandIconView(icon: .plus, size: 17).foregroundStyle(Color.Brand.creamSoft)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let group = groups.first(where: { $0.id == id }) {
                    GroupDetailScreen(group: group)
                }
            }
            .fullScreenCover(isPresented: $showAdd) { AddGroupSheet() }
        }
        // Screenshot support: `-openGroup <name>` pushes straight into a group.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-openGroup"), i + 1 < args.count else { return }
            let name = args[(i + 1)...].joined(separator: " ")
            if let g = groups.first(where: { $0.name == name }) { path.append(g.id) }
        }
    }
}
