import AppKit
import SwiftUI

/// While the connection comes up: the app icon breathing at the centre of
/// ripples, with two arcs circling it. Reduce Motion keeps it still.
struct ConnectingView: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            if reduceMotion {
                emblem(at: 0)
            } else {
                TimelineView(.animation) { context in
                    emblem(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
            VStack(spacing: 6) {
                if reduceMotion {
                    Text(text).font(.title3.weight(.semibold))
                } else {
                    TimelineView(.animation) { context in
                        Shimmer(text: text, time: context.date.timeIntervalSinceReferenceDate)
                    }
                }
                Label("End-to-end encrypted", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func emblem(at time: TimeInterval) -> some View {
        ZStack {
            Ripples(time: time)
            // Two arcs, turning against each other.
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(AngularGradient(colors: [.accentColor.opacity(0), .accentColor], center: .center,
                                        startAngle: .zero, endAngle: .degrees(108)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 128, height: 128)
                .rotationEffect(.degrees(time * 160))
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 112, height: 112)
                .rotationEffect(.degrees(-time * 110))
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .scaleEffect(1 + 0.035 * sin(time * 2.2))
                .shadow(color: .accentColor.opacity(0.35 + 0.15 * sin(time * 2.2)), radius: 18)
        }
        .frame(width: 260, height: 260)
    }
}

/// Rings rising from the icon and fading as they spread.
private struct Ripples: View {
    let time: TimeInterval
    private let count = 3
    private let period = 2.6

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for ring in 0 ..< count {
                let phase = (time / period + Double(ring) / Double(count)).truncatingRemainder(dividingBy: 1)
                let radius = 46 + phase * (size.width / 2 - 46)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Circle().path(in: rect), with: .color(.accentColor.opacity((1 - phase) * 0.45)),
                               lineWidth: 1.5 + (1 - phase) * 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The status, with a band of light passing across it.
private struct Shimmer: View {
    let text: String
    let time: TimeInterval

    var body: some View {
        let band = (time / 1.8).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .overlay {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: band - 0.25),
                            .init(color: .black, location: band),
                            .init(color: .clear, location: band + 0.25),
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
    }
}
