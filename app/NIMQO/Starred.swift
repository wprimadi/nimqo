import AppKit
import NimqoCore
import SwiftUI

/// Starred messages by day, newest first, each in the bubble it was sent
/// in. Click or Return opens it in its chat; Delete unstars it.
struct StarredView: View {
    let model: CoreModel
    /// Only this chat's, when set.
    var chat: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hits: [SearchHit]?
    @State private var query = ""
    @State private var selection: Int64?
    @State private var hovered: Int64?
    @FocusState private var focused: Bool

    private var shown: [SearchHit] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return hits ?? [] }
        return (hits ?? []).filter {
            $0.body.localizedCaseInsensitiveContains(text)
                || model.title(of: $0.chatId).localizedCaseInsensitiveContains(text)
        }
    }

    private var days: [(day: Date, hits: [SearchHit])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SearchField(prompt: "Search starred messages", text: $query, focused: $focused)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            list
        }
        .frame(width: 520, height: 640)
        .task { hits = await model.starredMessages().filter { chat == nil || $0.chatId == chat } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.yellow.gradient, in: .rect(cornerRadius: 11, style: .continuous))
                .shadow(color: .orange.opacity(0.3), radius: 8, y: 3)
                .symbolEffect(.bounce, value: hits?.count)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Starred Messages").font(.title2.bold())
                if let chat {
                    Text(model.title(of: chat)).font(.callout.weight(.medium))
                }
                Text(hits.map { "\($0.count) messages" } ?? " ")
                    .font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.hits, id: \.seq) { hit in
                        StarredRow(hit: hit, chat: model.summary(of: hit.chatId), avatars: model.avatars,
                                   hovered: hovered == hit.seq) { unstar(hit) }
                            .onHover { hovered = hovered.hovering(hit.seq, $0) }
                            .listRowSeparator(.hidden)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                } header: {
                    Text(Self.title(of: day.day)).font(.subheadline.weight(.semibold))
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { seqs in
            if let hit = seqs.first.flatMap(hit(_:)) {
                Button("Show in Chat", systemImage: "arrow.up.forward.app") { reveal(hit) }
                if hit.kind == .text {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hit.body, forType: .string)
                    }
                }
                Divider()
                Button("Unstar", systemImage: "star.slash") { unstar(hit) }
            }
        } primaryAction: { seqs in
            seqs.first.flatMap(hit(_:)).map(reveal)
        }
        .onDeleteCommand { selection.flatMap(hit(_:)).map(unstar) }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: shown.map(\.seq))
        .overlay {
            if hits == nil {
                ProgressView()
            } else if hits?.isEmpty == true {
                ContentUnavailableView {
                    Label("No Starred Messages", systemImage: "star")
                } description: {
                    Text("Right-click a message and choose Star to keep it here, a click away.")
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func hit(_ seq: Int64) -> SearchHit? {
        hits?.first { $0.seq == seq }
    }

    private func reveal(_ hit: SearchHit) {
        dismiss()
        Task { await model.reveal(hit.seq, in: hit.chatId) }
    }

    private func unstar(_ hit: SearchHit) {
        hits?.removeAll { $0.seq == hit.seq }
        Task { await model.setStarred(hit.seq, in: hit.chatId, false) }
    }

    private static func title(of day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return String(localized: "Today")
        }
        if calendar.isDateInYesterday(day) {
            return String(localized: "Yesterday")
        }
        let thisYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(thisYear ? .dateTime.weekday(.wide).day().month(.wide)
            : .dateTime.day().month(.wide).year())
    }
}

private struct StarredRow: View {
    let hit: SearchHit
    let chat: ChatSummary
    let avatars: AvatarStore
    let hovered: Bool
    let unstar: () -> Void

    private var symbol: String? {
        switch hit.kind {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .document: "doc"
        case .sticker: "face.smiling"
        default: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(chat: chat, store: avatars, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(chat.title).fontWeight(.semibold).lineLimit(1)
                    if hit.fromMe {
                        Text("· You").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(hit.date, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                bubble
            }
            Button("Unstar", systemImage: "star.fill", action: unstar)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.yellow)
                .opacity(hovered ? 1 : 0)
                .help("Unstar")
                .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Unstar", unstar)
    }

    private var bubble: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            Text(ChatMessage.describe(kind: hit.kind, body: hit.body.isEmpty ? nil : hit.body))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hit.fromMe ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.7)),
                    in: .rect(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: hit.fromMe ? .trailing : .leading)
    }
}

extension SearchHit {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampSecs))
    }
}

extension CoreModel {
    /// A chat from the list, or a stand-in for one no longer there.
    func summary(of chat: String) -> ChatSummary {
        chats.first { $0.id == chat }
            ?? ChatSummary(id: chat, title: title(of: chat), isGroup: chat.hasSuffix("@g.us"), phone: nil,
                           preview: "", lastActivity: .now, unread: 0, timer: nil, muted: false)
    }
}
