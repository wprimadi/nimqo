import NimqoCore
import SwiftUI

/// Starts a chat: pick someone from the address book, or type a number,
/// which WhatsApp is asked about before the chat opens.
struct NewChatView: View {
    let core: Core?
    let avatars: AvatarStore
    let open: (ChatSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var contacts: [Contact] = []
    @State private var checking = false
    @State private var problem: String?
    @State private var makingGroup = false
    @FocusState private var focused: Bool

    /// Digits, "+", spaces, and dashes, with enough digits for a number.
    private var number: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let digits = text.filter(\.isNumber)
        guard digits.count >= 8, text.allSatisfy({ $0.isNumber || "+ -".contains($0) }) else { return nil }
        return "+" + digits
    }

    private var shown: [Contact] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return contacts }
        let digits = text.filter(\.isNumber)
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(text) || (!digits.isEmpty && $0.id.hasPrefix(digits))
        }
    }

    var body: some View {
        Group {
            if makingGroup {
                NewGroup(core: core, avatars: avatars) { makingGroup = false } created: { group in
                    open(group)
                    dismiss()
                }
            } else {
                finder
            }
        }
        .frame(width: 400, height: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var finder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Name or phone number", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                if checking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
            .padding([.horizontal, .top], 14)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            List {
                if query.isEmpty {
                    Button { makingGroup = true } label: {
                        Label("New Group", systemImage: "person.3.fill")
                            .font(.body.weight(.medium))
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                if let number {
                    Button { Task { await openNumber(number) } } label: {
                        Label("Chat with \(number)", systemImage: "phone.bubble.fill")
                            .font(.body.weight(.medium))
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(checking)
                }
                Section(contacts.isEmpty ? "" : "Contacts") {
                    ForEach(shown, id: \.id) { contact in
                        Button { pick(contact) } label: {
                            HStack(spacing: 10) {
                                Avatar(chat: Self.summary(contact.id, contact.name), store: avatars, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(contact.name)
                                    if let phone = Self.phone(contact.id) {
                                        Text(phone).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if shown.isEmpty, number == nil {
                    ContentUnavailableView(contacts.isEmpty ? "No contacts yet" : "No matches",
                                           systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("Type a phone number with its country code."))
                }
            }
        }
        .onChange(of: query) { problem = nil }
        .task {
            focused = true
            contacts = await Task.detached { [core] in (try? core?.addressBook()) ?? [] }.value
        }
    }

    private func submit() {
        if let number {
            Task { await openNumber(number) }
        } else if let first = shown.first {
            pick(first)
        }
    }

    private func pick(_ contact: Contact) {
        open(Self.summary(contact.id, contact.name))
        dismiss()
    }

    private func openNumber(_ number: String) async {
        guard let core, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let id = try await core.findNumber(phoneNumber: number)
            let saved = contacts.first { $0.id == id }?.name
            open(Self.summary(id, saved ?? number))
            dismiss()
        } catch let CoreError.SendRefused(reason) {
            problem = reason
        } catch {
            problem = "Enter the number with its country code, for example +62 812 3456 7890."
        }
    }

    /// "+digits" for a number; nil for a LID, which has none to show.
    private static func phone(_ id: String) -> String? {
        id.hasSuffix("@s.whatsapp.net") ? "+" + id.prefix { $0 != "@" } : nil
    }

    /// A chat that may have no messages yet, until the first one is sent.
    static func summary(_ id: String, _ name: String) -> ChatSummary {
        ChatSummary(id: id, title: name, isGroup: false, phone: phone(id), preview: "", lastActivity: .now,
                    unread: 0, timer: nil, muted: false)
    }
}
