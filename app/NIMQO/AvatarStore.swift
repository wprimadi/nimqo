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
            requested = []
            generation += 1
        }
    }

    /// Bumped when pictures may have changed; views re-read on it. The cache
    /// itself is not observed, so filling it in a view update changes nothing.
    private var generation = 0
    /// nil value: looked up, no picture stored.
    @ObservationIgnored private var images: [String: NSImage?] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func image(for chat: String) -> NSImage? {
        _ = generation
        if let cached = images[chat] {
            return cached
        }
        let data = (try? core?.avatar(chatId: chat)) ?? nil
        let image = data.flatMap(NSImage.init(data:))
        images[chat] = .some(image)
        return image
    }

    /// The row became visible.
    func request(_ chat: String) {
        guard let core, requested.insert(chat).inserted else { return }
        core.requestAvatar(chatId: chat)
    }

    /// The core reported these chats changed; a new picture may be stored.
    func invalidate(_ chats: [String]) {
        for chat in chats {
            images[chat] = nil
        }
        generation += 1
    }
}

struct Avatar: View {
    let chat: ChatSummary
    let store: AvatarStore

    var body: some View {
        Group {
            if let image = store.image(for: chat.id) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear { store.request(chat.id) }
    }
}
