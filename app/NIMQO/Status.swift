import NimqoCore
import OSLog
import SwiftUI

/// Status updates of the last day, as they arrived while linked, and the
/// ones playing in the viewer.
@MainActor
@Observable
final class StatusStore {
    /// Where the core stores status updates (`inbox::STATUS`).
    nonisolated static let chat = "status@broadcast"
    /// Settings: whether viewing someone's status tells them (on by default).
    nonisolated static let receiptsKey = "sendsStatusViewReceipts"

    var core: Core? {
        didSet {
            updates = []
            unviewed = []
            close()
            load()
        }
    }

    private(set) var updates: [ChatMessage] = []
    /// Updates (seqs) of other people not opened yet.
    private(set) var unviewed: Set<Int64> = []
    var selected: String?
    /// What the viewer plays, in order; empty while it is closed.
    private(set) var queue: [ChatMessage] = []
    private(set) var position = 0
    private let log = Logger(subsystem: "app.nimqo", category: "status")

    var playing: ChatMessage? {
        queue.indices.contains(position) ? queue[position] : nil
    }

    /// One row per person: yours, then people with something new, then the
    /// rest; the latest first within each.
    var posters: [Poster] {
        Dictionary(grouping: updates, by: \.sender)
            .compactMap { sender, posts in
                posts.max { $0.timestampSecs < $1.timestampSecs }.map {
                    Poster(id: sender, name: $0.displaySender, latest: $0.timestampSecs, count: posts.count,
                           unviewed: posts.contains { self.unviewed.contains($0.seq) })
                }
            }
            .sorted(by: Self.order)
    }

    nonisolated static func order(_ lhs: Poster, _ rhs: Poster) -> Bool {
        let rank = { (poster: Poster) -> Int in
            if poster.id == "me" {
                return 0
            }
            return poster.unviewed ? 1 : 2
        }
        return rank(lhs) == rank(rhs) ? lhs.latest > rhs.latest : rank(lhs) < rank(rhs)
    }

    func updates(of sender: String) -> [ChatMessage] {
        updates.filter { $0.sender == sender }
    }

    /// Plays `poster`'s updates from the first one not seen, then the
    /// people after them in the list.
    func play(from poster: String) {
        let order = posters
        guard let start = order.firstIndex(where: { $0.id == poster }) else { return }
        queue = order[start...].flatMap { updates(of: $0.id) }
        position = queue.firstIndex { $0.sender == poster && unviewed.contains($0.seq) } ?? 0
    }

    func next() {
        if position + 1 < queue.count {
            position += 1
        } else {
            close()
        }
    }

    func previous() {
        position = max(position - 1, 0)
    }

    func close() {
        queue = []
        position = 0
        selected = nil
    }

    /// Records `update` opened; the core tells its poster only when asked.
    func view(_ update: ChatMessage, tellPoster: Bool) {
        guard unviewed.remove(update.seq) != nil, let core else { return }
        let log = log
        Task.detached {
            do { try core.viewStatus(seq: update.seq, tellPoster: tellPoster) } catch {
                log.error("view status: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Reads off the main thread; the store can be busy committing.
    func load() {
        guard let core else { return }
        Task.detached {
            let result = Result { try (core.messages(chatId: Self.chat, limit: 1000), core.unviewedStatuses()) }
            await MainActor.run {
                guard self.core === core else { return }
                switch result {
                case let .success((updates, unviewed)):
                    self.updates = updates
                    self.unviewed = Set(unviewed)
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
        let unviewed: Bool
    }
}

/// A person with status updates in the sidebar, ringed while it has
/// something new, as on the phone.
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
            .overlay {
                Circle().strokeBorder(poster.unviewed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary), lineWidth: 2)
            }
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
