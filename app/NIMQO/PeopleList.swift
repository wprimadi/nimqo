import NimqoCore
import SwiftUI

extension Contact {
    /// "+digits" for a number; nil for a LID, which has none to show.
    var phone: String? {
        id.hasSuffix("@s.whatsapp.net") ? "+" + id.prefix { $0 != "@" } : nil
    }

    /// A chat that may have no messages yet, until the first one is sent.
    var summary: ChatSummary {
        ChatSummary(id: id, title: name, isGroup: false, phone: phone, preview: "", lastActivity: .now,
                    unread: 0, timer: nil, muted: false)
    }

    func matches(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return name.localizedCaseInsensitiveContains(text) || (!digits.isEmpty && id.hasPrefix(digits))
    }

    /// Under their first letter, as the Contacts app lists people; "#" last.
    static func sections(_ contacts: [Contact]) -> [(letter: String, contacts: [Contact])] {
        let grouped = Dictionary(grouping: contacts) { contact in
            contact.name.first.map { $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
        }
        return grouped.keys
            .sorted { ($0 == "#" ? 1 : 0, $0) < ($1 == "#" ? 1 : 0, $1) }
            .map { ($0, grouped[$0] ?? []) }
    }
}

extension Optional where Wrapped: Equatable {
    /// The hovered row: `id` on entering; leaving clears it only if no
    /// other row was entered first.
    func hovering(_ id: Wrapped, _ inside: Bool) -> Self {
        if inside {
            return id
        }
        return self == id ? nil : self
    }
}

/// The search field at the top of the people sheets.
struct SearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(focused)
            if busy {
                ProgressView().controlSize(.small)
            } else if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

struct LetterHeader: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ContactRow<Accessory: View>: View {
    let contact: Contact
    let avatars: AvatarStore
    var highlighted = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Avatar(chat: contact.summary, store: avatars, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).lineLimit(1)
                if let phone = contact.phone {
                    Text(phone).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlighted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
    }
}

/// People from the address book, several at a time: for new members and
/// new groups. Those picked ride along on top as chips; Return in the
/// search field picks the first match, so names can be typed one by one.
struct PeoplePicker: View {
    let core: Core?
    let avatars: AvatarStore
    /// Numbers ("+digits") already in the group.
    var excluded: Set<String> = []
    @Binding var picked: [Contact]
    @State private var query = ""
    @State private var contacts: [Contact]?
    @State private var hovered: String?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [Contact] {
        let all = (contacts ?? []).filter { !excluded.contains($0.phone ?? "") }
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.matches(text) }
    }

    var body: some View {
        VStack(spacing: 10) {
            SearchField(prompt: "Search name or number", text: $query, focused: $focused)
                .onSubmit {
                    if let first = shown.first {
                        toggle(first)
                        query = ""
                    }
                }
            if !picked.isEmpty {
                chips.transition(.opacity.combined(with: .move(edge: .top)))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Contact.sections(shown), id: \.letter) { section in
                        LetterHeader(letter: section.letter)
                        ForEach(section.contacts, id: \.id, content: row)
                    }
                }
            }
            .overlay {
                if contacts == nil {
                    ProgressView()
                } else if shown.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No contacts to add" : "No matches",
                                           systemImage: "person.crop.circle.badge.questionmark")
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: picked.map(\.id))
        .task {
            focused = true
            contacts = await Task.detached { [core] in (try? core?.addressBook()) ?? [] }.value
        }
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(picked, id: \.id) { contact in
                        HStack(spacing: 6) {
                            Avatar(chat: contact.summary, store: avatars, size: 22)
                            Text(contact.name.split(separator: " ").first.map(String.init) ?? contact.name)
                                .font(.callout).lineLimit(1)
                            Button("Remove \(contact.name)", systemImage: "xmark.circle.fill") { toggle(contact) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 7)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.14), in: .capsule)
                        .id(contact.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 1)
            }
            .onChange(of: picked.last?.id) { _, last in
                if let last {
                    withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        }
    }

    private func row(_ contact: Contact) -> some View {
        let isPicked = picked.contains { $0.id == contact.id }
        return Button { toggle(contact) } label: {
            ContactRow(contact: contact, avatars: avatars, highlighted: hovered == contact.id) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = hovered.hovering(contact.id, $0) }
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func toggle(_ contact: Contact) {
        if let index = picked.firstIndex(where: { $0.id == contact.id }) {
            picked.remove(at: index)
        } else {
            picked.append(contact)
        }
    }
}
