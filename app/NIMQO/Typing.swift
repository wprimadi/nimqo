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

/// Three dots that light up one after another; still under Reduce Motion.
/// A symbol effect runs in Core Animation, so it costs nothing per frame
/// here; the TimelineView it replaced re-rendered the whole window 30 times
/// a second for as long as anyone was typing.
struct TypingDots: View {
    var size: CGFloat = 5

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: size * 3, weight: .black))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers)
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
