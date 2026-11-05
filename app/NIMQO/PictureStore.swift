import AppKit
import NimqoCore
import Observation
import SwiftUI

/// Message pictures: the thumbnail from the message right away, the full
/// image once the core has downloaded it. Downloads are asked for only when
/// a picture is on screen, once per message per session.
@MainActor
@Observable
final class PictureStore {
    var core: Core? {
        didSet {
            images = [:]
            requested = []
            generation += 1
        }
    }

    /// Bumped when pictures may have changed; the cache itself is not
    /// observed, so filling it during a view update changes nothing.
    private var generation = 0
    @ObservationIgnored private var images: [Int64: (image: NSImage, full: Bool)] = [:]
    @ObservationIgnored private var requested: Set<Int64> = []

    func image(chat: String, seq: Int64) -> (image: NSImage, full: Bool)? {
        _ = generation
        if let cached = images[seq] {
            return cached
        }
        guard let picture = (try? core?.picture(chatId: chat, seq: seq)) ?? nil,
              let image = NSImage(data: picture.bytes) else { return nil }
        images[seq] = (image, picture.full)
        return (image, picture.full)
    }

    /// The picture is on screen: fetch the full image if only the thumbnail
    /// is here.
    func request(chat: String, seq: Int64) {
        guard let core, images[seq]?.full != true, requested.insert(seq).inserted else { return }
        core.downloadPicture(chatId: chat, seq: seq)
    }

    /// A chat changed: a full image may have arrived for its thumbnails.
    func invalidate() {
        images = images.filter(\.value.full)
        generation += 1
    }
}

struct MessagePictureView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore

    var body: some View {
        Group {
            if let picture = store.image(chat: chat, seq: message.seq) {
                Image(nsImage: picture.image)
                    .resizable()
                    .scaledToFit()
                    // A thumbnail is tiny; soften it until the image comes.
                    .blur(radius: picture.full ? 0 : 6)
                    .overlay {
                        if !picture.full {
                            ProgressView().controlSize(.small)
                        }
                    }
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, height: 120)
            }
        }
        .frame(maxWidth: 280, maxHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Photo")
        .onAppear { store.request(chat: chat, seq: message.seq) }
    }
}
