import NimqoCore
import SwiftUI

/// "@" in a group's composer: the members to mention, picked by click,
/// Return or Tab, Up and Down to move, Esc to dismiss. The field shows
/// "@Name"; the message carries "@number", as WhatsApp sends it.
extension Composer {
    /// What follows the last "@" at the end of the field, while picking.
    var mentionQuery: String? {
        guard members != nil, let sign = text.lastIndex(of: "@") else { return nil }
        if sign > text.startIndex, !text[text.index(before: sign)].isWhitespace {
            return nil
        }
        let query = text[text.index(after: sign)...]
        guard query.count <= 30, !query.contains(where: \.isNewline),
              !mentioned.keys.contains(where: { query.hasPrefix("\($0) ") }) else { return nil }
        return String(query)
    }

    var suggestions: [GroupMember] {
        guard let query = mentionQuery, query != dismissedMention, let members = members?() else { return [] }
        return Array(members.lazy.filter {
            !$0.isMe && (query.isEmpty || $0.mentionLabel.localizedStandardContains(query)
                || ($0.phone ?? "").contains(query))
        }.prefix(6))
    }

    /// Up, Down, Return, Tab and Esc while the list is open.
    func mentionKey(_ key: KeyEquivalent) -> KeyPress.Result {
        let shown = suggestions
        guard !shown.isEmpty else { return .ignored }
        switch key {
        case .upArrow: mentionHighlight = max(mentionHighlight - 1, 0)
        case .downArrow: mentionHighlight = min(mentionHighlight + 1, shown.count - 1)
        case .escape: dismissedMention = mentionQuery
        default: mention(shown[min(mentionHighlight, shown.count - 1)])
        }
        return .handled
    }

    func mention(_ member: GroupMember) {
        guard let sign = text.lastIndex(of: "@") else { return }
        let label = member.mentionLabel
        text = String(text[..<sign]) + "@\(label) "
        mentioned[label] = String(member.id.prefix { $0 != "@" })
        mentionHighlight = 0
    }

    /// The text to send: each picked "@Name" as "@number", longest first
    /// so one name inside another is not cut.
    func withMentions(_ draft: String) -> String {
        mentioned.keys.sorted { $0.count > $1.count }.reduce(draft) { out, label in
            out.replacingOccurrences(of: "@\(label)", with: "@\(mentioned[label] ?? label)")
        }
    }

    var mentionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, member in
                Button { mention(member) } label: {
                    HStack(spacing: 8) {
                        // The picture tells apart one person's two numbers.
                        if let avatars {
                            Avatar(chat: member.summary, store: avatars, size: 24)
                        }
                        Text(member.mentionLabel).lineLimit(1)
                        Spacer()
                        if let phone = member.phone, member.savedName != nil || member.pushName != nil {
                            Text(phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                    .background(index == mentionHighlight ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: 320, alignment: .leading)
        .glassSurface(in: .rect(cornerRadius: 14))
        .onChange(of: mentionQuery) { mentionHighlight = 0 }
        .accessibilityLabel("Members to mention")
    }
}

extension ContactStore {
    /// `chat`'s members, read when "@" is typed; nil outside groups.
    func mentionable(_ chat: ChatSummary) -> (@MainActor () -> [GroupMember])? {
        guard chat.isGroup else { return nil }
        return { [weak self] in self?.groups[chat.id]?.members ?? [] }
    }
}

extension GroupMember {
    /// As written after "@": the saved name, else the chosen one, else the number.
    var mentionLabel: String {
        savedName ?? pushName ?? phone ?? String(id.prefix { $0 != "@" })
    }

    /// As a chat, for its `Avatar`.
    var summary: ChatSummary {
        ChatSummary(id: id, title: displayName, isGroup: false, phone: phone,
                    preview: "", lastActivity: .now, unread: 0, timer: nil, muted: false)
    }
}
