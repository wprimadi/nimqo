import AVFoundation
import NimqoCore
import SwiftUI

/// The photo or video open over the conversation. It grows out of its
/// bubble and shrinks back into it, so the bubbles report where they are.
@MainActor
@Observable
final class Lightbox {
    nonisolated static let space = "conversation"

    private(set) var message: ChatMessage?
    /// False while growing out of or shrinking back into the bubble.
    private(set) var expanded = false
    /// Bubble frames by seq, in the conversation's coordinate space; not
    /// observed, so scrolling redraws nothing.
    @ObservationIgnored var frames: [Int64: CGRect] = [:]

    func open(_ message: ChatMessage, reduceMotion: Bool) {
        guard self.message == nil else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                self.message = message
                expanded = true
            }
            return
        }
        self.message = message
        // Next turn: drawn at the bubble first, then grows.
        Task { @MainActor in
            withAnimation(.spring(duration: 0.45, bounce: 0.15)) { self.expanded = true }
        }
    }

    func close(reduceMotion: Bool) {
        guard message != nil else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                message = nil
                expanded = false
            }
            return
        }
        withAnimation(.spring(duration: 0.38, bounce: 0)) {
            expanded = false
        } completion: {
            if !self.expanded {
                self.message = nil
            }
        }
    }
}

extension View {
    /// Tells the lightbox where this message's bubble media is.
    func lightboxSource(_ message: ChatMessage, _ lightbox: Lightbox?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Lightbox.space)) } action: {
            lightbox?.frames[message.seq] = $0
        }
        // Hidden while it is open, so the photo seems to leave the bubble.
        .opacity(lightbox?.message?.seq == message.seq ? 0 : 1)
    }
}

/// The open photo or video, over a blur of itself, with its sender, time
/// and caption. Photos zoom (pinch, double-click) and pan; dragging an
/// unzoomed photo away closes it. Escape or a click outside closes.
struct LightboxView: View {
    let lightbox: Lightbox
    let message: ChatMessage
    let chat: String
    let store: PictureStore
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var settledPan: CGSize = .zero
    @State private var player: AVPlayer?
    @State private var source: MemoryAsset?
    @State private var captionOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isVideo: Bool {
        message.kind == .video
    }

    /// How far a drag has pulled the photo away, 0 to 1: fades the backdrop.
    private var pull: CGFloat {
        zoom > 1 ? 0 : min(hypot(pan.width, pan.height) / 300, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let picture = store.image(chat: chat, message: message)
            let size = picture?.image.size ?? CGSize(width: 16, height: 9)
            let bounds = CGRect(origin: .zero, size: geo.size)
            // A video's still and a photo's thumbnail are tiny: only a full
            // photo is held to twice its own size.
            let target = Self.fit(size, in: bounds.insetBy(dx: 48, dy: 76),
                                  maxScale: isVideo || picture?.full != true ? .infinity : 2)
            let origin = geo.frame(in: .named(Lightbox.space)).origin
            let start = lightbox.frames[message.seq].map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                ?? target.insetBy(dx: target.width * 0.3, dy: target.height * 0.3)
            let rect = lightbox.expanded ? target : start
            ZStack {
                backdrop(picture?.image)
                    .opacity(lightbox.expanded ? 1 - pull * 0.7 : 0)
                    .onTapGesture { close() }
                media(picture)
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(.rect(cornerRadius: lightbox.expanded ? 18 : 12, style: .continuous))
                    .shadow(color: .black.opacity(lightbox.expanded ? 0.45 : 0), radius: 40, y: 18)
                    .scaleEffect(zoom * (1 - pull * 0.15))
                    .offset(pan)
                    .position(x: rect.midX, y: rect.midY)
                    .modifier(PhotoGestures(enabled: !isVideo, zoom: $zoom, settledZoom: $settledZoom,
                                            pan: $pan, settledPan: $settledPan, toggleZoom: toggleZoom, close: close))
                chrome
                    .opacity(lightbox.expanded ? 1 - pull : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityAddTraits(.isModal)
        .task(id: store.generation) { await loadVideo() }
        .onDisappear {
            if let player {
                DispatchQueue.global(qos: .utility).async { player.pause() }
            }
        }
    }

    private func toggleZoom() {
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            (zoom, settledZoom) = zoom > 1 ? (1, 1) : (2.5, 2.5)
            (pan, settledPan) = (.zero, .zero)
        }
    }

    private func close() {
        if let player {
            // The still shrinks back, not the live player. Pausing waits on
            // the audio device, which can hang for seconds when macOS
            // cannot start it, so that happens off the main thread.
            self.player = nil
            let retired = (player, source)
            source = nil
            DispatchQueue.global(qos: .utility).async {
                retired.0.pause()
                retired.0.replaceCurrentItem(with: nil)
                _ = retired
            }
        }
        if reduceMotion {
            lightbox.close(reduceMotion: true)
            return
        }
        withAnimation(.spring(duration: 0.38, bounce: 0)) {
            zoom = 1
            pan = .zero
        }
        lightbox.close(reduceMotion: false)
    }

    /// The photo itself, blurred and dimmed, filling the view.
    private func backdrop(_ image: NSImage?) -> some View {
        // In an overlay, so the filled image cannot size the backdrop: a
        // tall or wide photo made it, and with it the caption and buttons,
        // larger than the window.
        Color.black
            .overlay {
                if let image, !reduceTransparency {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 60, opaque: true)
                        .saturation(1.5)
                        .opacity(0.55)
                }
            }
            .overlay { Color.black.opacity(0.35) }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func media(_ picture: (image: NSImage, full: Bool)?) -> some View {
        if let player {
            PlayerView(player: player).background(.black)
        } else if let picture {
            Image(nsImage: picture.image)
                .resizable()
                .scaledToFill()
                .blur(radius: picture.full || isVideo ? 0 : 8)
                .overlay {
                    if store.didFail(chat: chat, message: message) {
                        RetryDownload(chat: chat, message: message, store: store)
                    } else if !picture.full || isVideo {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .accessibilityLabel(message.body ?? (isVideo ? "Video" : "Photo"))
        } else {
            Color.black.overlay { ProgressView().tint(.white) }
        }
    }

    /// Sender and time at the top, caption at the bottom, on glass.
    private var chrome: some View {
        VStack {
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.displaySender).font(.headline)
                    Text(Date(timeIntervalSince1970: TimeInterval(message.timestampSecs))
                        .formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassSurface(in: .capsule)
                Spacer()
                if !isVideo {
                    Button(action: toggleZoom) {
                        Label(zoom > 1 ? "Fit" : "Zoom In",
                              systemImage: zoom > 1 ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .glassButton()
                    .controlSize(.large)
                }
                Button("Close", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .glassButton()
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if let caption = message.body {
                // The glass hugs the text; the outer frame only caps its
                // width (a horizontal fixedSize made it one endless line,
                // pushing the buttons and itself off screen).
                Text(caption)
                    .lineLimit(captionOpen ? nil : 4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: .rect(cornerRadius: 18, style: .continuous))
                    .onTapGesture { captionOpen.toggle() }
                    .frame(maxWidth: 592)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func loadVideo() async {
        guard isVideo, player == nil else { return }
        guard let data = store.media(chat: chat, message: message) else {
            store.download(chat: chat, message: message)
            return
        }
        let asset = MemoryAsset(data)
        source = asset
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset.asset))
        withAnimation(.easeOut(duration: 0.25)) { self.player = player }
        player.play()
    }

    /// The largest rect of `size`'s shape inside `bounds`, centred, scaled
    /// up at most `maxScale` times.
    nonisolated static func fit(_ size: CGSize, in bounds: CGRect, maxScale: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height, maxScale)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// Pinch and double-click zoom, drag to pan; unzoomed, a drag pulls the
/// photo away and, far or fast enough, closes it.
private struct PhotoGestures: ViewModifier {
    let enabled: Bool
    @Binding var zoom: CGFloat
    @Binding var settledZoom: CGFloat
    @Binding var pan: CGSize
    @Binding var settledPan: CGSize
    let toggleZoom: () -> Void
    let close: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .gesture(magnify.simultaneously(with: drag))
                .onTapGesture(count: 2, perform: toggleZoom)
        } else {
            content
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = min(max(settledZoom * $0.magnification, 1), 5) }
            .onEnded { _ in
                settledZoom = zoom
                if zoom == 1 {
                    withAnimation(.spring(duration: 0.3)) { (pan, settledPan) = (.zero, .zero) }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                pan = CGSize(width: settledPan.width + value.translation.width,
                             height: settledPan.height + value.translation.height)
            }
            .onEnded { value in
                if zoom > 1 {
                    settledPan = pan
                    return
                }
                let flung = hypot(value.predictedEndTranslation.width, value.predictedEndTranslation.height)
                if flung > 260 {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { pan = .zero }
                }
            }
    }
}

extension ChatMessage {
    /// "You", the saved name, else the self-chosen one marked "~".
    var displaySender: String {
        fromMe ? String(localized: "You") : contactName ?? senderName.map { "~\($0)" } ?? String(localized: "Unknown")
    }
}
