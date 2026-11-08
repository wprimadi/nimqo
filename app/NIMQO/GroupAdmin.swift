import AppKit
import NimqoCore
import SwiftUI

extension ContactStore {
    /// Runs a change to group `chat`, then reads its info again. Returns why
    /// it was refused.
    func change(_ chat: String, _ change: @escaping (Core) async throws -> Void) async -> String? {
        guard let core else { return "Not connected." }
        do {
            try await change(core)
        } catch {
            return CoreModel.message(for: error)
        }
        await refresh(chat)
        return nil
    }
}

extension GroupMember {
    /// A saved name as is; otherwise the number, with the self-chosen name
    /// marked "~" as WhatsApp does.
    var displayName: String {
        if isMe {
            return String(localized: "You")
        }
        if let savedName {
            return savedName
        }
        let pushed = pushName.map { "~\($0)" }
        let name = [phone, pushed].compactMap(\.self).joined(separator: " ")
        return name.isEmpty ? String(localized: "Unknown member") : name
    }
}

/// Text shown as is, with a pencil to edit it in place where allowed.
/// Return saves, Esc puts it back.
struct EditableText: View {
    let text: String?
    let placeholder: LocalizedStringKey
    let editable: Bool
    var multiline = false
    /// Returns false when the change was refused, to keep editing.
    let save: (String) async -> Bool
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField(placeholder, text: $draft, axis: multiline ? .vertical : .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(multiline ? 1 ... 6 : 1 ... 1)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .disabled(saving)
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save", systemImage: "checkmark.circle.fill", action: commit)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                }
            }
            .onAppear { focused = true }
        } else if editable || text != nil {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let text {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(placeholder).foregroundStyle(.tertiary)
                }
                if editable {
                    Button("Edit", systemImage: "pencil") {
                        draft = text ?? ""
                        editing = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Edit")
                }
            }
        }
    }

    private func commit() {
        guard !saving else { return }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != (text ?? "") else {
            editing = false
            return
        }
        saving = true
        Task {
            if await save(draft) {
                editing = false
            }
            saving = false
        }
    }
}

/// People from the address book, several at a time: for new members and
/// new groups.
struct PeoplePicker: View {
    let core: Core?
    let avatars: AvatarStore
    /// Numbers ("+digits") already in the group.
    var excluded: Set<String> = []
    @Binding var picked: [Contact]
    @State private var query = ""
    @State private var contacts: [Contact]?
    @FocusState private var focused: Bool

    private var shown: [Contact] {
        let all = (contacts ?? []).filter { !excluded.contains(Self.phone($0.id) ?? "") }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        let digits = text.filter(\.isNumber)
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(text) || (!digits.isEmpty && $0.id.hasPrefix(digits))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search contacts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8, style: .continuous))
            List(shown, id: \.id) { contact in
                row(contact)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if contacts == nil {
                    ProgressView()
                } else if shown.isEmpty {
                    ContentUnavailableView("No contacts to add", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
        }
        .task {
            focused = true
            contacts = await Task.detached { [core] in (try? core?.addressBook()) ?? [] }.value
        }
    }

    private func row(_ contact: Contact) -> some View {
        let isPicked = picked.contains { $0.id == contact.id }
        return Button {
            if isPicked {
                picked.removeAll { $0.id == contact.id }
            } else {
                picked.append(contact)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                Avatar(chat: NewChatView.summary(contact.id, contact.name), store: avatars, size: 28)
                Text(contact.name).lineLimit(1)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    static func phone(_ id: String) -> String? {
        id.hasSuffix("@s.whatsapp.net") ? "+" + id.prefix { $0 != "@" } : nil
    }
}

/// Inside the group card: pick people, then add them.
struct AddMembers: View {
    let chat: String
    let info: GroupInfo
    let avatars: AvatarStore
    let contacts: ContactStore
    let done: () -> Void
    @State private var picked: [Contact] = []
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Button("Back", systemImage: "chevron.backward", action: done)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Text("Add Members").font(.headline)
                Spacer()
                if adding {
                    ProgressView().controlSize(.small)
                }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || adding)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if !picked.isEmpty {
                Text(picked.map(\.name).formatted(.list(type: .and)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            PeoplePicker(core: contacts.core, avatars: avatars,
                         excluded: Set(info.members.compactMap(\.phone)), picked: $picked)
                .frame(height: 360)
        }
    }

    private func add() {
        guard let core = contacts.core else { return }
        adding = true
        problem = nil
        let ids = picked.map(\.id)
        Task {
            do {
                let turnedDown = try await core.changeGroupMembers(chatId: chat, members: ids, change: .add)
                await contacts.refresh(chat)
                if turnedDown > 0 {
                    let why = "Their privacy settings may only allow an invite link."
                    problem = String(localized: "\(turnedDown) of them couldn't be added. \(why)")
                } else {
                    done()
                }
            } catch {
                problem = CoreModel.message(for: error)
            }
            adding = false
        }
    }
}

/// What an admin can do to a member; nothing for themselves or the owner.
struct MemberMenu: View {
    let member: GroupMember
    let change: (MemberChange) -> Void
    let remove: () -> Void

    var body: some View {
        if member.role == .member {
            Button("Make Group Admin", systemImage: "star.circle") { change(.promote) }
        } else if member.role == .admin {
            Button("Dismiss as Admin", systemImage: "star.slash") { change(.demote) }
        }
        Divider()
        Button("Remove from Group…", systemImage: "person.badge.minus", role: .destructive, action: remove)
    }
}

/// A new group: pick people, then name it. Opens the group once made.
struct NewGroup: View {
    let core: Core?
    let avatars: AvatarStore
    let back: () -> Void
    let created: (ChatSummary) -> Void
    @State private var picked: [Contact] = []
    @State private var naming = false
    @State private var name = ""
    @State private var problem: String?
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Button("Back", systemImage: "chevron.backward") {
                    if naming {
                        naming = false
                    } else {
                        back()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Text(naming ? "Name the Group" : "New Group").font(.headline)
                Spacer()
                if creating {
                    ProgressView().controlSize(.small)
                }
                if naming {
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                } else {
                    Button("Next") { naming = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(picked.isEmpty)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if !picked.isEmpty {
                Text(picked.map(\.name).formatted(.list(type: .and)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if naming {
                TextField("Group name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
                    .disabled(creating)
                    .onAppear { nameFocused = true }
                Spacer()
            } else {
                PeoplePicker(core: core, avatars: avatars, picked: $picked)
            }
        }
        .padding(14)
        .onChange(of: name) { problem = nil }
    }

    private func create() {
        let subject = name.trimmingCharacters(in: .whitespaces)
        guard let core, !subject.isEmpty, !creating else { return }
        creating = true
        problem = nil
        let ids = picked.map(\.id)
        Task {
            do {
                let id = try await core.createGroup(subject: subject, members: ids)
                created(ChatSummary(id: id, title: subject, isGroup: true, phone: nil, preview: "",
                                    lastActivity: .now, unread: 0, timer: nil, muted: false))
            } catch {
                problem = CoreModel.message(for: error)
            }
            creating = false
        }
    }
}
