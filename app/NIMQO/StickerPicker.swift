import AppKit
import NimqoCore
import SwiftUI

/// Where the sticker picker gets its stickers and sends the one picked.
struct StickerPicking {
    let core: Core
    /// Sends it to the open chat, as a GIF when true; returns why it was
    /// refused.
    let send: @MainActor (StickerRef, Bool) async -> String?
}

private enum PickerTab: String, CaseIterable, Identifiable {
    case favorites, recent, gifs

    var id: Self {
        self
    }

    var title: LocalizedStringKey {
        switch self {
        case .favorites: "Favorites"
        case .recent: "Recent"
        case .gifs: "GIFs"
        }
    }

    var symbol: String {
        switch self {
        case .favorites: "star.fill"
        case .recent: "clock.fill"
        case .gifs: "play.square.stack.fill"
        }
    }

    var empty: (title: LocalizedStringKey, detail: LocalizedStringKey) {
        switch self {
        case .favorites: ("No favorites yet", "Stickers you star in WhatsApp on your phone appear here.")
        case .recent: ("No stickers yet", "Stickers sent to you appear here to send on.")
        case .gifs: ("No GIFs yet", "GIFs sent to you appear here to send on.")
        }
    }

    func load(_ core: Core) -> [StickerRef] {
        switch self {
        case .favorites: (try? core.favoriteStickers()) ?? []
        case .recent: (try? core.recentStickers()) ?? []
        case .gifs: (try? core.recentGifs()) ?? []
        }
    }
}

/// Favorite stickers (starred on the phone), the stickers and the GIFs
/// seen in chats, newest first, each once. Click one to send it; it pops
/// as it goes.
struct StickerPicker: View {
    let picking: StickerPicking
    let done: (String?) -> Void
    @AppStorage("stickerTab") private var tab = PickerTab.favorites
    @State private var items: [PickerTab: [StickerRef]] = [:]
    @State private var sending: StickerRef?
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabs
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array((items[tab] ?? []).enumerated()), id: \.element.seq) { index, item in
                        StickerCell(sticker: item, core: picking.core, index: index, gif: tab == .gifs,
                                    sending: sending == item) { pick(item) }
                    }
                }
                .padding(2)
            }
            .id(tab)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .overlay {
                if items[tab] == nil {
                    ProgressView()
                } else if items[tab]?.isEmpty == true {
                    ContentUnavailableView(tab.empty.title, systemImage: tab.symbol,
                                           description: Text(tab.empty.detail))
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: 420)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25), value: tab)
        .task(id: tab) {
            guard items[tab] == nil else { return }
            let (core, shown) = (picking.core, tab)
            items[shown] = await Task.detached { shown.load(core) }.value
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tab == .gifs ? 110 : 72), spacing: 6)]
    }

    /// A pill per tab; the chosen one's background slides between them.
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(PickerTab.allCases) { option in
                Button { tab = option } label: {
                    Label(option.title, systemImage: option.symbol)
                        .font(.callout.weight(tab == option ? .semibold : .regular))
                        .foregroundStyle(tab == option ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .symbolEffect(.bounce, value: tab == option)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if tab == option {
                                Capsule().fill(Color.accentColor.gradient)
                                    .shadow(color: .accentColor.opacity(0.4), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.primary.opacity(0.06), in: .capsule)
    }

    private func pick(_ item: StickerRef) {
        guard sending == nil else { return }
        sending = item
        Task {
            let refusal = await picking.send(item, tab == .gifs)
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
    /// A GIF: its still, wide, marked "GIF".
    var gif = false
    let sending: Bool
    let pick: () -> Void
    @State private var image: NSImage?
    /// A GIF plays while the pointer is over it.
    @State private var loop: GifLoop?
    @State private var hovering = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: pick) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.08 : 0))
                if let image, gif {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if let loop, hovering {
                                LoopView(player: loop.player).allowsHitTesting(false)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            Text("GIF")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: .capsule)
                                .padding(6)
                        }
                } else if let image {
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
            .frame(height: gif ? 80 : 72)
            .scaleEffect(scale)
            .rotationEffect(.degrees(hovering && !reduceMotion && !gif ? -4 : 0))
            .opacity(shown || reduceMotion ? 1 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.5)) { hovering = over }
            if gif, !reduceMotion {
                if over {
                    play()
                } else {
                    loop?.player.pause()
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.6), value: sending)
        .accessibilityLabel(gif ? "GIF" : "Sticker")
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

    /// Fetches the GIF the first time, then plays it while still hovered.
    private func play() {
        if let loop {
            loop.player.play()
            return
        }
        let (chat, seq, core) = (sticker.chatId, sticker.seq, core)
        Task {
            let read = { await Task.detached { (try? core.mediaFile(chatId: chat, seq: seq)) ?? nil }.value }
            var data = await read()
            if data == nil, await core.downloadMedia(chatId: chat, seq: seq) {
                data = await read()
            }
            guard let data, loop == nil else { return }
            let made = GifLoop(data)
            loop = made
            if hovering {
                made.player.play()
            }
        }
    }

    /// The sticker's file, downloading it first when it is not here yet.
    private func load() async {
        let (chat, seq, core) = (sticker.chatId, sticker.seq, core)
        let read = { await Task.detached { (try? core.picture(chatId: chat, seq: seq)) ?? nil }.value }
        let first = await read()
        if let first {
            image = NSImage(data: first.bytes)
        }
        // A GIF shows the still it came with; its video is not fetched to pick it.
        guard !gif, first?.full != true, await core.downloadMedia(chatId: chat, seq: seq) else { return }
        if let full = await read() {
            image = NSImage(data: full.bytes)
        }
    }
}
