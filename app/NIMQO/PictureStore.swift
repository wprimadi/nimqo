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
            failed = []
            generation += 1
        }
    }

    /// Bumped when pictures may have changed; the cache itself is not
    /// observed, so filling it during a view update changes nothing.
    private(set) var generation = 0
    /// Keyed by the message itself (chat, sender, id): storage order can be
    /// reused once a message is gone.
    @ObservationIgnored private var images: [String: (image: NSImage, full: Bool)] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    /// Downloads that failed; shown with a retry button.
    private var failed: Set<String> = []

    private static func key(_ chat: String, _ message: ChatMessage) -> String {
        "\(chat)\n\(message.sender)\n\(message.id)"
    }

    func image(chat: String, message: ChatMessage) -> (image: NSImage, full: Bool)? {
        _ = generation
        let key = Self.key(chat, message)
        if let cached = images[key] {
            return cached
        }
        guard let picture = (try? core?.picture(chatId: chat, seq: message.seq)) ?? nil,
              let image = NSImage(data: picture.bytes) else { return nil }
        images[key] = (image, picture.full)
        return (image, picture.full)
    }

    /// The picture is on screen: fetch the full image if only the thumbnail
    /// is here.
    func request(chat: String, message: ChatMessage) {
        let key = Self.key(chat, message)
        guard images[key]?.full != true else { return }
        download(chat: chat, message: message)
    }

    /// Asks the core for the message's file once per session, unless it
    /// failed and is asked for again (`retry`).
    func download(chat: String, message: ChatMessage) {
        let key = Self.key(chat, message)
        guard let core, requested.insert(key).inserted else { return }
        Task {
            if await !core.downloadMedia(chatId: chat, seq: message.seq) {
                requested.remove(key)
                failed.insert(key)
            }
        }
    }

    func didFail(chat: String, message: ChatMessage) -> Bool {
        failed.contains(Self.key(chat, message))
    }

    func retry(chat: String, message: ChatMessage) {
        failed.remove(Self.key(chat, message))
        download(chat: chat, message: message)
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
    @State private var enlarged = false

    private var isSticker: Bool {
        message.kind == .sticker
    }

    var body: some View {
        Group {
            if let picture = store.image(chat: chat, message: message) {
                Image(nsImage: picture.image)
                    .resizable()
                    .scaledToFit()
                    // A thumbnail is tiny; soften it until the image comes.
                    .blur(radius: picture.full ? 0 : 6)
                    .overlay {
                        if store.didFail(chat: chat, message: message) {
                            RetryDownload(chat: chat, message: message, store: store)
                        } else if !picture.full {
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
        // Stickers are drawn small, as on the phone.
        .frame(maxWidth: isSticker ? 160 : 280, maxHeight: isSticker ? 160 : 320)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(isSticker ? "Sticker" : "Photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the photo at full size.")
        .onTapGesture { enlarged = true }
        .onAppear { store.request(chat: chat, message: message) }
        .sheet(isPresented: $enlarged) {
            PictureViewer(chat: chat, message: message, store: store)
        }
    }
}

/// The photo at full size in a sheet; Escape or Done closes it.
struct PictureViewer: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let picture = store.image(chat: chat, message: message) {
                Image(nsImage: picture.image)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        idealWidth: picture.image.size.width,
                        maxWidth: .infinity,
                        idealHeight: picture.image.size.height,
                        maxHeight: .infinity
                    )
                    .accessibilityLabel(message.body ?? "Photo")
                if store.didFail(chat: chat, message: message) {
                    RetryDownload(chat: chat, message: message, store: store)
                } else if !picture.full {
                    Label("Downloading the full photo…", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let caption = message.body {
                Text(caption).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(minWidth: 400, maxWidth: 1200, minHeight: 300, maxHeight: 900)
    }
}

/// A failed download: says so and asks for it again.
struct RetryDownload: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore

    var body: some View {
        Button("Couldn't download. Try Again", systemImage: "arrow.clockwise") {
            store.retry(chat: chat, message: message)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("It may no longer be on WhatsApp's servers, or the Mac is offline.")
    }
}
