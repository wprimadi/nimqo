import AppKit
import NimqoCore
import SwiftUI

/// What can be done to a message from the buttons shown on hover.
struct MessageActions {
    /// The same items as the message's context menu.
    let menu: AnyView
    /// Nil where reacting is not possible; an empty emoji removes it.
    let react: ((String) -> Void)?
    /// Opens the full emoji list for this message.
    let moreReactions: () -> Void
    /// The full emoji list is open for this message.
    let picking: Bool
    /// Bumped on every request, so asking again reopens the viewer.
    let pickRequest: Int
    let endPicking: () -> Void
}

/// Beside a bubble while the pointer is over its row: React, then a menu
/// with everything the context menu has. Stays while the reactions are open.
struct MessageHoverBar: View {
    let actions: MessageActions
    let mine: String?
    let shown: Bool
    /// Own messages sit on the right, so the bar reads from the bubble out.
    let mirrored: Bool
    @State private var reacting = false

    var body: some View {
        HStack(spacing: 2) {
            if mirrored {
                more
            }
            if let react = actions.react {
                Button("React", systemImage: "face.smiling") { reacting = true }
                    .popover(isPresented: $reacting, arrowEdge: .top) {
                        ReactPicker(mine: mine) { emoji in
                            reacting = false
                            react(emoji)
                        } more: {
                            reacting = false
                            actions.moreReactions()
                        }
                    }
                    .modifier(EmojiField(active: actions.picking, request: actions.pickRequest,
                                         pick: react, end: actions.endPicking))
            }
            if !mirrored {
                more
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .imageScale(.large)
        // Kept in the layout while hidden, so rows don't shift on hover.
        .opacity(shown || reacting || actions.picking ? 1 : 0)
        .allowsHitTesting(shown || reacting || actions.picking)
        .animation(.easeOut(duration: 0.12), value: shown)
        .accessibilityHidden(true)
    }

    private var more: some View {
        Menu {
            actions.menu
        } label: {
            Label("More", systemImage: "chevron.down.circle")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The quick reactions in a row, plus the full emoji list.
struct ReactPicker: View {
    let mine: String?
    let choose: (String) -> Void
    let more: () -> Void

    /// A reaction from the full list shows here too, so it can be removed.
    private var choices: [String] {
        if let mine, !ReactMenu.choices.contains(mine) {
            return [mine] + ReactMenu.choices
        }
        return ReactMenu.choices
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.self) { emoji in
                Button { choose(emoji == mine ? "" : emoji) } label: {
                    Text(emoji)
                        .font(.title2)
                        .padding(5)
                        .background(emoji == mine ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.clear),
                                    in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji == mine ? "Remove \(emoji)" : emoji)
            }
            Divider().frame(height: 24)
            Button("More Reactions", systemImage: "plus", action: more)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .imageScale(.large)
                .help("All emoji")
        }
        .padding(8)
    }
}

/// The full emoji list is the macOS Character Viewer. It types into the
/// focused field and points at it, so a hidden field under the React
/// button takes the pick. Anything that isn't an emoji (the viewer closed
/// and a key was typed) ends picking instead of reacting, as does focus
/// moving anywhere else.
private struct EmojiField: ViewModifier {
    let active: Bool
    let request: Int
    let pick: (String) -> Void
    let end: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .background {
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    // Its focus ring was the blue outline left on screen.
                    .focusEffectDisabled()
                    .focused($focused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            .onChange(of: [active ? 1 : 0, request], initial: true) {
                guard active else { return }
                focused = true
                // After the field takes focus, or the viewer has no target.
                DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
            }
            .onChange(of: typed) {
                guard !typed.isEmpty else { return }
                if active, let emoji = typed.first, Self.isEmoji(emoji) {
                    pick(String(emoji))
                }
                typed = ""
                focused = false
                end()
            }
            .onChange(of: focused) {
                if !focused, active {
                    end()
                }
            }
    }

    static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
    }
}

extension MessageBubble {
    @ViewBuilder
    var hoverBar: some View {
        if let actions {
            MessageHoverBar(actions: actions, mine: message.myReaction, shown: hovering, mirrored: message.fromMe)
        }
    }
}

extension ConversationView {
    func actions(for message: ChatMessage) -> MessageActions {
        MessageActions(
            menu: AnyView(menu(for: message)),
            react: send != nil && message.kind != .deleted ? { react(message.seq, $0) } : nil,
            moreReactions: { pickEmoji(for: message.seq) },
            picking: pickingEmoji == message.seq,
            pickRequest: emojiRequests,
            endPicking: {
                if pickingEmoji == message.seq {
                    pickingEmoji = nil
                }
            }
        )
    }

    /// Closing the viewer without a pick leaves this message picking, and
    /// setting the same value again changes nothing: the request count
    /// makes every ask focus the field and open the viewer anew.
    func pickEmoji(for seq: Int64) {
        pickingEmoji = seq
        emojiRequests += 1
    }
}
