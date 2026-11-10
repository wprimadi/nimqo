import NimqoCore
import Observation
import os
import SwiftUI

/// Each group-call participant's camera, keyed by the id their video is
/// tagged with. Frames come on Rust threads; the pictures live on the main actor.
@MainActor
@Observable
final class GroupVideo {
    private(set) var pictures: [String: RemoteVideo] = [:]
    /// Set while a group call is on; 1:1 video keeps going to `CallStore.remote`.
    private nonisolated let routes = OSAllocatedUnfairLock<[String: RemoteVideo]?>(initialState: nil)
    @ObservationIgnored var onLoss: (() -> Void)?

    func start() {
        routes.withLock { $0 = $0 ?? [:] }
    }

    /// One picture per participant the call lists: video tagged with any
    /// other id is dropped, so a stream of made-up ids builds nothing.
    func update(_ participants: [CallParticipant]) {
        guard routes.withLock({ $0 != nil }) else { return }
        let ids = Set(participants.map(\.id))
        for (id, picture) in pictures where !ids.contains(id) {
            picture.reset()
        }
        pictures = pictures.filter { ids.contains($0.key) }
        for id in ids where pictures[id] == nil {
            let picture = RemoteVideo()
            // ponytail: one keyframe request for the whole call, per-sender if the engine grows one.
            picture.onLoss = { [weak self] in self?.onLoss?() }
            pictures[id] = picture
        }
        let pictures = pictures
        routes.withLock { routes in
            if routes != nil {
                routes = pictures
            }
        }
    }

    /// False when this is not a group call: the frame is for the 1:1 picture.
    nonisolated func show(_ frame: Data, orientation: UInt8, from id: String) -> Bool {
        guard let route = routes.withLock({ $0.map { $0[id] } }) else { return false }
        route?.show(frame, orientation: orientation)
        return true
    }

    func reset() {
        routes.withLock { $0 = nil }
        pictures.values.forEach { $0.reset() }
        pictures = [:]
    }
}

/// One tile per other participant: their camera, else their picture.
struct GroupGrid: View {
    let participants: [CallParticipant]
    let video: GroupVideo
    let summary: (String) -> ChatSummary
    let avatars: AvatarStore

    var body: some View {
        let count = max(participants.count, 1)
        let columns = count == 1 ? 1 : count <= 4 ? 2 : 3
        let rows = (count + columns - 1) / columns
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let height = (geometry.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let grid = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
            LazyVGrid(columns: grid, spacing: spacing) {
                ForEach(participants, id: \.id) { person in
                    tile(person)
                        .frame(height: max(height, 0))
                        .clipShape(.rect(cornerRadius: columns == 1 ? 0 : 12, style: .continuous))
                }
            }
        }
        .padding(count == 1 ? 0 : 6)
        .animation(.spring(duration: 0.35, bounce: 0), value: participants)
    }

    private func tile(_ person: CallParticipant) -> some View {
        let chat = summary(person.chat)
        return ZStack(alignment: .bottomLeading) {
            Color.white.opacity(0.08)
            if let picture = video.pictures[person.id], picture.hasPicture {
                RemotePicture(remote: picture)
            } else {
                Avatar(chat: chat, store: avatars, size: 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 4) {
                Text(chat.title).lineLimit(1)
                if !person.joined {
                    Text("Ringing…").foregroundStyle(.white.opacity(0.6))
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(8)
        }
        .opacity(person.joined ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }
}
