import AppKit
import AVFoundation
import Foundation
import ImageIO
import NimqoCore
import UniformTypeIdentifiers

/// Prepares a picked file for sending. Photos are re-encoded as JPEG at most
/// 2560 px on the long side; writing only the pixels drops location and
/// other metadata. Videos are rewritten as MP4 without re-encoding, minus
/// location and other personal metadata. Common audio goes as audio;
/// everything else as a document, unchanged.
enum OutgoingFiles {
    /// Audio WhatsApp plays in the chat, by extension.
    static let audioTypes = [
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "ogg": "audio/ogg", "opus": "audio/ogg",
    ]

    static func prepare(_ url: URL) async throws -> OutgoingFile {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .movie), let video = try await video(url) {
            return video
        }
        let bytes = try Data(contentsOf: url)
        if type.conforms(to: .image), let photo = jpeg(bytes, maxPixels: 2560, quality: 0.8) {
            return OutgoingFile(
                bytes: photo,
                fileName: url.deletingPathExtension().lastPathComponent + ".jpg",
                mimetype: "image/jpeg",
                caption: nil,
                thumbnail: jpeg(bytes, maxPixels: 100, quality: 0.6),
                kind: .photo,
                durationSecs: nil
            )
        }
        if let mimetype = audioTypes[url.pathExtension.lowercased()] {
            return await OutgoingFile(
                bytes: bytes,
                fileName: url.lastPathComponent,
                mimetype: mimetype,
                caption: nil,
                thumbnail: nil,
                kind: .audio,
                durationSecs: seconds(of: AVURLAsset(url: url))
            )
        }
        return OutgoingFile(
            bytes: bytes,
            fileName: url.lastPathComponent,
            mimetype: type.preferredMIMEType ?? "application/octet-stream",
            caption: nil,
            thumbnail: nil,
            kind: .document,
            durationSecs: nil
        )
    }

    /// Nil when it cannot go into MP4 as it is (it is sent as a document).
    /// The copy is written to the temporary folder and removed at once.
    private static func video(_ url: URL) async throws -> OutgoingFile? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        session.metadataItemFilter = .forSharing()
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 100, height: 100)
        let still = try? await generator.image(at: .zero).image
        return try await OutgoingFile(
            bytes: Data(contentsOf: out),
            fileName: url.deletingPathExtension().lastPathComponent + ".mp4",
            mimetype: "video/mp4",
            caption: nil,
            thumbnail: still.flatMap { jpeg($0, quality: 0.6) },
            kind: .video,
            durationSecs: seconds(of: asset)
        )
    }

    private static func seconds(of asset: AVURLAsset) async -> UInt32? {
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration >= 0
        else { return nil }
        return UInt32(duration.rounded())
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
        return jpeg(image, quality: quality)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
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
        let link = await LinkPreviews.make(for: text)
        let result = await Task.detached {
            Result {
                if let link {
                    try core.sendTextWithLink(chatId: chat, text: text, replyTo: replyTo, link: link)
                } else {
                    try core.sendText(chatId: chat, text: text, replyTo: replyTo)
                }
            }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }

    /// Reacts to message `seq` of `chat`; an empty emoji removes it.
    func react(_ emoji: String, to seq: Int64, in chat: String) async {
        guard let core else { return }
        do {
            try await core.react(chatId: chat, seq: seq, emoji: emoji)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Sends a failed message of `chat` again.
    func retry(_ seq: Int64, in chat: String) {
        guard let core else { return }
        Task.detached {
            try? core.retryMessage(chatId: chat, seq: seq)
        }
    }

    /// Sends a recorded voice note (16 kHz mono PCM) to `chat`; the core
    /// encodes it. Returns why it was refused.
    func sendVoice(_ pcm: Data, to chat: String) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached {
            Result { try core.sendVoiceNote(chatId: chat, pcm: pcm) }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }

    /// Sends a sticker picked from those seen; returns why it was refused.
    /// Sends a picked sticker, or a GIF when `gif`, by its upload.
    func sendSticker(_ sticker: StickerRef, gif: Bool, to chat: String) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached {
            Result {
                if gif {
                    try core.sendGif(chatId: chat, fromChat: sticker.chatId, seq: sticker.seq)
                } else {
                    try core.sendSticker(chatId: chat, fromChat: sticker.chatId, seq: sticker.seq)
                }
            }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }

    /// Sends a picked file to `chat`, with `caption` if given. Returns why
    /// it was refused.
    func sendFile(_ url: URL, caption: String?, to chat: String) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached {
            do {
                var file = try await OutgoingFiles.prepare(url)
                file.caption = caption
                try core.sendFile(chatId: chat, file: file)
                return Result<Void, Error>.success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }
}
