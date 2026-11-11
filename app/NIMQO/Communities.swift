import NimqoCore
import SwiftUI

/// The communities this account is in and the groups inside the open one,
/// asked of the server when shown. Joining a group is the one thing sent.
@MainActor
@Observable
final class CommunityStore {
    var core: Core? {
        didSet {
            communities = nil
            groups = [:]
        }
    }

    /// Nil until fetched, or when the fetch failed (offline).
    private(set) var communities: [Community]?
    private(set) var failed = false
    var selected: String?
    private(set) var groups: [String: [CommunityGroup]] = [:]
    /// Communities whose groups could not be fetched.
    private(set) var unreachable: Set<String> = []
    /// A join on its way: the group's id.
    private(set) var joining: String?

    func load() async {
        guard let core else { return }
        let list = await core.communities()
        communities = list ?? communities
        failed = list == nil
    }

    func open(_ id: String) async {
        guard let core else { return }
        unreachable.remove(id)
        if let list = await core.communityGroups(communityId: id) {
            groups[id] = list
        } else if groups[id] == nil {
            unreachable.insert(id)
        }
    }

    /// Returns why it did not go through.
    func join(_ group: String, in community: String) async -> String? {
        guard let core, joining == nil else { return nil }
        joining = group
        defer { joining = nil }
        do {
            try await core.joinCommunityGroup(communityId: community, groupId: group)
        } catch {
            return CoreModel.message(for: error)
        }
        await open(community)
        return nil
    }
}

extension CommunityGroup {
    /// As a chat, for its picture and for opening it.
    var summary: ChatSummary {
        ChatSummary(id: id, title: name, isGroup: true, phone: nil, preview: "", lastActivity: .now,
                    unread: 0, timer: nil, muted: false)
    }
}

/// A community in the sidebar: its picture, name and size.
struct CommunityRow: View {
    let community: Community
    let avatars: AvatarStore

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = avatars.image(for: community.id) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.3.sequence.fill")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.tint)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
            .onAppear { avatars.request(community.id) }
            VStack(alignment: .leading, spacing: 3) {
                Text(community.name.isEmpty ? "Community" : community.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let members = community.members {
                    Text("\(members, format: .number) members")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The groups of one community: open the ones joined, join the others.
struct CommunityView: View {
    let community: Community
    let store: CommunityStore
    let avatars: AvatarStore
    /// Shows the group in Chats.
    let open: (ChatSummary) -> Void
    @State private var problem: String?

    var body: some View {
        let groups = store.groups[community.id]
        List {
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
            ForEach(groups ?? [], id: \.id) { group in
                row(group)
            }
        }
        .overlay {
            if groups?.isEmpty == true {
                ContentUnavailableView("No groups to show", systemImage: "person.3",
                                       description: Text("WhatsApp listed no groups in this community."))
            } else if groups == nil {
                if store.unreachable.contains(community.id) {
                    ContentUnavailableView("Couldn't load groups", systemImage: "wifi.slash",
                                           description: Text("Check the connection and open the community again."))
                } else {
                    ProgressView()
                }
            }
        }
        .task { await store.open(community.id) }
        .navigationTitle(community.name.isEmpty ? "Community" : community.name)
        .navigationSubtitle(community.members.map { Text("\($0, format: .number) members") } ?? Text(""))
        .windowBar()
    }

    private func row(_ group: CommunityGroup) -> some View {
        HStack(spacing: 12) {
            if group.announcements {
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.tint, in: .rect(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Avatar(chat: group.summary, store: avatars, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.announcements ? String(localized: "Announcements") : group.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let members = group.members {
                    Text("\(members, format: .number) members").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if group.joined {
                Button("Open") { open(group.summary) }
            } else if store.joining == group.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Join") {
                    Task {
                        problem = nil
                        problem = await store.join(group.id, in: community.id)
                    }
                }
                .disabled(store.joining != nil)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        // A double-click opens a joined group, like a chat in the list.
        .onTapGesture(count: 2) {
            if group.joined {
                open(group.summary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The communities in the sidebar.
struct CommunityList: View {
    let store: CommunityStore
    let avatars: AvatarStore

    var body: some View {
        List(store.communities ?? [], id: \.id, selection: Bindable(store).selected) { community in
            CommunityRow(community: community, avatars: avatars)
                .listRowSeparator(.visible)
        }
        .overlay {
            if store.communities == nil {
                if store.failed {
                    ContentUnavailableView("Couldn't load communities", systemImage: "wifi.slash")
                } else {
                    ProgressView()
                }
            } else if store.communities?.isEmpty == true {
                ContentUnavailableView(
                    "No communities",
                    systemImage: "person.3",
                    description: Text("Communities this account is in appear here.")
                )
            }
        }
        .task { await store.load() }
    }
}

/// The selected community's groups, or a hint to pick one.
struct CommunityDetail: View {
    let store: CommunityStore
    let avatars: AvatarStore
    let open: (ChatSummary) -> Void

    var body: some View {
        if let id = store.selected, let community = store.communities?.first(where: { $0.id == id }) {
            CommunityView(community: community, store: store, avatars: avatars, open: open)
                .id(id)
        } else {
            ContentUnavailableView(
                "Select a community",
                systemImage: "person.3",
                description: Text("Its groups appear here: open the ones you are in, or join others.")
            )
        }
    }
}
