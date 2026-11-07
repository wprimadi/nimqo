import NimqoCore
import SwiftUI

/// What the core knows now about the person in the open chat. Read from
/// memory on demand; `invalidate` makes views read again.
@MainActor
@Observable
final class ContactStore {
    var core: Core? {
        didSet { generation += 1 }
    }

    private var generation = 0
    /// Fetched when a group is opened; nil until then or when offline.
    private(set) var groups: [String: GroupInfo] = [:]

    func status(for chat: String) -> ContactStatus? {
        _ = generation
        return core?.contactStatus(chatId: chat)
    }

    /// The chat was opened: a person's about text, online and typing, or a
    /// group's members and description.
    func watch(_ chat: ChatSummary) async {
        guard let core else { return }
        if chat.isGroup {
            if let info = await core.groupInfo(chatId: chat.id) {
                groups[chat.id] = info
            }
        } else {
            core.watchContact(chatId: chat.id)
        }
    }

    func invalidate() {
        generation += 1
    }
}

extension View {
    /// Replaces the plain window title with the chat's picture, name,
    /// number and status; clicking it shows the contact card.
    func chatHeader(chat: ChatSummary, avatars: AvatarStore, contacts: ContactStore) -> some View {
        modifier(ChatHeader(chat: chat, avatars: avatars, contacts: contacts))
    }
}

private struct ChatHeader: ViewModifier {
    let chat: ChatSummary
    let avatars: AvatarStore
    let contacts: ContactStore
    @State private var showsCard = false

    func body(content: Content) -> some View {
        let status = chat.isGroup ? nil : contacts.status(for: chat.id)
        content
            .hidesWindowTitle()
            .toolbar { headerItem(status: status) }
            .task(id: chat.id) { await contacts.watch(chat) }
            // Typing ends without a signal when the "paused" one is lost.
            .task(id: status?.typing) {
                guard status?.typing == true else { return }
                try? await Task.sleep(for: .seconds(16))
                contacts.invalidate()
            }
    }

    /// On macOS 26 the item's own glass flickers black where it samples the
    /// see-through window on hover, so the header draws a calm glass of
    /// its own instead.
    @ToolbarContentBuilder
    private func headerItem(status: ContactStatus?) -> some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { header(status: status) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { header(status: status) }
        }
    }

    private func header(status: ContactStatus?) -> some View {
        Button { showsCard.toggle() } label: {
            HeaderLabel(chat: chat, status: status, members: contacts.groups[chat.id]?.members.count,
                        avatars: avatars)
        }
        .buttonStyle(.plain)
        .help("Contact info")
        .popover(isPresented: $showsCard, arrowEdge: .bottom) {
            if chat.isGroup {
                GroupCard(chat: chat, info: contacts.groups[chat.id], avatars: avatars)
            } else {
                ContactCard(chat: chat, status: status, avatars: avatars)
            }
        }
    }
}

private extension View {
    /// A plain (not interactive) glass capsule on macOS 26; elsewhere the
    /// toolbar draws the item as usual.
    @ViewBuilder
    func headerGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            self
        }
    }

    @ViewBuilder
    func hidesWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
                // The bar's blur shows on hover and cannot see the desktop
                // blur behind the see-through window, so it flickers black.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

/// "online", "typing…" or when last seen; nil when unknown.
private func presenceText(_ status: ContactStatus?) -> Text? {
    guard let status else { return nil }
    if status.typing {
        return Text("typing…").foregroundStyle(.tint)
    }
    if status.online {
        return Text("online").foregroundStyle(.green)
    }
    if let secs = status.lastSeenSecs {
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        return Text("last seen \(date, format: .relative(presentation: .named))")
    }
    return nil
}

private struct HeaderLabel: View {
    let chat: ChatSummary
    let status: ContactStatus?
    let members: Int?
    let avatars: AvatarStore
    @State private var hovering = false

    /// The number, unless the title already shows it.
    private var phone: String? {
        chat.phone.flatMap { chat.title.contains($0) ? nil : $0 }
    }

    private var subtitle: Text? {
        let parts: [Text] = chat.isGroup
            ? [Text(members.map { "\($0) members" } ?? "Group")]
            : [phone.map { Text($0) }, presenceText(status) ?? status?.about.map { Text($0) }].compactMap(\.self)
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() {
            line = Text("\(line) · \(part)")
        }
        return line
    }

    var body: some View {
        HStack(spacing: 10) {
            Avatar(chat: chat, store: avatars, size: 30, online: status?.online == true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(chat.title).font(.headline).lineLimit(1)
                    if chat.timer != nil {
                        Image(systemName: "timer").accessibilityLabel("Disappearing messages")
                    }
                    if chat.muted {
                        Image(systemName: "bell.slash").accessibilityLabel("Muted")
                    }
                }
                .imageScale(.small)
                if let subtitle {
                    subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(.primary.opacity(hovering ? 0.08 : 0), in: .capsule)
        .headerGlass()
        .contentShape(.capsule)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows contact info.")
    }
}

/// The picture, name, number and about text, larger.
private struct ContactCard: View {
    let chat: ChatSummary
    let status: ContactStatus?
    let avatars: AvatarStore

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            Avatar(chat: chat, store: avatars, size: 96, online: status?.online == true)
            Text(chat.title).font(.title2.bold()).multilineTextAlignment(.center)
            if let phone = chat.phone {
                Text(phone).font(.title3).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let presence = presenceText(status) {
                presence.font(.callout)
            }
            if let about = status?.about {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("About").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(about).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if chat.timer != nil || chat.muted {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if let timer = chat.timer {
                        Label("Disappearing messages: \(timer)", systemImage: "timer")
                    }
                    if chat.muted {
                        Label("Muted", systemImage: "bell.slash")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Spacing.medium + 4)
        .frame(width: 300)
    }
}
