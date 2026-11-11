import AppKit
import NimqoCore
import SwiftUI

/// The menu bar's popover: how NIMQO is doing, the latest chats, and a
/// reply to any of them without opening the window. Click a chat to write
/// back, or its arrow to open it.
struct MenuBarPanel: View {
    let model: CoreModel
    let panels: Panels
    @State private var query = ""
    @State private var replying: ChatSummary.ID?
    @FocusState private var searching: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [ChatSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return Array(model.listed.prefix(7)) }
        return Array(model.listed.filter { $0.title.localizedCaseInsensitiveContains(text) }.prefix(7))
    }

    private var unread: Int {
        model.chats.filter { !$0.quiet }.reduce(0) { $0 + $1.unread }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isSessionUp {
                search
                chats
            } else {
                notLinked
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 360)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.25), value: replying)
        .animation(reduceMotion ? nil : .snappy, value: shown.map(\.id))
        .onExitCommand { replying = nil }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            StatusOrb(connected: model.state == .connected, symbol: model.statusSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text("NIMQO").font(.headline)
                Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if unread > 0 {
                Text("\(unread) unread")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.accentColor.gradient, in: .capsule)
                    .contentTransition(.numericText())
            }
        }
        .padding(14)
        .background {
            LinearGradient(colors: [.accentColor.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $query)
                .textFieldStyle(.plain)
                .focused($searching)
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.primary.opacity(searching ? 0.09 : 0.05), in: .rect(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var chats: some View {
        if shown.isEmpty {
            ContentUnavailableView(query.isEmpty ? "No chats yet" : "No matches",
                                   systemImage: "bubble.left.and.bubble.right")
                .frame(height: 140)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, chat in
                        PanelChatRow(chat: chat, model: model, index: index, replying: replying == chat.id,
                                     toggle: { replying = replying == chat.id ? nil : chat.id },
                                     open: { open(chat.id) })
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notLinked: some View {
        VStack(spacing: 10) {
            Image(systemName: model.statusSymbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Open NIMQO to link it to WhatsApp.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(title: "Open NIMQO", symbol: "macwindow") { open(nil) }
                .keyboardShortcut("o")
            FooterButton(title: "Settings", symbol: "gearshape") {
                open(nil)
                panels.shown = .settings
            }
            .keyboardShortcut(",")
            Spacer()
            FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(8)
    }

    /// Closes the popover (the key window while it is up), then brings the
    /// main window forward, on `chat` if given.
    private func open(_ chat: ChatSummary.ID?) {
        NSApp.keyWindow?.close()
        openWindow(id: MainWindow.id)
        NSApp.activate()
        if let chat {
            model.selectedChat = chat
        }
    }
}

/// Green and breathing while connected; otherwise the state's symbol.
private struct StatusOrb: View {
    let connected: Bool
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(connected ? Color.green.gradient : Color.orange.gradient)
                .frame(width: 34, height: 34)
                .shadow(color: (connected ? Color.green : .orange).opacity(0.5), radius: 8)
            if connected {
                Circle()
                    .stroke(.green.opacity(0.5), lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .phaseAnimator([false, true]) { ring, spread in
                        ring.scaleEffect(spread && !reduceMotion ? 1.45 : 1).opacity(spread && !reduceMotion ? 0 : 0.8)
                    } animation: { _ in .easeOut(duration: 1.8) }
            }
            Image(systemName: connected ? "bolt.horizontal.fill" : symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

private struct PanelChatRow: View {
    let chat: ChatSummary
    let model: CoreModel
    let index: Int
    let replying: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(chat: chat, store: model.avatars, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(chat.title).font(.callout.weight(chat.unread > 0 ? .bold : .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(chat.lastActivity, format: .relative(presentation: .named, unitsStyle: .narrow))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(chat.preview.isEmpty ? " " : chat.preview)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if chat.unread > 0 {
                            Text("\(chat.unread)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(chat.quiet ? AnyShapeStyle(.gray) : AnyShapeStyle(Color.accentColor),
                                            in: .capsule)
                        }
                    }
                }
                Button("Open in NIMQO", systemImage: "arrow.up.forward.app", action: open)
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .opacity(hovering || replying ? 1 : 0)
                    .help("Open in NIMQO")
            }
            .padding(8)
            .contentShape(.rect)
            .onTapGesture(perform: toggle)
            if replying {
                QuickReply(chat: chat, model: model, done: toggle)
                    .padding([.horizontal, .bottom], 8)
                    .transition(.asymmetric(insertion: .push(from: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .background(.primary.opacity(replying ? 0.08 : hovering ? 0.05 : 0),
                    in: .rect(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.3).delay(Double(index) * 0.035)) { appeared = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chat.unread > 0 ? "\(chat.title), \(chat.unread) unread" : chat.title)
        .accessibilityHint("Click to reply here.")
    }
}

/// A one-line reply; Return sends it, Escape closes. The paper plane flies
/// off as it goes.
private struct QuickReply: View {
    let chat: ChatSummary
    let model: CoreModel
    let done: () -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var sent = false
    @State private var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        model.canSend(chat.id) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(model.canSend(chat.id) ? "Reply to \(chat.title)" : "Replies can't go to this chat",
                          text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(!model.canSend(chat.id) || sending)
                Button("Send", systemImage: sent ? "checkmark" : "paperplane.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(sent ? AnyShapeStyle(Color.green.gradient)
                        : canSend ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.gray.opacity(0.4)),
                        in: .circle)
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .offset(x: sending && !reduceMotion ? 14 : 0, y: sending && !reduceMotion ? -10 : 0)
                    .opacity(sending && !reduceMotion ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
            .background(.background.opacity(0.7), in: .capsule)
            .overlay(Capsule().strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard canSend else { return }
        let message = text
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) { sending = true }
        problem = nil
        Task {
            let refusal = await model.send(message, replyTo: nil, to: chat.id)
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.5)) {
                sending = false
                if let refusal {
                    problem = refusal
                } else {
                    text = ""
                    sent = true
                }
            }
            guard refusal == nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            done()
        }
    }
}

private struct FooterButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.primary.opacity(hovering ? 0.09 : 0), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
