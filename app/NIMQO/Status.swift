import NimqoCore
import OSLog
import SwiftUI

/// Status updates of the last day, as they arrived while linked. Viewing
/// is local: nothing tells the poster it was seen.
@MainActor
@Observable
final class StatusStore {
    /// Where the core stores status updates (`inbox::STATUS`).
    nonisolated static let chat = "status@broadcast"

    var core: Core? {
        didSet {
            updates = []
            load()
        }
    }

    private(set) var updates: [ChatMessage] = []
    var selected: String?
    private let log = Logger(subsystem: "app.nimqo", category: "status")

    /// One row per person: your own first, then the latest update first.
    var posters: [Poster] {
        Dictionary(grouping: updates, by: \.sender)
            .compactMap { sender, posts in
                posts.max { $0.timestampSecs < $1.timestampSecs }.map {
                    Poster(id: sender, name: $0.displaySender, latest: $0.timestampSecs, count: posts.count)
                }
            }
            .sorted { ($0.id == "me" ? Int64.max : $0.latest) > ($1.id == "me" ? Int64.max : $1.latest) }
    }

    func updates(of sender: String) -> [ChatMessage] {
        updates.filter { $0.sender == sender }
    }

    /// Reads off the main thread; the store can be busy committing.
    func load() {
        guard let core else { return }
        Task.detached {
            let result = Result { try core.messages(chatId: Self.chat, limit: 1000) }
            await MainActor.run {
                guard self.core === core else { return }
                switch result {
                case let .success(updates): self.updates = updates
                case let .failure(error): self.log.error("status: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    struct Poster: Identifiable, Hashable {
        let id: String
        let name: String
        let latest: Int64
        let count: Int
    }
}

/// A person with status updates in the sidebar, ringed as on the phone.
struct StatusRow: View {
    let poster: StatusStore.Poster
    let avatars: AvatarStore

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if poster.id != "me", let image = avatars.image(for: poster.id) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.secondary)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(.circle)
            .padding(3)
            .overlay(Circle().strokeBorder(.tint, lineWidth: 2))
            .accessibilityHidden(true)
            .onAppear {
                if poster.id != "me" {
                    avatars.request(poster.id)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(poster.id == "me" ? String(localized: "My Status") : poster.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(ChatRow.stamp(Date(timeIntervalSince1970: TimeInterval(poster.latest))))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// One person's updates, oldest at the top, read-only.
struct StatusView: View {
    let poster: StatusStore.Poster
    let store: StatusStore
    let pictures: PictureStore

    var body: some View {
        ScrollView {
            TimelineStack {
                ForEach(store.updates(of: poster.id), id: \.seq) { update in
                    MessageBubble(message: update, showsSender: false, chat: StatusStore.chat, pictures: pictures)
                        .padding(.top, Theme.Spacing.small)
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .bottomAnchored()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(poster.id == "me" ? String(localized: "My Status") : poster.name)
        .navigationSubtitle(Text("^[\(poster.count) update](inflect: true) in the last 24 hours"))
        .windowBar()
    }
}
