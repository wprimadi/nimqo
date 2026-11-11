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
    let calls: CallStore
    let showStarred: () -> Void
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
        .padding(14)
        .frame(width: 360)
        .confirmationDialog(removalTitle, isPresented: removingShown, presenting: removing) { member in
            Button("Remove", role: .destructive) { change([member.id], .remove) }
        }
        .confirmationDialog("Leave “\(info?.subject ?? chat.title)”?", isPresented: $leaving) {
            Button("Leave Group", role: .destructive) { leave() }
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
        VStack(spacing: 12) {
            ProfileHero(chat: chat, avatars: avatars) { heroText }
            if let info, isMember {
                actions
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        // Wraps: a refusal can be longer than the card.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                details(info)
                ChatSettings(chat: chat, core: contacts.core, locked: !canEditInfo(info), showStarred: showStarred)
                memberList
                footer
            } else if info != nil {
                Label("You're no longer a member of this group.", systemImage: "person.crop.circle.badge.xmark")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small).padding(.top, 4)
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
            InfoSection("Description", symbol: "text.alignleft") {
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
        }
        InfoSection("Settings", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 6) {
                if isAdmin {
                    setting("Only admins can send messages", isOn: info.announceOnly, .announceOnly)
                    setting("Only admins can edit group info", isOn: info.locked, .locked)
                } else {
                    Label(info.announceOnly ? "Only admins can send messages" : "Everyone can send messages",
                          systemImage: "megaphone")
                    Label(info.locked ? "Only admins can edit group info" : "Everyone can edit group info",
                          systemImage: info.locked ? "lock.fill" : "lock.open")
                }
                if let secs = info.createdSecs {
                    let date = Date(timeIntervalSince1970: TimeInterval(secs))
                    Label("Created \(date.formatted(date: .long, time: .omitted))", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
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
        InfoSection(title: "\(info?.members.count ?? 0) Members", symbol: "person.2.fill") {
            if isAdmin {
                Button("Add", systemImage: "person.badge.plus") {
                    problem = nil
                    adding = true
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
            }
        } content: {
            if (info?.members.count ?? 0) > 8 {
                TextField("Find a member", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(members, id: \.id) { member in
                        MemberRow(member: member, avatars: avatars,
                                  manageable: isAdmin && !member.isMe && member.role != .owner, actions: {
                                      MemberMenu(member: member) { change([member.id], $0) } remove: {
                                          removing = member
                                      }
                                  })
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if isAdmin {
                Button("Reset Invite Link…", systemImage: "arrow.clockwise") { resetting = true }
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                leaving = true
            }
            .foregroundStyle(.red)
        }
        .font(.callout)
        .buttonStyle(.borderless)
    }

    /// The card shows the group as left at once, whatever the server's
    /// copy of it says a moment later.
    private func leave() {
        Task {
            if await save({ try await $0.leaveGroup(chatId: chat.id) }) {
                contacts.left(chat.id)
            }
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

extension GroupCard {
    private var heroText: some View {
        VStack(spacing: 6) {
            if let info, isMember {
                EditableText(text: info.subject ?? chat.title, placeholder: "Group name",
                             editable: canEditInfo(info), save: { name in
                                 await save { try await $0.setGroupSubject(chatId: chat.id, subject: name) }
                             })
                             .font(.title2.bold())
                             .multilineTextAlignment(.center)
            } else {
                Text(info?.subject ?? chat.title).font(.title2.bold()).multilineTextAlignment(.center)
            }
            if let info {
                HStack(spacing: 6) {
                    HeroChip(text: Text("\(info.members.count) members"), symbol: "person.2.fill")
                    if isAdmin {
                        HeroChip(text: Text("Admin"), symbol: "star.fill")
                    }
                }
            }
        }
    }

    /// Calls, and the invite link for admins.
    private var actions: some View {
        HStack(spacing: 8) {
            let canCall = calls.current == nil && calls.core != nil
            QuickAction(title: "Voice", symbol: "phone.fill") { calls.place(chat.id, video: false) }
                .disabled(!canCall)
            QuickAction(title: "Video", symbol: "video.fill") { calls.place(chat.id, video: true) }
                .disabled(!canCall)
            if isAdmin {
                QuickAction(title: copied ? "Copied" : "Invite", symbol: copied ? "checkmark" : "link") {
                    copyLink(reset: false)
                }
                .help("Copy the invite link")
            }
        }
    }
}

private struct MemberRow<Actions: View>: View {
    let member: GroupMember
    let avatars: AvatarStore
    let manageable: Bool
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(chat: ChatSummary(id: member.id, title: member.displayName, isGroup: false, phone: member.phone,
                                     preview: "", lastActivity: .now, unread: 0, timer: nil, muted: false),
                   store: avatars, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.isMe ? String(localized: "You") : member.displayName).lineLimit(1)
                if member.savedName != nil || member.isMe, let phone = member.phone {
                    Text(phone).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            switch member.role {
            case .owner: RoleBadge(title: "Owner", fill: AnyShapeStyle(Color.orange.gradient))
            case .admin: RoleBadge(title: "Admin", fill: AnyShapeStyle(Color.accentColor.gradient))
            case .member: EmptyView()
            }
            if manageable {
                Menu(content: actions) {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0.4)
                .help("Member options")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
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
