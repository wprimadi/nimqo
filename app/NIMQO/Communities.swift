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

/// A community in the sidebar: its emblem, name and size.
struct CommunityRow: View {
    let community: Community
    let avatars: AvatarStore

    var body: some View {
        HStack(spacing: 12) {
            CommunityEmblem(id: community.id, avatars: avatars, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(community.name.isEmpty ? "Community" : community.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let members = community.members {
                    Label("\(members, format: .number) members", systemImage: "person.2.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A community's picture on a stack of tinted cards: many groups, one place.
struct CommunityEmblem: View {
    let id: String
    let avatars: AvatarStore
    let size: CGFloat

    var body: some View {
        let corner = size * 0.28
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.tint.opacity(0.25))
                .rotationEffect(.degrees(-10))
                .offset(x: -size * 0.08, y: size * 0.04)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.tint.opacity(0.45))
                .rotationEffect(.degrees(6))
                .offset(x: size * 0.07, y: size * 0.02)
            Group {
                if let image = avatars.image(for: id) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.accentColor.gradient)
                }
            }
            .clipShape(.rect(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: size * 0.08, y: size * 0.04)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { avatars.request(id) }
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
