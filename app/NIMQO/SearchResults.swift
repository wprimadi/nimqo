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
/// one opens its chat.
struct SearchResults: View {
    let model: CoreModel
    let query: String
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        List(hits, id: \.seq) { hit in
            Button {
                model.selectedChat = hit.chatId
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
