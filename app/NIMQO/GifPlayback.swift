import AVFoundation
import AVKit
import NimqoCore
import SwiftUI

/// A GIF in the timeline: its still until it is on screen, then fetched and
/// looping, silent and without controls, from memory (never unencrypted on
/// disk). It pauses off screen, and stays still under Reduce Motion. Click
/// to open it large.
struct GifMessageView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @Environment(Lightbox.self) private var lightbox: Lightbox?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loop: GifLoop?
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Group {
            if let still = store.image(chat: chat, message: message) {
                Image(nsImage: still.image).resizable().hugging(still.image, in: MediaTile.bounds)
            } else {
                Color.secondary.opacity(0.2).frame(width: 220, height: 140)
            }
        }
        .overlay {
            if let loop {
                LoopView(player: loop.player).transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            Text("GIF")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: .capsule)
                .padding(8)
                .opacity(loop == nil || hovering ? 1 : 0)
        }
        .modifier(MediaTile(enabled: true, hovering: hovering))
        .lightboxSource(message, lightbox)
        .onHover { hovering = $0 }
        .onShownChange { shown = $0 }
        .task(id: [store.generation, shown ? 1 : 0, reduceMotion ? 1 : 0]) { start() }
        .onDisappear { loop?.player.pause() }
        .accessibilityLabel("GIF")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the GIF.")
        .onTapGesture { lightbox?.open(message, reduceMotion: reduceMotion) }
    }

    private func start() {
        guard shown, !reduceMotion else {
            loop?.player.pause()
            return
        }
        if let loop {
            loop.player.play()
            return
        }
        guard let data = store.media(chat: chat, message: message) else {
            store.download(chat: chat, message: message)
            return
        }
        let made = GifLoop(data)
        withAnimation(.easeOut(duration: 0.2)) { loop = made }
        made.player.play()
    }
}

/// A silent player that starts over at the end.
@MainActor
final class GifLoop {
    let player: AVQueuePlayer
    private let source: MemoryAsset
    private let looper: AVPlayerLooper

    init(_ data: Data) {
        source = MemoryAsset(data)
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: source.asset))
    }
}

/// The video alone, filling its tile; clicks go to the tile.
struct LoopView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        view.player = player
    }
}
