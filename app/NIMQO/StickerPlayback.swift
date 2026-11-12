import ImageIO
import Lottie
import SwiftUI

/// An animated sticker plays twice, then rests; a click plays it once
/// more. Looping forever, a chat full of them kept the CPU near 50%.
/// Still under Reduce Motion.
struct StickerAnimation: View {
    let animation: LottieAnimation
    let replays: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView(animation: animation)
            .playbackMode(reduceMotion
                ? .paused(at: .progress(0))
                : .playing(.fromProgress(0, toProgress: 1, loopMode: replays == 0 ? .repeat(2) : .playOnce)))
            .resizable()
            .scaledToFit()
            .frame(width: 160, height: 160)
            // A new view per click: the same mode again would not replay.
            .id(replays)
    }
}

/// An animated WebP (or GIF) sticker, played by ImageIO twice, then once
/// per click, like `StickerAnimation`; `TimelineWindow` removes one far
/// off screen, which stops it.
struct AnimatedImage: View {
    let data: Data
    let replays: Int
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
        .onAppear { play(loops: 2) }
        .onChange(of: replays) { play(loops: 1) }
        .onDisappear { playing?.stopped = true }
    }

    private func play(loops: Int) {
        playing?.stopped = true
        let playing = Playing()
        self.playing = playing
        let options = [kCGImageAnimationLoopCount: loops] as CFDictionary
        CGAnimateImageDataWithBlock(data as CFData, options) { _, image, stop in
            MainActor.assumeIsolated {
                if playing.stopped {
                    stop.pointee = true
                } else {
                    frame = image
                }
            }
        }
    }
}
