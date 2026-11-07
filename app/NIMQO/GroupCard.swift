import NimqoCore
import SwiftUI

/// A group's picture, name, description, settings and members. Read-only.
struct GroupCard: View {
    let chat: ChatSummary
    /// Nil while loading, or when the server could not be reached.
    let info: GroupInfo?
    let avatars: AvatarStore
    @State private var filter = ""

    private var members: [GroupMember] {
        let all = info?.members ?? []
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return all }
        return all.filter { member in
            [member.savedName, member.pushName, member.phone].contains { $0?.localizedStandardContains(wanted) == true }
        }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            Avatar(chat: chat, store: avatars, size: 96)
            Text(info?.subject ?? chat.title).font(.title2.bold()).multilineTextAlignment(.center)
            if let info {
                Text("Group · \(info.members.count) members").foregroundStyle(.secondary)
                details(info)
                memberList
            } else {
                ProgressView().controlSize(.small).padding()
                Text("Members appear once the group's info arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.medium + 4)
        .frame(width: 340)
    }

    @ViewBuilder
    private func details(_ info: GroupInfo) -> some View {
        if let description = info.description {
            Divider()
            ScrollView {
                Text(description)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
        }
        let notes = [
            info.announceOnly ? Label("Only admins can send messages", systemImage: "megaphone") : nil,
            info.locked ? Label("Only admins can edit group info", systemImage: "lock") : nil,
            chat.timer.map { Label("Disappearing messages: \($0)", systemImage: "timer") },
            info.createdSecs.map { secs in
                let date = Date(timeIntervalSince1970: TimeInterval(secs))
                return Label("Created \(date.formatted(date: .long, time: .omitted))", systemImage: "calendar")
            },
        ].compactMap(\.self)
        if !notes.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes.indices, id: \.self) { notes[$0] }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var memberList: some View {
        VStack(spacing: 6) {
            Divider()
            if (info?.members.count ?? 0) > 8 {
                TextField("Find a member", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                        MemberRow(member: member)
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MemberRow: View {
    let member: GroupMember

    /// A saved name as is; otherwise the number, with the self-chosen name
    /// marked "~" as WhatsApp does.
    private var name: String {
        if let saved = member.savedName {
            return saved
        }
        let pushed = member.pushName.map { "~\($0)" }
        return [member.phone, pushed].compactMap(\.self).joined(separator: " ").nonEmpty ?? "Unknown member"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if member.savedName != nil, let phone = member.phone {
                    Text(phone).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            switch member.role {
            case .owner: RoleBadge(title: "Owner", fill: AnyShapeStyle(.orange))
            case .admin: RoleBadge(title: "Admin", fill: AnyShapeStyle(.tint))
            case .member: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
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

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
