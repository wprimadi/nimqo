import AppKit
import NimqoCore
import SwiftUI

/// Where the sticker picker gets its stickers and sends the one picked.
struct StickerPicking {
    let core: Core
    /// Sends it to the open chat; returns why it was refused.
    let send: @MainActor (StickerRef) async -> String?
}

/// The stickers seen in any chat, newest first, each once. Click one to
/// send it; it pops as it goes.
struct StickerPicker: View {
    let picking: StickerPicking
    let done: (String?) -> Void
    @State private var stickers: [StickerRef]?
    @State private var sending: StickerRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.pink.gradient, in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Stickers").font(.headline)
                    Text("From your chats").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                    ForEach(Array((stickers ?? []).enumerated()), id: \.element.seq) { index, sticker in
                        StickerCell(sticker: sticker, core: picking.core, index: index,
                                    sending: sending == sticker) { pick(sticker) }
                    }
                }
                .padding(2)
            }
            .overlay {
                if stickers == nil {
                    ProgressView()
                } else if stickers?.isEmpty == true {
                    ContentUnavailableView("No stickers yet", systemImage: "face.smiling",
                                           description: Text("Stickers sent to you appear here to send on."))
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 380)
        .task {
            let core = picking.core
            stickers = await Task.detached { (try? core.recentStickers()) ?? [] }.value
        }
    }

    private func pick(_ sticker: StickerRef) {
        guard sending == nil else { return }
        sending = sticker
        Task {
            let refusal = await picking.send(sticker)
            // Long enough for the pop to be seen.
            try? await Task.sleep(for: .milliseconds(220))
            done(refusal)
        }
    }
}

private struct StickerCell: View {
    let sticker: StickerRef
    let core: Core
    let index: Int
    let sending: Bool
    let pick: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: pick) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.08 : 0))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 6, y: 3)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.06))
                        .padding(10)
                }
            }
            .frame(height: 72)
            .scaleEffect(scale)
            .rotationEffect(.degrees(hovering && !reduceMotion ? -4 : 0))
            .opacity(shown || reduceMotion ? 1 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.5)) { hovering = over }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.6), value: sending)
        .accessibilityLabel("Sticker")
        .task { await load() }
        .onAppear {
            // Cascades in, row by row.
            let cascade = Animation.spring(duration: 0.45, bounce: 0.4).delay(Double(min(index, 24)) * 0.02)
            withAnimation(reduceMotion ? nil : cascade) {
                shown = true
            }
        }
    }

    private var scale: CGFloat {
        if reduceMotion {
            return 1
        }
        if sending {
            return 1.35
        }
        if !shown {
            return 0.4
        }
        return hovering ? 1.12 : 1
    }

    /// The sticker's file, downloading it first when it is not here yet.
    private func load() async {
        let (chat, seq, core) = (sticker.chatId, sticker.seq, core)
        let read = { await Task.detached { (try? core.picture(chatId: chat, seq: seq)) ?? nil }.value }
        let first = await read()
        if let first {
            image = NSImage(data: first.bytes)
        }
        guard first?.full != true, await core.downloadMedia(chatId: chat, seq: seq) else { return }
        if let full = await read() {
            image = NSImage(data: full.bytes)
        }
    }
}
