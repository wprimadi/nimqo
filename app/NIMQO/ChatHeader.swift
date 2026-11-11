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

    /// Reads a group's info again, after a change to it.
    func refresh(_ chat: String) async {
        if let info = await core?.groupInfo(chatId: chat) {
            groups[chat] = info
        }
    }

    /// The account left `chat`: no longer among its members.
    func left(_ chat: String) {
        guard var info = groups[chat] else { return }
        info.members.removeAll(where: \.isMe)
        info.myRole = nil
        groups[chat] = info
    }

    /// The account can manage `chat`: it is one of the group's admins.
    func isAdmin(of chat: String) -> Bool {
        guard let role = groups[chat]?.myRole else { return false }
        return role != .member
    }
}

extension View {
    /// Replaces the plain window title with the chat's picture, name,
    /// number and status; clicking it shows the contact card.
    func chatHeader(chat: ChatSummary, model: CoreModel, showStarred: @escaping () -> Void) -> some View {
        modifier(ChatHeader(chat: chat, avatars: model.avatars, contacts: model.contacts, calls: model.calls,
                            showStarred: showStarred))
    }
}

private struct ChatHeader: ViewModifier {
    let chat: ChatSummary
    let avatars: AvatarStore
    let contacts: ContactStore
    let calls: CallStore
    let showStarred: () -> Void
    @State private var showsCard = false

    func body(content: Content) -> some View {
        let status = chat.isGroup ? nil : contacts.status(for: chat.id)
        content
            .hidesWindowTitle()
            .toolbar {
                headerItem(status: status)
                ToolbarItemGroup(placement: .primaryAction) { callButtons }
            }
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

    @ViewBuilder
    private var callButtons: some View {
        Button("Voice Call", systemImage: "phone") { calls.place(chat.id, video: false) }
            .help("Voice call")
            .disabled(calls.current != nil || calls.core == nil)
        Button("Video Call", systemImage: "video") { calls.place(chat.id, video: true) }
            .help("Video call")
            .disabled(calls.current != nil || calls.core == nil)
    }

    /// The card closes first: a sheet can't sit over a popover.
    private func starred() {
        showsCard = false
        showStarred()
    }

    private func header(status: ContactStatus?) -> some View {
        Button { showsCard.toggle() } label: {
            // The label reads the group's info itself: read here, its
            // arrival rebuilt the whole toolbar and re-laid out the
            // timeline below, which then sat past its rows, blank.
            HeaderLabel(chat: chat, status: status, contacts: contacts, avatars: avatars)
        }
        .buttonStyle(.plain)
        .help("Contact info")
        .onChange(of: showsCard) { _, open in
            if !open {
                releaseSidebarFocus()
            }
        }
        .popover(isPresented: $showsCard, arrowEdge: .bottom) {
            if chat.isGroup {
                GroupCardOf(chat: chat, contacts: contacts, avatars: avatars, calls: calls, showStarred: starred)
            } else {
                ContactCard(chat: chat, status: status, avatars: avatars, calls: calls, core: contacts.core,
                            showStarred: starred)
            }
        }
    }
}

/// Closing the card hands key focus back to the chat list, and a focused
/// list paints its selection in the accent colour until something else,
/// like the composer, takes focus. Focus goes to the window instead, the
/// moment it is key again and before it redraws (a delay showed a flash).
@MainActor
private func releaseSidebarFocus() {
    let watch = FocusWatch()
    watch.token = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
    ) { note in
        let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            guard let window = NSApp.mainWindow, ObjectIdentifier(window) == id else { return }
            FocusWatch.release(window)
            watch.stop()
        }
    }
    FocusWatch.release(NSApp.keyWindow)
    // In case the window never stopped being key, or the closing click
    // landed on the list.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        MainActor.assumeIsolated {
            FocusWatch.release(NSApp.mainWindow)
            watch.stop()
        }
    }
}

@MainActor
final class FocusWatch {
    var token: NSObjectProtocol?

    static func release(_ window: NSWindow?) {
        guard let window, window.firstResponder is NSTableView else { return }
        window.makeFirstResponder(nil)
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
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
            toolbar(removing: .title).windowBar()
        } else {
            self
        }
    }
}

extension View {
    /// The calm bar under the toolbar, in place of the system's: its blur
    /// shows on hover and cannot see the desktop blur behind the
    /// see-through window, so it flickered black, and it blurred harder
    /// over whatever content sat under it.
    @ViewBuilder
    func windowBar() -> some View {
        if #available(macOS 15, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .overlay(alignment: .top) {
                    // Spans the toolbar's height, under its items.
                    GeometryReader { proxy in
                        WindowBar()
                            .frame(height: proxy.safeAreaInsets.top)
                            .offset(y: -proxy.safeAreaInsets.top)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            self
        }
    }
}

/// "online", "typing…" or when last seen; nil when unknown.
func presenceText(_ status: ContactStatus?) -> Text? {
    guard let status else { return nil }
    if status.typing {
        return Text(status.recording ? "recording audio…" : "typing…").foregroundStyle(.tint)
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
    let contacts: ContactStore
    let avatars: AvatarStore
    @State private var hovering = false

    private var members: Int? {
        contacts.groups[chat.id]?.members.count
    }

    /// The number, unless the title already shows it.
    private var phone: String? {
        chat.phone.flatMap { chat.title.contains($0) ? nil : $0 }
    }

    private var subtitle: Text? {
        // A group's typing names who; a person's comes with their presence.
        if chat.isGroup, let activity = chat.activity {
            return Text(activity).foregroundStyle(.tint)
        }
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

/// The group card, reading the group's info here rather than in the
/// header's modifier (see `header`).
private struct GroupCardOf: View {
    let chat: ChatSummary
    let contacts: ContactStore
    let avatars: AvatarStore
    let calls: CallStore
    let showStarred: () -> Void

    var body: some View {
        GroupCard(chat: chat, info: contacts.groups[chat.id], avatars: avatars, contacts: contacts, calls: calls,
                  showStarred: showStarred)
            // Members and settings change from other phones too.
            .task { await contacts.refresh(chat.id) }
    }
}
