import NimqoCore
import SwiftUI

/// The channels this account follows and the posts of the open one, asked
/// of the server when shown. Read-only: nothing is sent back or stored.
@MainActor
@Observable
final class ChannelStore {
    var core: Core? {
        didSet {
            channels = nil
            posts = [:]
            hasOlder = [:]
        }
    }

    /// Nil until fetched, or when the fetch failed (offline).
    private(set) var channels: [Channel]?
    private(set) var failed = false
    var selected: String?
    private(set) var posts: [String: [ChannelPost]] = [:]
    /// A full page came last time, so there may be more before it.
    private(set) var hasOlder: [String: Bool] = [:]
    private(set) var isLoading = false
    /// Channels whose first page could not be fetched.
    private(set) var unreachable: Set<String> = []

    /// Mirrors the core's page size (`channels::PAGE`).
    nonisolated static let page = 30

    func load() async {
        guard let core else { return }
        let list = await core.channels()
        channels = list ?? channels
        failed = list == nil
    }

    /// The latest posts, unless already here.
    func open(_ id: String) async {
        guard posts[id] == nil else { return }
        unreachable.remove(id)
        await fetch(id, before: nil)
    }

    func loadOlder(_ id: String) async {
        await fetch(id, before: posts[id]?.first?.serverId)
    }

    private func fetch(_ id: String, before: UInt64?) async {
        guard let core, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = await core.channelPosts(channelId: id, before: before) else {
            if before == nil {
                unreachable.insert(id)
            }
            return
        }
        unreachable.remove(id)
        posts[id] = page + (before == nil ? [] : posts[id] ?? [])
        hasOlder[id] = page.count >= Self.page
    }
}

/// A channel in the sidebar: its name, a seal when verified, followers.
struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "megaphone.fill")
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.tint, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(channel.name).font(.body.weight(.semibold)).lineLimit(1)
                    if channel.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Verified")
                    }
                }
                Text("\(channel.followers, format: .number.notation(.compactName)) followers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A channel's posts, oldest at the top, read-only.
struct ChannelView: View {
    let channel: Channel
    let store: ChannelStore
    let pictures: PictureStore

    var body: some View {
        let posts = store.posts[channel.id]
        ScrollView {
            TimelineStack {
                if store.hasOlder[channel.id] == true {
                    Button("Load Older Posts") { Task { await store.loadOlder(channel.id) } }
                        .disabled(store.isLoading)
                        .padding(.bottom, Theme.Spacing.small)
                }
                if let description = channel.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.medium)
                        .frame(maxWidth: 520)
                }
                ForEach(posts ?? [], id: \.serverId) { post in
                    MessageBubble(message: post.asMessage, showsSender: false, chat: channel.id, pictures: pictures)
                        .padding(.top, Theme.Spacing.small)
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if posts == nil {
                if !store.unreachable.contains(channel.id) {
                    ProgressView()
                } else {
                    ContentUnavailableView("Couldn't load posts", systemImage: "wifi.slash",
                                           description: Text("Check the connection and open the channel again."))
                }
            }
        }
        .task { await store.open(channel.id) }
        .navigationTitle(channel.name)
        .navigationSubtitle(Text("\(channel.followers, format: .number.notation(.compactName)) followers"))
    }
}

extension ChannelPost {
    /// Shown with the chat bubble; channel media is not fetched yet, so a
    /// photo reads as "Photo" and its caption.
    var asMessage: ChatMessage {
        ChatMessage(id: String(serverId), seq: Int64(clamping: serverId), sender: "", senderName: nil,
                    contactName: nil, edited: edited, hasMedia: false, reactions: nil, myReaction: nil,
                    fromMe: false, timestampSecs: timestampSecs, kind: kind, body: body, delivery: .none,
                    reply: nil)
    }
}
