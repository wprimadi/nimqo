import AppKit
import NimqoCore
import SwiftUI

/// A group's picture, name, description, settings and members. Admins
/// change them here; anyone can when the group's info is not locked.
struct GroupCard: View {
    let chat: ChatSummary
    /// Nil while loading, or when the server could not be reached.
    let info: GroupInfo?
    let avatars: AvatarStore
    let contacts: ContactStore
    @State private var filter = ""
    @State private var adding = false
    @State private var problem: String?
    @State private var removing: GroupMember?
    @State private var leaving = false
    @State private var resetting = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAdmin: Bool {
        contacts.isAdmin(of: chat.id)
    }

    private var isMember: Bool {
        info?.members.contains(where: \.isMe) ?? false
    }

    private var members: [GroupMember] {
        let all = info?.members ?? []
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return all }
        return all.filter { member in
            [member.savedName, member.pushName, member.phone].contains { $0?.localizedStandardContains(wanted) == true }
        }
    }

    var body: some View {
        Group {
            if adding, let info {
                AddMembers(chat: chat.id, info: info, avatars: avatars, contacts: contacts) { adding = false }
                    .transition(slide(from: .trailing))
            } else {
                card.transition(slide(from: .leading))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: adding)
        .padding(Theme.Spacing.medium + 4)
        .frame(width: 340)
        .confirmationDialog(removalTitle, isPresented: removingShown, presenting: removing) { member in
            Button("Remove", role: .destructive) { change([member.id], .remove) }
        }
        .confirmationDialog("Leave “\(info?.subject ?? chat.title)”?", isPresented: $leaving) {
            Button("Leave Group", role: .destructive) { run { try await $0.leaveGroup(chatId: chat.id) } }
        } message: {
            Text("You'll stop getting its messages. The chat stays here.")
        }
        .confirmationDialog("Reset the invite link?", isPresented: $resetting) {
            Button("Reset Link", role: .destructive) { copyLink(reset: true) }
        } message: {
            Text("The current link stops working. Anyone who has it can no longer join.")
        }
    }

    private var removalTitle: String {
        String(localized: "Remove \(removing?.displayName ?? "") from the group?")
    }

    private var removingShown: Binding<Bool> {
        Binding { removing != nil } set: {
            if !$0 {
                removing = nil
            }
        }
    }

    private func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var card: some View {
        VStack(spacing: Theme.Spacing.small) {
            Avatar(chat: chat, store: avatars, size: 96)
            if let info {
                EditableText(text: info.subject, placeholder: "Group name", editable: canEditInfo(info)) { name in
                    await save { try await $0.setGroupSubject(chatId: chat.id, subject: name) }
                }
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                Text("Group · \(info.members.count) members").foregroundStyle(.secondary)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                details(info)
                memberList
                footer
            } else {
                Text(chat.title).font(.title2.bold()).multilineTextAlignment(.center)
                ProgressView().controlSize(.small).padding()
                Text("Members appear once the group's info arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func canEditInfo(_ info: GroupInfo) -> Bool {
        isMember && (isAdmin || !info.locked)
    }

    @ViewBuilder
    private func details(_ info: GroupInfo) -> some View {
        if info.description != nil || canEditInfo(info) {
            Divider()
            ScrollView {
                EditableText(text: info.description, placeholder: "Add a group description",
                             editable: canEditInfo(info), multiline: true,
                             save: { text in
                                 await save { try await $0.setGroupDescription(chatId: chat.id, text: text) }
                             })
                             .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            if isAdmin {
                setting("Only admins can send messages", isOn: info.announceOnly, .announceOnly)
                setting("Only admins can edit group info", isOn: info.locked, .locked)
            } else {
                if info.announceOnly {
                    Label("Only admins can send messages", systemImage: "megaphone")
                }
                if info.locked {
                    Label("Only admins can edit group info", systemImage: "lock")
                }
            }
            if let timer = chat.timer {
                Label("Disappearing messages: \(timer)", systemImage: "timer")
            }
            if let secs = info.createdSecs {
                let date = Date(timeIntervalSince1970: TimeInterval(secs))
                Label("Created \(date.formatted(date: .long, time: .omitted))", systemImage: "calendar")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setting(_ title: LocalizedStringKey, isOn: Bool, _ setting: GroupSetting) -> some View {
        Toggle(title, isOn: Binding { isOn } set: { value in
            run { try await $0.setGroupSetting(chatId: chat.id, setting: setting, on: value) }
        })
        .toggleStyle(.switch)
        .controlSize(.mini)
        .foregroundStyle(.primary)
    }

    private var memberList: some View {
        VStack(spacing: 6) {
            Divider()
            HStack {
                Text("Members").font(.headline)
                Spacer()
                if isAdmin {
                    Button("Add Members", systemImage: "person.badge.plus") {
                        problem = nil
                        adding = true
                    }
                    .buttonStyle(.borderless)
                }
            }
            if (info?.members.count ?? 0) > 8 {
                TextField("Find a member", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(members, id: \.id) { member in
                        MemberRow(member: member, manageable: isAdmin && !member.isMe && member.role != .owner) {
                            MemberMenu(member: member) { change([member.id], $0) } remove: { removing = member }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        Divider()
        if isMember {
            HStack {
                if isAdmin {
                    Button(copied ? "Copied" : "Copy Invite Link",
                           systemImage: copied ? "checkmark" : "link") { copyLink(reset: false) }
                        .contentTransition(.symbolEffect(.replace))
                    Menu {
                        Button("Reset Link…", systemImage: "arrow.clockwise") { resetting = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More link options")
                }
                Spacer()
                Button("Leave Group", role: .destructive) { leaving = true }
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        } else {
            Text("You're no longer a member of this group.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func copyLink(reset: Bool) {
        problem = nil
        Task {
            guard let core = contacts.core else { return }
            do {
                let link = try await core.groupInviteLink(chatId: chat.id, reset: reset)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                copied = true
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            } catch {
                problem = CoreModel.message(for: error)
            }
        }
    }

    private func change(_ ids: [String], _ change: MemberChange) {
        run { core in
            if try await core.changeGroupMembers(chatId: chat.id, members: ids, change: change) > 0 {
                throw CoreError.SendRefused(reason: String(localized: "WhatsApp didn't accept that change."))
            }
        }
    }

    /// Returns whether it went through, to keep an edit open when not.
    private func save(_ change: @escaping (Core) async throws -> Void) async -> Bool {
        problem = await contacts.change(chat.id, change)
        return problem == nil
    }

    private func run(_ change: @escaping (Core) async throws -> Void) {
        Task { _ = await save(change) }
    }
}

private struct MemberRow<Actions: View>: View {
    let member: GroupMember
    let manageable: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName).lineLimit(1)
                if member.savedName != nil || member.isMe, let phone = member.phone {
                    Text(phone).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            switch member.role {
            case .owner: RoleBadge(title: "Owner", fill: AnyShapeStyle(.orange))
            case .admin: RoleBadge(title: "Admin", fill: AnyShapeStyle(.tint))
            case .member: EmptyView()
            }
            if manageable {
                Menu(content: actions) {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Member options")
            }
        }
        .contentShape(.rect)
        .contextMenu {
            if manageable {
                actions()
            }
        }
        .accessibilityElement(children: manageable ? .contain : .combine)
    }
}

private struct RoleBadge: View {
    let title: LocalizedStringKey
    /// Solid, with white text: a faint tint is unreadable over the blur.
    let fill: AnyShapeStyle

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(fill, in: .capsule)
    }
}
