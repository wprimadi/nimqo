import NimqoCore
import SwiftUI

extension ChatSummary {
    /// "typing…", "Ana is typing…", "recording audio…"; nil when quiet.
    static func activityText(_ activity: Activity?) -> String? {
        guard let activity else { return nil }
        return switch (activity.who, activity.recording) {
        case (nil, false): String(localized: "typing…")
        case (nil, true): String(localized: "recording audio…")
        case let (who?, false): String(localized: "\(who) is typing…")
        case let (who?, true): String(localized: "\(who) is recording audio…")
        }
    }
}

/// Three dots rising one after another, like a breath; still under
/// Reduce Motion.
struct TypingDots: View {
    var size: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(phase: -1)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                dots(phase: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// `phase` < 0 draws them at rest.
    private func dots(phase: Double) -> some View {
        HStack(spacing: size * 0.6) {
            ForEach(0 ..< 3) { index in
                let wave = phase < 0 ? 0 : max(0, sin((phase * 2 * .pi / 1.2) - Double(index) * 0.9))
                Circle()
                    .frame(width: size, height: size)
                    .offset(y: -wave * size * 0.7)
                    .opacity(0.45 + wave * 0.55)
            }
        }
        .accessibilityHidden(true)
    }
}

/// In a chat list row, in place of the last message.
struct TypingLabel: View {
    let text: String
    let recording: Bool

    var body: some View {
        HStack(spacing: 5) {
            if recording {
                Image(systemName: "mic.fill").symbolEffect(.pulse)
            } else {
                TypingDots(size: 4)
            }
            Text(text).lineLimit(1)
        }
        .foregroundStyle(.tint)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// At the end of the timeline while the other side is typing: an incoming
/// bubble of dots that grows in from its corner.
struct TypingBubble: View {
    let text: String
    let recording: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if recording {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                } else {
                    TypingDots(size: 7)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// One app, one chat list: one pending re-read.
@MainActor private var activityExpiry: Task<Void, Never>?

extension CoreModel {
    /// Typing ends without a signal when the "paused" one is lost: read
    /// the list again once the core has let it lapse.
    func expireActivity() {
        activityExpiry?.cancel()
        guard chats.contains(where: { $0.activity != nil }) else { return }
        activityExpiry = Task {
            try? await Task.sleep(for: .seconds(16))
            if !Task.isCancelled {
                reloadChats()
            }
        }
    }
}
