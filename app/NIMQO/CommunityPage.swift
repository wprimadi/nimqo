import NimqoCore
import SwiftUI

/// One community: a hero with its emblem over its own picture, blurred,
/// then its groups as cards, in three shelves (announcements, the groups
/// the account is in, the ones it can join).
struct CommunityView: View {
    let community: Community
    let store: CommunityStore
    let avatars: AvatarStore
    /// Shows the group in Chats.
    let open: (ChatSummary) -> Void
    @State private var problem: String?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        community.name.isEmpty ? String(localized: "Community") : community.name
    }

    var body: some View {
        let groups = store.groups[community.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero(groups: groups)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let groups {
                    shelves(groups)
                } else if store.unreachable.contains(community.id) {
                    ContentUnavailableView("Couldn't load groups", systemImage: "wifi.slash",
                                           description: Text("Check the connection and open the community again."))
                } else {
                    placeholders
                }
            }
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0), value: problem)
        .task {
            await store.open(community.id)
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.15)) { shown = true }
        }
        .navigationTitle(title)
        .windowBar()
    }

    private func hero(groups: [CommunityGroup]?) -> some View {
        HStack(spacing: 22) {
            CommunityEmblem(id: community.id, avatars: avatars, size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.4)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let members = community.members {
                        Chip(text: "\(members.formatted()) members", symbol: "person.2.fill")
                    }
                    if let groups {
                        Chip(text: "\(groups.count) groups", symbol: "square.stack.3d.up.fill")
                        let mine = groups.count(where: \.joined)
                        Chip(text: "\(mine) joined", symbol: "checkmark.circle.fill")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { HeroBackdrop(id: community.id, avatars: avatars) }
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func shelves(_ groups: [CommunityGroup]) -> some View {
        if groups.isEmpty {
            ContentUnavailableView("No groups to show", systemImage: "person.3",
                                   description: Text("WhatsApp listed no groups in this community."))
        }
        let announcements = groups.filter(\.announcements)
        let mine = groups.filter { $0.joined && !$0.announcements }
        let others = groups.filter { !$0.joined && !$0.announcements }
        shelf("Announcements", "megaphone.fill", announcements, 0)
        shelf("Your groups", "checkmark.circle.fill", mine, announcements.count)
        shelf("More to join", "plus.circle.fill", others, announcements.count + mine.count)
    }

    @ViewBuilder
    private func shelf(_ title: LocalizedStringKey, _ icon: String, _ list: [CommunityGroup], _ off: Int) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, group in
                        CommunityCard(group: group, avatars: avatars, joining: store.joining,
                                      open: { open(group.summary) },
                                      join: { join(group) })
                            // Cards rise into place one after another.
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown ? 0 : 18)
                            .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.2)
                                .delay(Double(min(off + index, 12)) * 0.04), value: shown)
                    }
                }
            }
        }
    }

    /// Cards in the shape of the ones on their way.
    private var placeholders: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            ForEach(0 ..< 6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .frame(height: 132)
            }
        }
        .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.45]) { content, opacity in
            content.opacity(opacity)
        } animation: { _ in .easeInOut(duration: 0.9) }
        .accessibilityLabel("Loading groups")
    }

    private func join(_ group: CommunityGroup) {
        Task {
            problem = nil
            problem = await store.join(group.id, in: community.id)
        }
    }
}

private struct Chip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: .capsule)
    }
}

/// One group: its picture, name, size, and Open or Join. A joined card
/// opens on a click anywhere; every card lifts under the pointer.
private struct CommunityCard: View {
    let group: CommunityGroup
    let avatars: AvatarStore
    let joining: String?
    let open: () -> Void
    let join: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                picture
                Spacer()
                if group.joined {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Joined")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(group.announcements ? String(localized: "Announcements") : group.name)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                if let members = group.members {
                    Text("\(members, format: .number) members").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            action
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(group.announcements ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.primary.opacity(0.05)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(hovering ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.primary.opacity(0.08)),
                              lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 14, y: 8)
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .contentShape(.rect(cornerRadius: 18))
        .onHover { over in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) { hovering = over }
        }
        .onTapGesture {
            if group.joined {
                open()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: group.joined ? "Open" : "Join", group.joined ? open : join)
    }

    @ViewBuilder
    private var picture: some View {
        if group.announcements {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.gradient, in: .circle)
                .accessibilityHidden(true)
        } else {
            Avatar(chat: group.summary, store: avatars, size: 44)
        }
    }

    @ViewBuilder
    private var action: some View {
        if group.joined {
            Button("Open Chat", systemImage: "bubble.left.fill", action: open)
                .glassButton()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if joining == group.id {
            ProgressView().controlSize(.small)
                .frame(height: 22)
        } else {
            Button("Join", systemImage: "plus", action: join)
                .glassButton(prominent: true)
                .disabled(joining != nil)
        }
    }
}
