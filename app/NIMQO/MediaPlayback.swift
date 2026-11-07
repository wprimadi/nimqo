import AVFoundation
import AVKit
import NimqoCore
import SwiftUI

extension PictureStore {
    /// The downloaded video or audio of `message`, decrypted into memory
    /// only (it never touches disk unencrypted); nil until downloaded.
    func media(chat: String, message: ChatMessage) -> Data? {
        (try? core?.mediaFile(chatId: chat, seq: message.seq)) ?? nil
    }
}

/// A voice note or audio file: play and pause in the bubble. Downloaded on
/// the first tap; WhatsApp's Ogg Opus plays through AVAudioPlayer.
struct AudioMessageView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var playback = AudioPlayback()
    @State private var waiting = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            let playing = playback.isPlaying
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill", action: toggle)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title2)
            if store.didFail(chat: chat, message: message) {
                RetryDownload(chat: chat, message: message, store: store)
            } else if waiting {
                ProgressView().controlSize(.small)
            } else if let duration = playback.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Audio").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio message")
        // A finished download arrives as a chat change.
        .onChange(of: store.generation) {
            if waiting {
                toggle()
            }
        }
        .onDisappear { playback.stop() }
    }

    private func toggle() {
        if playback.isLoaded {
            playback.toggle()
        } else if let data = store.media(chat: chat, message: message) {
            waiting = false
            playback.load(data)
            playback.toggle()
        } else if !waiting {
            waiting = true
            store.download(chat: chat, message: message)
        }
    }
}

@MainActor
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval?
    @ObservationIgnored private var player: AVAudioPlayer?

    var isLoaded: Bool {
        player != nil
    }

    func load(_ data: Data) {
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        duration = player?.duration
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in isPlaying = false }
    }
}

/// A video: its still with a play mark; opening it downloads and plays.
struct VideoMessageView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @Environment(Lightbox.self) private var lightbox: Lightbox?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 2)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: .circle)
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                .environment(\.colorScheme, .dark)
                .scaleEffect(hovering && !reduceMotion ? 1.1 : 1)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .modifier(MediaTile(enabled: true, hovering: hovering))
        .lightboxSource(message, lightbox)
        .onHover { hovering = $0 }
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays the video.")
        .onTapGesture { lightbox?.open(message, reduceMotion: reduceMotion) }
    }
}

/// AppKit's player view. SwiftUI's VideoPlayer crashes on macOS 27 while
/// its type is first set up (in _AVKit_SwiftUI), so it is not used.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // A bar along the bottom, sized to the video, not a fixed panel.
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        view.player = player
    }
}

/// Serves a decrypted video to AVFoundation from memory, so it is never
/// written to disk unencrypted.
final class MemoryAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let data: Data
    private let queue = DispatchQueue(label: "app.nimqo.video")

    init(_ data: Data) {
        self.data = data
        // A made-up scheme, so AVFoundation asks the delegate for the bytes.
        asset = AVURLAsset(url: URL(string: "nimqo-media://video.mp4")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = AVFileType.mp4.rawValue
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let wanted = request.dataRequest {
            let start = Int(wanted.currentOffset)
            let end = wanted.requestsAllDataToEndOfResource
                ? data.count : min(data.count, Int(wanted.requestedOffset) + wanted.requestedLength)
            if start < end {
                // A slice shares the bytes; subdata copied the whole video
                // for every request.
                wanted.respond(with: data[start ..< end])
            }
        }
        request.finishLoading()
        return true
    }
}
