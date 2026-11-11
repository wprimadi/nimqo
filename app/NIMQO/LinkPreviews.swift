import AppKit
import LinkPresentation
import NimqoCore
import SwiftUI
import UniformTypeIdentifiers

extension MessageBubble {
    struct Badge {
        let name: String
        let tint: Color
        let label: String
    }

    var deliverySymbol: Badge? {
        switch message.delivery {
        case .none: nil
        case .pending: Badge(name: "clock", tint: .secondary, label: "Sending")
        case .sent: Badge(name: "checkmark", tint: .secondary, label: "Sent")
        case .delivered: Badge(name: "checkmark.circle", tint: .secondary, label: "Delivered")
        case .read: Badge(name: "checkmark.circle.fill", tint: .blue, label: "Read")
        case .failed: Badge(name: "exclamationmark.circle.fill", tint: .red, label: "Not sent")
        }
    }
}

/// A sender's preview of the link in their text: picture, title, and the
/// site it goes to, which is the link written in the text (the core keeps
/// no other). Nothing is fetched to show it.
struct LinkPreviewView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var link: LinkPreview?
    @State private var hovering = false

    var body: some View {
        Group {
            if let link, let url = Self.url(link.url) {
                Button { NSWorkspace.shared.open(url) } label: { card(link, host: url.host() ?? link.url) }
                    .buttonStyle(.plain)
                    .help(url.absoluteString)
            }
        }
        .task(id: message.seq) { link = store.core?.linkPreview(chatId: chat, seq: message.seq) }
    }

    private func card(_ link: LinkPreview, host: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let data = link.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(host, systemImage: "link")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tint).lineLimit(1)
                if let title = link.title {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(2)
                }
                if let description = link.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .padding(.leading, 4)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.primary.opacity(hovering ? 0.09 : 0.05), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule().fill(.tint).frame(width: 3).padding(.vertical, 6)
        }
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }

    /// Web links only; a bare "example.com" opens over https.
    static func url(_ written: String) -> URL? {
        let full = written.contains("://") ? written : "https://" + written
        guard let url = URL(string: full), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }
}

/// Settings: make previews for links being sent. It fetches the page from
/// this Mac, which tells the site this Mac's address, so it is off unless
/// turned on.
enum LinkPreviews {
    static let key = "sendsLinkPreviews"

    /// The first web link written in `text` and its preview, or nil when
    /// turned off, there is none, or the page gives nothing within a few
    /// seconds.
    @MainActor
    static func make(for text: String, defaults: UserDefaults = .standard) async -> LinkPreview? {
        guard defaults.bool(forKey: key),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let written = Range(match.range, in: text).map({ String(text[$0]) }),
              let url = LinkPreviewView.url(written)
        else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 5
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let thumbnail = await jpeg(from: metadata.imageProvider)
        guard metadata.title != nil || thumbnail != nil else { return nil }
        return LinkPreview(url: written, title: metadata.title, description: nil, thumbnail: thumbnail)
    }

    /// The page's picture, at most 300 px and 90 KB.
    private static func jpeg(from provider: NSItemProvider?) async -> Data? {
        guard let provider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let data: Data? = await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
        }
        guard let data, let image = NSImage(data: data),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 300 / CGFloat(max(source.width, source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        return jpeg.flatMap { $0.count <= 90 * 1024 ? $0 : nil }
    }
}
