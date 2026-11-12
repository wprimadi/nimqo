import AppKit
import Lottie
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
            lastUse = [:]
            original = nil
            animations = [:]
            animatedFiles = [:]
            requested = []
            failed = []
            pendingSaves = [:]
            pendingPreviews = []
            saving = []
            previewing = nil
            generation += 1
        }
    }

    /// Bumped when pictures may have changed; the cache itself is not
    /// observed, so filling it during a view update changes nothing.
    private(set) var generation = 0
    /// Keyed by the message itself (chat, sender, id): storage order can be
    /// reused once a message is gone.
    /// Downscaled for the timeline; nil value: no picture yet.
    @ObservationIgnored private var images: [String: (image: NSImage, full: Bool)?] = [:]
    /// When each cached picture was last asked for, to drop the oldest.
    @ObservationIgnored private var lastUse: [String: Int] = [:]
    @ObservationIgnored private var uses = 0
    /// The one picture shown full size (lightbox, status), at its own size.
    @ObservationIgnored private var original: (key: String, picture: (image: NSImage, full: Bool))?
    /// Asked for this session; observed, as it shows a download running.
    private var requested: Set<String> = []
    /// Animated stickers, decoded once; nil marks "not one" until the next
    /// change, since the file may not be downloaded yet.
    @ObservationIgnored private var animations: [String: LottieAnimation?] = [:]
    /// Downloaded stickers checked for frames; nil value: a still one.
    @ObservationIgnored private var animatedFiles: [String: Data?] = [:]
    /// Downloads that failed; shown with a retry button.
    private var failed: Set<String> = []
    /// Files to save once downloaded (see MediaSaving.swift), by key.
    @ObservationIgnored var pendingSaves: [String: (chat: String, message: ChatMessage)] = [:]
    /// Keys being downloaded to save; shown as progress.
    var saving: Set<String> = []
    /// Of `pendingSaves`, those to show in Quick Look instead.
    @ObservationIgnored var pendingPreviews: Set<String> = []
    /// The file shown in Quick Look: a private copy, removed when it closes.
    var previewing: URL? {
        didSet {
            if let old = oldValue, old != previewing {
                try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
            }
        }
    }

    static func key(_ chat: String, _ message: ChatMessage) -> String {
        "\(chat)\n\(message.sender)\n\(message.id)"
    }

    func image(chat: String, message: ChatMessage) -> (image: NSImage, full: Bool)? {
        _ = generation
        let key = Self.key(chat, message)
        uses += 1
        lastUse[key] = uses
        if let cached = images[key] {
            return cached
        }
        let picture = (try? core?.picture(chatId: chat, seq: message.seq)) ?? nil
        let found = picture.flatMap { picture in
            Self.downscaled(picture.bytes, maxPixels: 640).map { ($0, picture.full) }
        }
        // A decoded picture is up to 1.6 MB, and the timeline draws only a
        // few screens of rows: keep the 48 asked for last, dropping the
        // oldest 16 at a time (one in a bubble on screen is still held by it).
        if images.count >= 48 {
            for old in lastUse.sorted(by: { $0.value < $1.value }).prefix(16) {
                images[old.key] = nil
                lastUse[old.key] = nil
            }
        }
        images[key] = .some(found)
        return found
    }

    /// The picture at its own size, for a full-window view; one at a time.
    func fullSize(chat: String, message: ChatMessage) -> (image: NSImage, full: Bool)? {
        _ = generation
        let key = Self.key(chat, message)
        if let original, original.key == key {
            return original.picture
        }
        guard let picture = (try? core?.picture(chatId: chat, seq: message.seq)) ?? nil,
              let image = NSImage(data: picture.bytes) else { return image(chat: chat, message: message) }
        original = (key, (image, picture.full))
        return (image, picture.full)
    }

    /// Decoded straight to at most `maxPixels` on its long side: a phone
    /// photo decoded whole is tens of megabytes, drawn in a 280-point tile.
    nonisolated static func downscaled(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    /// An animated sticker's animation, once its file is downloaded.
    func animation(chat: String, message: ChatMessage) -> LottieAnimation? {
        _ = generation
        let key = Self.key(chat, message)
        if let cached = animations[key] {
            return cached
        }
        let json = (try? core?.stickerAnimation(chatId: chat, seq: message.seq)) ?? nil
        let animation = json.flatMap { try? LottieAnimation.from(data: $0) }
        animations[key] = .some(animation)
        return animation
    }

    /// An animated WebP sticker's file (third-party packs; WhatsApp's own
    /// are Lottie), once downloaded; nil for a still one.
    func animatedSticker(chat: String, message: ChatMessage) -> Data? {
        _ = generation
        let key = Self.key(chat, message)
        if let cached = animatedFiles[key] {
            return cached
        }
        guard let picture = (try? core?.picture(chatId: chat, seq: message.seq)) ?? nil, picture.full else {
            return nil
        }
        // Frames decode at full size and the file comes from the sender: a
        // sticker is 512 pixels square, so anything far beyond stays still.
        let source = CGImageSourceCreateWithData(picture.bytes as CFData, nil)
        let animated = source.map { source in
            let size = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = size?[kCGImagePropertyPixelWidth] as? Int ?? .max
            let height = size?[kCGImagePropertyPixelHeight] as? Int ?? .max
            return (2 ... 300).contains(CGImageSourceGetCount(source)) && max(width, height) <= 1024
        } ?? false
        if animatedFiles.count >= 32 {
            animatedFiles = [:]
        }
        animatedFiles[key] = .some(animated ? picture.bytes : nil)
        return animated ? picture.bytes : nil
    }

    /// The picture is on screen: fetch the full image if only the thumbnail
    /// is here.
    func request(chat: String, message: ChatMessage) {
        let key = Self.key(chat, message)
        guard images[key]??.full != true else { return }
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
                pendingSaves[key] = nil
                pendingPreviews.remove(key)
                saving.remove(key)
            }
        }
    }

    /// Its full image was asked for and has not come yet.
    func isDownloading(chat: String, message: ChatMessage) -> Bool {
        requested.contains(Self.key(chat, message))
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
        // Only a picture still downloading can have changed; the rest stay
        // decoded instead of all being read again on every new message.
        images = images.filter { $0.value?.full == true || ($0.value != nil && !requested.contains($0.key)) }
        original = nil
        animations = animations.filter { $0.value != nil }
        generation += 1
        finishSaves()
    }
}

struct MessagePictureView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @Environment(Lightbox.self) private var lightbox: Lightbox?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isSticker: Bool {
        message.kind == .sticker
    }

    var body: some View {
        Group {
            if isSticker, let animation = store.animation(chat: chat, message: message) {
                StickerAnimation(animation: animation)
                    .frame(maxWidth: 160, maxHeight: 160)
            } else if isSticker, !reduceMotion, let file = store.animatedSticker(chat: chat, message: message) {
                AnimatedImage(data: file)
            } else if let picture = store.image(chat: chat, message: message) {
                Image(nsImage: picture.image)
                    .resizable()
                    .hugging(picture.image, in: isSticker ? CGSize(width: 160, height: 160) : MediaTile.bounds)
                    // A thumbnail is tiny; soften it until the image comes.
                    .blur(radius: picture.full ? 0 : 6)
                    .overlay {
                        if store.didFail(chat: chat, message: message) {
                            RetryDownload(chat: chat, message: message, store: store)
                        } else if !picture.full, store.isDownloading(chat: chat, message: message) {
                            // Only while it downloads: the timeline lays out
                            // every message, and a spinner on each picture
                            // never scrolled to redrew the window every frame.
                            ProgressView().controlSize(.small)
                        }
                    }
            } else if isSticker {
                // An animated sticker still downloading, without a preview.
                Label("Animated sticker", systemImage: "face.smiling")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, height: 120)
                    // No thumbnail either: say so when the download failed
                    // (an old photo gone from WhatsApp's servers).
                    .overlay(alignment: .bottom) {
                        if store.didFail(chat: chat, message: message) {
                            RetryDownload(chat: chat, message: message, store: store).padding(6)
                        }
                    }
            }
        }
        .modifier(MediaTile(enabled: !isSticker, hovering: hovering))
        .lightboxSource(message, isSticker ? nil : lightbox)
        .onHover { hovering = $0 && !isSticker }
        .accessibilityLabel(isSticker ? "Sticker" : "Photo")
        .accessibilityAddTraits(isSticker ? [] : .isButton)
        .accessibilityHint(isSticker ? "" : "Opens the photo.")
        // Nothing to enlarge until there is a picture; stickers stay put.
        .onTapGesture {
            if !isSticker, store.image(chat: chat, message: message) != nil {
                lightbox?.open(message, reduceMotion: reduceMotion)
            }
        }
        // A sticker always downloads: an animated one may show a preview
        // that counts as complete.
        // Once on screen: the timeline lays out every message at once.
        .onShown {
            if isSticker {
                store.download(chat: chat, message: message)
            } else {
                store.request(chat: chat, message: message)
            }
        }
    }
}

extension Image {
    /// Exactly `image`'s shape, as large as fits `bounds`. A frame that
    /// only capped the size grew to the full width, so a tall picture sat
    /// in a wider box and the rounded corners fell on the box, not on it.
    func hugging(_ image: NSImage, in bounds: CGSize) -> some View {
        let size = LightboxView.fit(image.size, in: CGRect(origin: .zero, size: bounds), maxScale: .infinity).size
        return scaledToFit().frame(width: size.width, height: size.height)
    }
}

/// A photo or video in a bubble: rounded, a hairline edge, and a lift on
/// hover to say it opens.
struct MediaTile: ViewModifier {
    /// The largest a photo or video is drawn in a bubble.
    static let bounds = CGSize(width: 280, height: 320)
    let enabled: Bool
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
                .brightness(hovering ? 0.04 : 0)
                .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
                .animation(.spring(duration: 0.25, bounce: 0), value: hovering)
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
        } else {
            content
        }
    }
}

/// An animated sticker, looping; still under Reduce Motion. One far off
/// screen is not drawn at all (`TimelineWindow`), so it needs no pausing
/// here; pausing it by visibility left every sticker still.
private struct StickerAnimation: View {
    let animation: LottieAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView(animation: animation)
            .playbackMode(reduceMotion
                ? .paused(at: .progress(0))
                : .playing(.fromProgress(0, toProgress: 1, loopMode: .loop)))
            .resizable()
            .scaledToFit()
            .frame(width: 160, height: 160)
    }
}

/// An animated WebP (or GIF) sticker, looping, played by ImageIO while on
/// screen; `TimelineWindow` removes one far off screen, which stops it.
private struct AnimatedImage: View {
    let data: Data
    @State private var frame: CGImage?
    @State private var playing: Playing?

    final class Playing {
        var stopped = false
    }

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: 160, height: 160)
        .onAppear {
            let playing = Playing()
            self.playing = playing
            CGAnimateImageDataWithBlock(data as CFData, nil) { _, image, stop in
                MainActor.assumeIsolated {
                    if playing.stopped {
                        stop.pointee = true
                    } else {
                        frame = image
                    }
                }
            }
        }
        .onDisappear { playing?.stopped = true }
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
