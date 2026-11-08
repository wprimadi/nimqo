import NimqoCore
import SwiftUI

/// Starts a chat: pick someone from the address book, or type a number,
/// which WhatsApp is asked about before the chat opens. A new group starts
/// here too. Arrow keys move through the list; Return opens.
struct NewChatView: View {
    enum Start: Identifiable {
        case chat, group
        var id: Self {
            self
        }
    }

    private enum Row: Identifiable {
        case newGroup
        case number(String)
        case contact(Contact)

        var id: String {
            switch self {
            case .newGroup: "group"
            case .number: "number"
            case let .contact(contact): contact.id
            }
        }
    }

    let core: Core?
    let avatars: AvatarStore
    let open: (ChatSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var makingGroup: Bool
    @State private var query = ""
    @State private var contacts: [Contact]?
    @State private var checking = false
    @State private var problem: String?
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    init(core: Core?, avatars: AvatarStore, start: Start = .chat, open: @escaping (ChatSummary) -> Void) {
        self.core = core
        self.avatars = avatars
        self.open = open
        _makingGroup = State(initialValue: start == .group)
    }

    /// Digits, "+", spaces, and dashes, with enough digits for a number.
    private var number: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let digits = text.filter(\.isNumber)
        guard digits.count >= 8, text.allSatisfy({ $0.isNumber || "+ -".contains($0) }) else { return nil }
        return "+" + digits
    }

    private var shown: [Contact] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? contacts ?? [] : (contacts ?? []).filter { $0.matches(text) }
    }

    private var sections: [(letter: String, contacts: [Contact])] {
        Contact.sections(shown)
    }

    /// Everything Return can open, in the order shown.
    private var rows: [Row] {
        var rows: [Row] = query.isEmpty ? [.newGroup] : []
        if let number {
            rows.append(.number(number))
        }
        return rows + sections.flatMap(\.contacts).map(Row.contact)
    }

    var body: some View {
        ZStack {
            if makingGroup {
                NewGroup(core: core, avatars: avatars) { makingGroup = false } created: { group in
                    open(group)
                    dismiss()
                }
                .transition(push(from: .trailing))
            } else {
                finder.transition(push(from: .leading))
            }
        }
        .frame(width: 440, height: 600)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0), value: makingGroup)
        .task {
            contacts = await Task.detached { [core] in (try? core?.addressBook()) ?? [] }.value
            highlighted = rows.first?.id
        }
    }

    private func push(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var finder: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Chat").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)
            SearchField(prompt: "Name or phone number", text: $query, focused: $focused, busy: checking)
                .onSubmit { highlighted.flatMap { id in rows.first { $0.id == id } }.map(activate) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .padding(.horizontal, 18)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            list
        }
        .onAppear { focused = true }
        .onChange(of: query) {
            problem = nil
            highlighted = rows.first?.id
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        action(.newGroup, "New Group", "Pick people, then name it",
                               ("person.2.fill", .green))
                    }
                    if let number {
                        action(.number(number), "Chat with \(number)", "Opens once WhatsApp knows the number",
                               ("phone.fill", .accentColor))
                    }
                    ForEach(sections, id: \.letter) { section in
                        LetterHeader(letter: section.letter)
                        ForEach(section.contacts, id: \.id) { contact in
                            Button { activate(.contact(contact)) } label: {
                                ContactRow(contact: contact, avatars: avatars, highlighted: highlighted == contact.id) {
                                    EmptyView()
                                }
                            }
                            .buttonStyle(.plain)
                            .onHover {
                                if $0 {
                                    highlighted = contact.id
                                }
                            }
                            .id(contact.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .onChange(of: highlighted) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
            .overlay {
                if contacts == nil {
                    ProgressView()
                } else if rows.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("Type a phone number with its country code."))
                }
            }
        }
    }

    private typealias Look = (icon: String, tint: Color)

    private func action(_ row: Row, _ title: String, _ detail: LocalizedStringKey, _ look: Look) -> some View {
        Button { activate(row) } label: {
            HStack(spacing: 12) {
                Image(systemName: look.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(look.tint.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(highlighted == row.id ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(checking)
        .onHover {
            if $0 {
                highlighted = row.id
            }
        }
        .id(row.id)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = highlighted.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlighted = ids[min(max(current + step, 0), ids.count - 1)]
        return .handled
    }

    private func activate(_ row: Row) {
        switch row {
        case .newGroup:
            makingGroup = true
        case let .number(number):
            Task { await openNumber(number) }
        case let .contact(contact):
            open(contact.summary)
            dismiss()
        }
    }

    private func openNumber(_ number: String) async {
        guard let core, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let id = try await core.findNumber(phoneNumber: number)
            let saved = contacts?.first { $0.id == id }
            open(saved?.summary ?? Contact(id: id, name: number).summary)
            dismiss()
        } catch let CoreError.SendRefused(reason) {
            problem = reason
        } catch {
            problem = "Enter the number with its country code, for example +62 812 3456 7890."
        }
    }
}
