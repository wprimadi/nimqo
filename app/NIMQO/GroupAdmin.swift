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
                    .fixedSize(horizontal: false, vertical: true)
            }
            PeoplePicker(core: contacts.core, avatars: avatars,
                         excluded: Set(info.members.compactMap(\.phone)), picked: $picked)
                .frame(height: 400)
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
