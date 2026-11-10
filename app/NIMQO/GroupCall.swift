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

    /// False when this is not a group call: the frame is for the 1:1 picture.
    nonisolated func show(_ frame: Data, orientation: UInt8, from id: String) -> Bool {
        let route = routes.withLock { routes -> RemoteVideo?? in routes.map { $0[id] } }
        switch route {
        case .none: return false
        case let .some(.some(picture)): picture.show(frame, orientation: orientation)
        // The first frame of someone new: the decoder asks for a keyframe anyway.
        case .some(.none): Task { @MainActor in self.add(id) }
        }
        return true
    }

    func reset() {
        routes.withLock { $0 = nil }
        pictures.values.forEach { $0.reset() }
        pictures = [:]
    }

    private func add(_ id: String) {
        guard pictures[id] == nil else { return }
        let picture = RemoteVideo()
        // ponytail: one keyframe request for the whole call, per-sender if the engine grows one.
        picture.onLoss = { [weak self] in self?.onLoss?() }
        let added = routes.withLock { routes in
            guard routes != nil else { return false }
            routes?[id] = picture
            return true
        }
        if added {
            pictures[id] = picture
        }
    }
}

/// One tile per other participant: their camera, else their picture.
struct GroupGrid: View {
    let participants: [CallParticipant]
    let video: GroupVideo
    let summary: (String) -> ChatSummary
    let avatars: AvatarStore

    var body: some View {
        let columns = participants.count <= 1 ? 1 : participants.count <= 4 ? 2 : 3
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(participants, id: \.id) { person in
                tile(person)
                    .frame(height: columns == 1 ? 420 : columns == 2 ? 200 : 130)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(8)
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
