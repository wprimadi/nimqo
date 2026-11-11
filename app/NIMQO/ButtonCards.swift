import AppKit
import NimqoCore
import SwiftUI

/// A message with buttons or a list, as businesses and bots send them: its
/// header, text and footer, then the buttons as tinted rows inside the
/// bubble, like a poll's choices. A reply button or list row answers only
/// when pressed here.
struct ButtonsCardView: View {
    let chat: String
    let seq: Int64
    let card: ButtonsCard
    let core: Core?
    @State private var problem: String?
    @State private var choosing = false

    private var thumbnail: NSImage? {
        card.thumbnail.flatMap { NSImage(data: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            if let header = card.header {
                Text(header).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let body = card.body {
                Text(MessageText.attributed(body, mentions: []))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let footer = card.footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                ForEach(Array(card.buttons.enumerated()), id: \.offset) { _, button in
                    MessageButtonRow(button: button, press: press)
                }
                if let list = card.listButton {
                    CardButton(label: list, symbol: "list.bullet", enabled: core != nil) { choosing = true }
                        .popover(isPresented: $choosing, arrowEdge: .trailing) {
                            ListChoices(title: card.header ?? list, sections: card.sections) { row in
                                choosing = false
                                await press(row)
                            }
                        }
                }
            }
            .padding(.top, 2)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(width: 280, alignment: .leading)
    }

    /// Answers with reply button or row `id`; returns once it is queued.
    private func press(_ id: String) async {
        guard let core else { return }
        problem = nil
        let result = await Task.detached { Result { try core.pressButton(chatId: chat, seq: seq, id: id) } }.value
        if case let .failure(error) = result {
            problem = CoreModel.message(for: error)
        }
    }
}

/// One button: answers, opens a web link, copies a code, or calls.
private struct MessageButtonRow: View {
    let button: MessageButton
    let press: (String) async -> Void
    @State private var done = false
    @State private var sending = false

    var body: some View {
        CardButton(label: done ? doneLabel : button.label, symbol: done ? "checkmark" : symbol,
                   enabled: enabled && !sending, busy: sending) { run() }
            .help(help)
    }

    private var enabled: Bool {
        switch button.action {
        case .reply, .copy: true
        case let .url(url): Self.web(url) != nil
        case let .call(phone): Self.tel(phone) != nil
        case .unsupported: false
        }
    }

    private var symbol: String {
        switch button.action {
        case .reply: "arrowshape.turn.up.left"
        case .url: "arrow.up.right.square"
        case .copy: "doc.on.doc"
        case .call: "phone"
        case .unsupported: "iphone"
        }
    }

    private var doneLabel: String {
        if case .copy = button.action {
            return String(localized: "Copied")
        }
        return String(localized: "Sent")
    }

    private var help: String {
        switch button.action {
        case .reply: String(localized: "Answers with “\(button.label)”")
        case let .url(url): url
        case let .copy(code): String(localized: "Copies \(code)")
        case let .call(phone): String(localized: "Calls \(phone)")
        case .unsupported: String(localized: "Open this on your phone")
        }
    }

    private func run() {
        switch button.action {
        case .reply:
            sending = true
            Task {
                await press(button.id)
                sending = false
                flash()
            }
        case let .url(url):
            if let url = Self.web(url) {
                NSWorkspace.shared.open(url)
            }
        case let .copy(code):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            flash()
        case let .call(phone):
            if let url = Self.tel(phone) {
                NSWorkspace.shared.open(url)
            }
        case .unsupported: break
        }
    }

    /// Says it worked for a moment, then shows the button again.
    private func flash() {
        done = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            done = false
        }
    }

    /// Web links only, as in message text.
    static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }

    static func tel(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}

/// A button row inside the bubble, in the poll's shape and the app's tint.
private struct CardButton: View {
    let label: String
    let symbol: String
    var enabled = true
    var busy = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(label).lineLimit(2).multilineTextAlignment(.center)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(fill, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
            .scaleEffect(hovering && enabled && !reduceMotion ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3), value: hovering)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: label)
        .accessibilityLabel(label)
    }

    private var fill: AnyShapeStyle {
        guard enabled else { return AnyShapeStyle(.primary.opacity(0.04)) }
        return AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.2 : 0.12))
    }
}

/// A list's rows by section; picking one answers with it.
private struct ListChoices: View {
    let title: String
    let sections: [ButtonSection]
    let pick: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            if let title = section.title {
                                Text(title.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                            }
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                ListChoiceRow(row: row) { Task { await pick(row.id) } }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 420)
    }
}

private struct ListChoiceRow: View {
    let row: ButtonRow
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout.weight(.medium))
                    if let description = row.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .opacity(hovering ? 1 : 0)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.tint.opacity(hovering ? 0.12 : 0), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row.id.isEmpty)
        .onHover { hovering = $0 }
        .accessibilityHint("Answers with this choice.")
    }
}
