import AppKit
import NimqoCore
import SwiftUI

/// A person: the hero with their picture, name, number and presence, a row
/// of calls and copy, then what they wrote about themselves.
struct ContactCard: View {
    let chat: ChatSummary
    let status: ContactStatus?
    let avatars: AvatarStore
    let calls: CallStore
    @State private var copied = false

    private var canCall: Bool {
        calls.current == nil && calls.core != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            ProfileHero(chat: chat, avatars: avatars, online: status?.online == true) {
                VStack(spacing: 6) {
                    Text(chat.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let phone = chat.phone, phone != chat.title {
                        Text(phone)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let presence = presenceText(status) {
                        HeroChip(text: presence, symbol: status?.online == true ? "circle.fill" : "clock")
                    }
                }
            }
            HStack(spacing: 8) {
                QuickAction(title: "Voice", symbol: "phone.fill") { calls.place(chat.id, video: false) }
                    .disabled(!canCall)
                QuickAction(title: "Video", symbol: "video.fill") { calls.place(chat.id, video: true) }
                    .disabled(!canCall)
                if let phone = chat.phone {
                    QuickAction(title: copied ? "Copied" : "Copy",
                                symbol: copied ? "checkmark" : "doc.on.doc") { copy(phone) }
                }
            }
            if let about = status?.about {
                InfoSection("About", symbol: "quote.opening") {
                    Text(about)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if chat.timer != nil || chat.muted {
                InfoSection("This chat", symbol: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let timer = chat.timer {
                            Label("Disappearing messages: \(timer)", systemImage: "timer")
                        }
                        if chat.muted {
                            Label("Muted", systemImage: "bell.slash.fill")
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func copy(_ phone: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phone, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
