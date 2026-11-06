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
            if waiting {
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
    @State private var open = false

    var body: some View {
        Group {
            if let still = store.image(chat: chat, message: message) {
                Image(nsImage: still.image).resizable().scaledToFit()
            } else {
                Color.secondary.opacity(0.2).frame(width: 200, height: 120)
            }
        }
        .frame(maxWidth: 280, maxHeight: 320)
        .overlay {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white, .black.opacity(0.4))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays the video.")
        .onTapGesture { open = true }
        .sheet(isPresented: $open) {
            VideoViewer(chat: chat, message: message, store: store)
        }
    }
}

struct VideoViewer: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var player: AVPlayer?
    @State private var source: MemoryAsset?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let player {
                VideoPlayer(player: player)
                    .frame(minWidth: 480, idealWidth: 720, minHeight: 300, idealHeight: 480)
            } else {
                ProgressView("Downloading the video…")
                    .frame(minWidth: 480, minHeight: 300)
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
        .task(id: store.generation) {
            guard player == nil else { return }
            guard let data = store.media(chat: chat, message: message) else {
                store.download(chat: chat, message: message)
                return
            }
            let asset = MemoryAsset(data)
            source = asset
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset.asset))
            player?.play()
        }
        .onDisappear { player?.pause() }
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
                wanted.respond(with: data.subdata(in: start ..< end))
            }
        }
        request.finishLoading()
        return true
    }
}
