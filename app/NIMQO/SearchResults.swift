import NimqoCore
import SwiftUI

extension CoreModel {
    /// Messages containing `text`, searched on this Mac only.
    func search(_ text: String) async -> [SearchHit] {
        guard let core else { return [] }
        return await Task.detached { (try? core.searchMessages(text: text)) ?? [] }.value
    }
}

/// The sidebar while searching: matching messages, newest first. Choosing
/// one opens its chat at that message.
struct SearchResults: View {
    let model: CoreModel
    let query: String
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        List(hits, id: \.seq) { hit in
            Button {
                Task { await model.reveal(hit.seq, in: hit.chatId) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title(hit.chatId)).font(.headline).lineLimit(1)
                        Spacer()
                        Text(
                            Date(timeIntervalSince1970: TimeInterval(hit.timestampSecs)),
                            format: .dateTime.day().month().year(.twoDigits)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(hit.fromMe ? "You: \(hit.body)" : hit.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if searched, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            // Wait for typing to pause.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hits = await model.search(query)
            searched = true
        }
    }

    private func title(_ chat: String) -> String {
        model.chats.first { $0.id == chat }?.title ?? "Chat"
    }
}

extension CoreModel {
    /// Opens `chat` and loads older pages until message `seq` is in, then
    /// asks the timeline to show it. Only what is stored here: the hit came
    /// from this Mac's store, so the phone is not asked.
    /// ponytail: a page at a time, up to 25 (5000 messages back); load
    /// around the message instead if that proves slow.
    func reveal(_ seq: Int64, in chat: String) async {
        revealing = nil
        selectedChat = chat
        for _ in 0 ..< 100 where messagesChat != chat {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0 ..< 25 {
            guard selectedChat == chat, messagesChat == chat else { return }
            if messages.contains(where: { $0.seq == seq }) {
                revealing = seq
                return
            }
            let oldest = messages.first?.seq
            guard hasOlderMessages else { return }
            await loadOlderMessages(phoneAnswered: true)
            guard messages.first?.seq != oldest else { return }
        }
    }
}
