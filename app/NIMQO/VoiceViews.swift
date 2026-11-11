import NimqoCore
import SwiftUI

/// Takes the composer's place while a voice note is recorded: discard,
/// the live waveform and its time, and send. Escape discards, Return sends.
struct RecordingBar: View {
    let recorder: VoiceRecorder
    let cancel: () -> Void
    let send: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
            Button("Discard Voice Message", systemImage: "trash", action: cancel)
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .glassButton()
                .controlSize(.extraLarge)
                .foregroundStyle(.red)
                .keyboardShortcut(.cancelAction)
                .help("Discard (Esc)")
            HStack(spacing: 10) {
                RecordingDot()
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: Int(recorder.elapsed))
                LiveWaveform(levels: recorder.levels)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .glassSurface(in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording a voice message, \(Int(recorder.elapsed)) seconds")
            Button("Send Voice Message", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
                .buttonBorderShape(.circle)
                .glassButton(prominent: true)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .help("Send (Return)")
        }
        .onChange(of: recorder.elapsed >= VoiceRecorder.limit) { _, full in
            if full {
                send()
            }
        }
    }
}

/// Red, breathing, with a ring that spreads from it: on air.
private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            ZStack {
                Circle()
                    .stroke(.red.opacity(reduceMotion ? 0 : 0.6 * (1 - phase)), lineWidth: 2)
                    .scaleEffect(reduceMotion ? 1 : 1 + phase * 1.2)
                Circle()
                    .fill(.red.gradient)
                    .shadow(color: .red.opacity(0.6), radius: 4)
            }
            .frame(width: 10, height: 10)
        }
        .frame(width: 22, height: 22)
    }
}

/// The last few seconds' loudness, flowing in from the right.
private struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            let count = Int(geometry.size.width / 5)
            let shown = Array(levels.suffix(count))
            HStack(alignment: .center, spacing: 2) {
                Spacer(minLength: 0)
                ForEach(Array(shown.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(.tint.opacity(0.35 + 0.65 * Double(index + 1) / Double(max(shown.count, 1))))
                        .frame(width: 3, height: max(3, CGFloat(level) * geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: levels)
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

/// An audio message's bars: what was played in the tint, the rest dim.
/// Click or drag along it to move there.
struct WaveformBars: View {
    let bars: [UInt8]
    /// 0 to 1.
    let progress: Double
    let tint: Color
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let count = bars.count
            let gap: CGFloat = 2
            let width = max(1.5, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(max(count, 1)))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    let played = Double(index) / Double(max(count, 1)) < progress
                    Capsule()
                        .fill(played ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary.opacity(0.45)))
                        .frame(width: width, height: max(3, geometry.size.height * CGFloat(bar) / 100))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                seek(min(max(drag.location.x / geometry.size.width, 0), 1))
            })
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    /// 64 bars from a sender's waveform, or a calm made-up one when it has
    /// none (audio files, older apps), the same each time for the message.
    static func shape(_ waveform: [UInt8], seed: Int64) -> [UInt8] {
        // The core sends at most 64; anything longer is not drawn as is.
        if (8 ... 64).contains(waveform.count) {
            return waveform.map { min($0, 100) }
        }
        var value = UInt64(bitPattern: seed) &+ 0x9E37_79B9_7F4A_7C15
        return (0 ..< 48).map { _ in
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(25 + (value >> 33) % 50)
        }
    }
}
