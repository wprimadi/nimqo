import AVFoundation
import NimqoCore
import SwiftUI

/// Status updates over the whole window, one after another as on the
/// phone: each runs its time along a bar at the top, then the next starts,
/// until the last one ends or the viewer is closed. A new view per update.
struct StatusPlayer: View {
    let update: ChatMessage
    let store: StatusStore
    let pictures: PictureStore
    let avatars: AvatarStore
    @AppStorage(StatusStore.receiptsKey) private var tellsPoster = true
    @State private var progress = 0.0
    @State private var paused = false
    @State private var player: AVPlayer?
    @State private var source: MemoryAsset?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let chat = StatusStore.chat

    /// The poster's updates, for the bar segments.
    private var siblings: [ChatMessage] {
        store.updates(of: update.sender)
    }

    /// Shown for a set time; a video runs its own length once it plays.
    private var timed: Bool {
        update.kind != .video || pictures.didFail(chat: chat, message: update)
    }

    private var duration: Double {
        update.kind == .text ? min(max(Double(update.body?.count ?? 0) / 14, 5), 12) : 6
    }

    /// A photo shows once the full image is here (or it failed).
    private var ready: Bool {
        update.kind != .image || pictures.image(chat: chat, message: update)?.full == true
            || pictures.didFail(chat: chat, message: update)
    }

    var body: some View {
        let picture = pictures.image(chat: chat, message: update)
        ZStack {
            backdrop(picture?.image)
            GeometryReader { geo in
                content(picture, in: CGRect(origin: .zero, size: geo.size))
            }
            .padding(.horizontal, 72)
            .padding(.top, 110)
            .padding(.bottom, update.kind != .text && update.body != nil ? 130 : 56)
            chrome
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .accessibilityAddTraits(.isModal)
        .task { await run() }
        .onChange(of: paused) {
            guard let player else { return }
            let play = !paused
            // Pausing waits on the audio device; off the main thread.
            DispatchQueue.global(qos: .userInitiated).async { play ? player.play() : player.pause() }
        }
        .onDisappear(perform: retire)
    }

    /// Counts the update's time while it can be seen, then moves on.
    private func run() async {
        if !update.fromMe {
            store.view(update, tellPoster: tellsPoster)
        }
        if update.kind == .image {
            pictures.request(chat: chat, message: update)
        }
        var elapsed = 0.0
        var seenGeneration = -1
        let tick = 0.05
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(tick))
            if paused {
                continue
            }
            if !timed {
                guard let played = played(since: &seenGeneration) else { continue }
                progress = played
            } else if ready {
                elapsed += tick
                progress = min(elapsed / duration, 1)
            }
            if progress >= 1 {
                break
            }
        }
        if !Task.isCancelled {
            store.next()
        }
    }

    /// How much of the video has played; nil until it plays.
    private func played(since generation: inout Int) -> Double? {
        // Only when the store changed: reading the file decrypts it.
        if player == nil, pictures.generation != generation {
            generation = pictures.generation
            startPlayer()
        }
        guard let item = player?.currentItem, item.duration.isNumeric, item.duration.seconds > 0 else { return nil }
        return min(item.currentTime().seconds / item.duration.seconds, 1)
    }

    private func startPlayer() {
        guard let data = pictures.media(chat: chat, message: update) else {
            pictures.download(chat: chat, message: update)
            return
        }
        let asset = MemoryAsset(data)
        source = asset
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset.asset))
        self.player = player
        player.play()
    }

    private func retire() {
        guard let player else { return }
        self.player = nil
        let retired = (player, source)
        source = nil
        DispatchQueue.global(qos: .utility).async {
            retired.0.pause()
            retired.0.replaceCurrentItem(with: nil)
            _ = retired
        }
    }

    @ViewBuilder
    private func content(_ picture: (image: NSImage, full: Bool)?, in bounds: CGRect) -> some View {
        switch update.kind {
        case .image, .video:
            if let picture {
                let rect = LightboxView.fit(picture.image.size, in: bounds,
                                            maxScale: update.kind == .image && picture.full ? 2 : .infinity)
                Group {
                    if let player {
                        PlayerView(player: player).background(.black)
                    } else {
                        Image(nsImage: picture.image).resizable().scaledToFill()
                            .blur(radius: picture.full || update.kind == .video ? 0 : 8)
                    }
                }
                .overlay {
                    if pictures.didFail(chat: chat, message: update) {
                        RetryDownload(chat: chat, message: update, store: pictures)
                    } else if player == nil, !picture.full || update.kind == .video {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
                .position(x: rect.midX, y: rect.midY)
                .accessibilityLabel(update.body ?? (update.kind == .video ? "Video" : "Photo"))
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            Text(update.kind == .text ? update.body ?? "" : ChatMessage.describe(kind: update.kind, body: update.body))
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
                .textSelection(.enabled)
                .frame(maxWidth: 640, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
        }
    }

    /// The photo blurred behind itself; a text status on colour.
    private func backdrop(_ image: NSImage?) -> some View {
        Color.black
            .overlay {
                if update.kind == .text {
                    LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                } else if let image, !reduceTransparency {
                    Image(nsImage: image).resizable().scaledToFill()
                        .blur(radius: 60, opaque: true)
                        .saturation(1.5)
                        .opacity(0.55)
                }
            }
            .overlay { Color.black.opacity(update.kind == .text ? 0.1 : 0.35) }
            .clipped()
            .accessibilityHidden(true)
    }

    /// Bar, poster and buttons at the top, the caption at the bottom, and
    /// back and forward at the sides.
    private var chrome: some View {
        VStack(spacing: 12) {
            bar
            header
            Spacer()
            HStack {
                Button("Previous", systemImage: "chevron.left") { store.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .glassIcon()
                    .disabled(store.position == 0)
                Spacer()
                Button("Next", systemImage: "chevron.right") { store.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .glassIcon()
            }
            .frame(maxWidth: .infinity)
            Spacer()
            if update.kind != .text, let caption = update.body {
                Text(caption)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: .rect(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 592)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, 40)
        .padding(.bottom, Theme.Spacing.medium)
    }

    /// Seen in full, playing now, or still to come.
    private func filled(_ index: Int, current: Int) -> Double {
        if index < current {
            return 1
        }
        return index == current ? progress : 0
    }

    private var bar: some View {
        let current = siblings.firstIndex { $0.seq == update.seq } ?? 0
        return HStack(spacing: 4) {
            ForEach(Array(siblings.enumerated()), id: \.element.seq) { index, _ in
                Capsule().fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * filled(index, current: current))
                        }
                    }
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: 640)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if !update.fromMe, let image = avatars.image(for: update.sender) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(.circle)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.fromMe ? String(localized: "My Status") : update.displaySender).font(.headline)
                Text(Date(timeIntervalSince1970: TimeInterval(update.timestampSecs)), style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(paused ? "Play" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .glassIcon()
            Button("Close", systemImage: "xmark") { store.close() }
                .keyboardShortcut(.cancelAction)
                .glassIcon()
        }
        .frame(maxWidth: 640)
    }
}

private extension View {
    /// A round glass button showing only its icon.
    func glassIcon() -> some View {
        labelStyle(.iconOnly).buttonBorderShape(.circle).glassButton().controlSize(.large)
    }
}
