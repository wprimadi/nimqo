import AppKit
import NimqoCore
import Observation
import SwiftUI

/// Profile pictures for the chat list: decrypted once and cached, fetched by
/// the core only for rows on screen, at most once per chat per session here
/// (the core also skips chats checked in the last day).
@MainActor
@Observable
final class AvatarStore {
    var core: Core? {
        didSet {
            images = [:]
            stored = [:]
            requested = []
            generation += 1
        }
    }

    /// Bumped when pictures may have changed; views re-read on it. The cache
    /// itself is not observed, so filling it in a view update changes nothing.
    private var generation = 0
    /// nil value: looked up, no picture stored.
    @ObservationIgnored private var images: [String: NSImage?] = [:]
    /// The bytes each cached image came from (previews are a few KB).
    @ObservationIgnored private var stored: [String: Data?] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func image(for chat: String) -> NSImage? {
        _ = generation
        if let cached = images[chat] {
            return cached
        }
        let data = (try? core?.avatar(chatId: chat)) ?? nil
        let image = data.flatMap(NSImage.init(data:))
        images[chat] = .some(image)
        stored[chat] = .some(data)
        return image
    }

    /// The row became visible.
    func request(_ chat: String) {
        guard let core, requested.insert(chat).inserted else { return }
        core.requestAvatar(chatId: chat)
    }

    /// The core reported these chats changed; a new picture may be stored.
    /// Most changes are messages, so every avatar is redrawn only when one
    /// of the pictures shown really is different.
    func invalidate(_ chats: [String]) {
        var changed = false
        for chat in chats {
            guard let old = stored[chat] else { continue }
            if ((try? core?.avatar(chatId: chat)) ?? nil) != old {
                images[chat] = nil
                stored[chat] = nil
                changed = true
            }
        }
        if changed {
            generation += 1
        }
    }
}

struct Avatar: View {
    let chat: ChatSummary
    let store: AvatarStore
    var size: CGFloat = 36
    /// Draws the green "online" dot.
    var online = false

    var body: some View {
        Group {
            if let image = store.image(for: chat.id) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if online {
                Circle().fill(.green)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
        .onAppear { store.request(chat.id) }
    }
}
