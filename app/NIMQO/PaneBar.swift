import SwiftUI

/// What the sidebar lists.
enum SidebarPane: CaseIterable {
    case chats, status, channels, communities

    var title: String {
        switch self {
        case .chats: String(localized: "Chats")
        case .status: String(localized: "Status")
        case .channels: String(localized: "Channels")
        case .communities: String(localized: "Communities")
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .status: "circle.dashed"
        case .channels: "megaphone"
        case .communities: "person.3"
        }
    }
}

/// The sidebar's top bar: the panes as a glass capsule whose tinted pill
/// slides to the one chosen, and the More menu beside it. It sits on the
/// same blur as the toolbar above, with a hairline where the list begins.
struct PaneBar: View {
    @Binding var section: SidebarPane
    /// Unread chats wait: a dot on Chats while another pane is shown.
    let chatsUnread: Bool
    @Binding var composing: NewChatView.Start?
    @Binding var starred: Bool
    let enabled: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            // The chosen pane names itself where there is room for it.
            ViewThatFits(in: .horizontal) {
                tabs(titled: true)
                tabs(titled: false)
            }
            MoreMenu(composing: $composing, starred: $starred)
                .disabled(!enabled)
        }
        .glassGroup(spacing: Theme.Spacing.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WindowBar())
    }

    private func tabs(titled: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(SidebarPane.allCases, id: \.self) { pane in
                PaneTab(pane: pane, selected: section == pane, titled: titled,
                        badge: pane == .chats && chatsUnread, pill: pill) { section = pane }
            }
        }
        .padding(3)
        .glassSurface(in: .capsule)
    }
}

private struct PaneTab: View {
    let pane: SidebarPane
    let selected: Bool
    let titled: Bool
    let badge: Bool
    let pill: Namespace.ID
    let choose: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.25), choose)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pane.symbol)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.bounce, options: .speed(1.4), value: selected && !reduceMotion)
                if selected, titled {
                    Text(pane.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, selected && titled ? 12 : 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .shadow(color: .accentColor.opacity(0.4), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hovering {
                    Capsule().fill(.primary.opacity(0.08))
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge, !selected {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.background.opacity(0.6), lineWidth: 1))
                        .offset(x: -4, y: 3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = over }
        }
        .help(pane.title)
        .accessibilityLabel(badge ? "\(pane.title), unread messages" : pane.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// New chat, new group, and starred messages, behind one round button.
private struct MoreMenu: View {
    @Binding var composing: NewChatView.Start?
    @Binding var starred: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            Button("New Chat", systemImage: "square.and.pencil") { composing = .chat }
            Button("New Group", systemImage: "person.2") { composing = .group }
            Divider()
            Button("Starred Messages", systemImage: "star") { starred = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .rotationEffect(.degrees(hovering ? 90 : 0))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassSurface(in: .circle)
        .onHover { over in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3)) { hovering = over }
        }
        .help("New chat, new group, starred messages")
        .accessibilityLabel("More")
    }
}
