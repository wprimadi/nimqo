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

/// A voice note or audio file: play and pause, the sender's waveform
/// filling as it plays (click or drag along it to move), and its speed.
/// Downloaded on the first tap; WhatsApp's Ogg Opus plays through
/// AVAudioPlayer.
struct AudioMessageView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var playback = AudioPlayback()
    @State private var waiting = false
    @State private var info: AudioInfo?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        info?.voice == false ? .orange : .accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            playButton
            VStack(alignment: .leading, spacing: 3) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying)) { _ in
                    WaveformBars(bars: WaveformBars.shape([UInt8](info?.waveform ?? Data()), seed: message.seq),
                                 progress: playback.progress, tint: tint,
                                 active: playback.isPlaying || playback.progress > 0, seek: seek)
                }
                HStack(spacing: 6) {
                    if store.didFail(chat: chat, message: message) {
                        RetryDownload(chat: chat, message: message, store: store)
                    } else {
                        TimelineView(.animation(minimumInterval: 0.25, paused: !playback.isPlaying)) { _ in
                            Text(Duration.seconds(shownTime), format: .time(pattern: .minuteSecond))
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    if playback.isPlaying || playback.rate != 1 {
                        speedButton.transition(.scale.combined(with: .opacity))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 200)
        }
        .padding(.vertical, 4)
        .padding(.leading, 4)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.3), value: playback.isPlaying)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(info?.voice == false ? "Audio" : "Voice message")
        .accessibilityValue(Duration.seconds(shownTime).formatted(.time(pattern: .minuteSecond)))
        .accessibilityAction(named: playback.isPlaying ? "Pause" : "Play", toggle)
        .task(id: message.seq) { info = try? store.core?.audioInfo(chatId: chat, seq: message.seq) }
        // A finished download arrives as a chat change.
        .onChange(of: store.generation) {
            if waiting {
                toggle()
            }
        }
        .onDisappear { playback.stop() }
    }

    /// The time left while it plays, else the whole length.
    private var shownTime: TimeInterval {
        let length = playback.duration ?? TimeInterval(info?.seconds ?? 0)
        return playback.isPlaying || playback.progress > 0 ? max(0, length - playback.currentTime) : length
    }

    private var playButton: some View {
        Button(action: toggle) {
            ZStack {
                Circle().fill(tint.gradient)
                if waiting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: playback.isPlaying ? 0 : 1.5)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 38, height: 38)
            .shadow(color: tint.opacity(playback.isPlaying ? 0.55 : 0.25), radius: playback.isPlaying ? 8 : 3)
            // How far it has played, around the button.
            .overlay {
                if playback.isLoaded {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying)) { _ in
                        Circle()
                            .trim(from: 0, to: playback.progress)
                            .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(-4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if info?.voice == true, !message.fromMe {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(3)
                        .background(.background, in: .circle)
                        .offset(x: 3, y: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(playback.isPlaying ? "Pause" : "Play")
    }

    private var speedButton: some View {
        Button {
            playback.rate = playback.rate >= 2 ? 1 : playback.rate + 0.5
        } label: {
            Text(playback.rate == 1.5 ? "1.5×" : "\(Int(playback.rate))×")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.1), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Playback speed")
    }

    private func seek(_ fraction: Double) {
        if playback.isLoaded {
            playback.seek(to: fraction)
        }
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
    /// 1, 1.5 or 2.
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    /// Bumped on a seek or the end: the clocks above stop while paused, so
    /// a paused view redraws on this instead.
    private var moved = 0

    var isLoaded: Bool {
        player != nil
    }

    /// Read on a clock while playing; otherwise on `moved`.
    var currentTime: TimeInterval {
        _ = moved
        return player?.currentTime ?? 0
    }

    var progress: Double {
        _ = moved
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    func load(_ data: Data) {
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        player?.enableRate = true
        player?.rate = rate
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

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = fraction * player.duration
        moved += 1
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            player?.currentTime = 0
            isPlaying = false
            moved += 1
        }
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
