import Foundation
import ImageIO
import NimqoCore
import UniformTypeIdentifiers

/// Prepares a picked file for sending. Photos are re-encoded as JPEG at most
/// 2560 px on the long side; writing only the pixels drops location and
/// other metadata. Everything else goes as a document, unchanged.
enum OutgoingFiles {
    static func prepare(_ url: URL) throws -> OutgoingFile {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let bytes = try Data(contentsOf: url)
        let photo = type.conforms(to: .image) ? jpeg(bytes, maxPixels: 2560, quality: 0.8) : nil
        if let photo {
            return OutgoingFile(
                bytes: photo,
                fileName: url.deletingPathExtension().lastPathComponent + ".jpg",
                mimetype: "image/jpeg",
                caption: nil,
                thumbnail: jpeg(bytes, maxPixels: 100, quality: 0.6),
                asPhoto: true
            )
        }
        return OutgoingFile(
            bytes: bytes,
            fileName: url.lastPathComponent,
            mimetype: type.preferredMIMEType ?? "application/octet-stream",
            caption: nil,
            thumbnail: nil,
            asPhoto: false
        )
    }

    /// Nil when the data is not a readable image.
    static func jpeg(_ data: Data, maxPixels: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the orientation, which is metadata about to be dropped.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

extension CoreModel {
    /// Queues `text` for `chat`, named by the caller so a send started in
    /// one chat never lands in another. Returns the reason it was not
    /// queued, or nil. Storing can wait on a history import, so it runs off
    /// the main thread.
    func send(_ text: String, replyTo: Int64?, to chat: String) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached {
            Result { try core.sendText(chatId: chat, text: text, replyTo: replyTo) }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }

    /// Sends a picked file to `chat`. Returns why it was refused.
    func sendFile(_ url: URL, to chat: String) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached {
            Result { try core.sendFile(chatId: chat, file: OutgoingFiles.prepare(url)) }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }
}
