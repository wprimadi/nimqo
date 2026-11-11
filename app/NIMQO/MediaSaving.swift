import AppKit
import NimqoCore
import SwiftUI

/// Saving a message's photo, video, or document to a folder the person
/// chooses, downloading it first when it is not here yet.
extension PictureStore {
    func isSaving(chat: String, message: ChatMessage) -> Bool {
        saving.contains(Self.key(chat, message))
    }

    func save(chat: String, message: ChatMessage) {
        if let data = media(chat: chat, message: message) {
            Self.write(data, as: message.fileName(for: data))
            return
        }
        let key = Self.key(chat, message)
        pendingSaves[key] = (chat, message)
        saving.insert(key)
        if didFail(chat: chat, message: message) {
            retry(chat: chat, message: message)
        } else {
            download(chat: chat, message: message)
        }
    }

    /// Quick Look, which also shares it: a private copy of the file,
    /// downloading it first when it is not here yet.
    func preview(chat: String, message: ChatMessage) {
        if let data = media(chat: chat, message: message) {
            show(data, as: message.fileName(for: data))
            return
        }
        pendingPreviews.insert(Self.key(chat, message))
        save(chat: chat, message: message)
    }

    /// A download finished: ask where to save what was waiting for it.
    func finishSaves() {
        for (key, item) in pendingSaves {
            guard let data = media(chat: item.chat, message: item.message) else { continue }
            pendingSaves[key] = nil
            saving.remove(key)
            let previews = pendingPreviews.remove(key) != nil
            // Next turn: not inside the change that reported the download.
            Task { @MainActor in
                if previews {
                    show(data, as: item.message.fileName(for: data))
                } else {
                    Self.write(data, as: item.message.fileName(for: data))
                }
            }
        }
    }

    /// In a folder of its own in this user's temporary folder, marked as
    /// downloaded like a saved file; gone once Quick Look closes, and at
    /// the next launch if NIMQO quits first.
    private func show(_ data: Data, as name: String) {
        do {
            previewing = try Self.privateCopy(data, as: name)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// A copy in a folder of its own under `previews`, marked as downloaded;
    /// remove its folder when done with it.
    static func privateCopy(_ data: Data, as name: String) throws -> URL {
        let folder = previews.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                kLSQuarantineAgentNameKey as String: "NIMQO",
            ]
            var marked = file
            try marked.setResourceValues(values)
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static let previews = FileManager.default.temporaryDirectory.appending(path: "NIMQO Previews")

    /// Left by a session that ended with Quick Look open.
    static func removeLeftPreviews() {
        try? FileManager.default.removeItem(at: previews)
    }

    private static func write(_ data: Data, as name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            // Marked as downloaded, so macOS checks it before it is opened.
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                kLSQuarantineAgentNameKey as String: "NIMQO",
            ]
            var marked = url
            do {
                try marked.setResourceValues(values)
            } catch {
                // Unmarked, it could be opened unchecked: keep nothing.
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension ChatMessage {
    var canSave: Bool {
        hasMedia && [.image, .video, .document].contains(kind)
    }

    /// The sender's file name, reduced to a plain name: no folders, and no
    /// invisible characters (a right-to-left mark can show "fdp.exe" as
    /// "exe.pdf").
    var documentName: String {
        let visible = (body ?? "").unicodeScalars.filter {
            ![.control, .format].contains($0.properties.generalCategory)
        }
        let last = (String(String.UnicodeScalarView(visible)) as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return last.isEmpty ? "Document" : last
    }

    /// A document keeps its name; a photo or video is named by its time,
    /// with the extension its bytes say.
    func fileName(for data: Data) -> String {
        if kind == .document {
            return documentName
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let time = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestampSecs)))
        let ext = if kind == .video {
            "mp4"
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            "png"
        } else if data.count > 12, data[8 ..< 12].elementsEqual("WEBP".utf8) {
            "webp"
        } else {
            "jpg"
        }
        return "NIMQO \(kind == .video ? "Video" : "Photo") \(time).\(ext)"
    }
}

/// A document: a coloured tile for its type, its name, and a button that
/// saves it. It is never opened from here, since a sender picks the file
/// and its name.
struct DocumentMessageView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String {
        message.documentName
    }

    private var ext: String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.count <= 5 ? ext : ""
    }

    var body: some View {
        let saving = store.isSaving(chat: chat, message: message)
        VStack(alignment: .trailing, spacing: 6) {
            Button { store.save(chat: chat, message: message) } label: {
                HStack(spacing: 12) {
                    FileTile(ext: ext)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                        Text(ext.isEmpty ? "Document" : "\(ext.uppercased()) document")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ZStack {
                        Circle().fill(.tint.opacity(hovering ? 0.28 : 0.16))
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.tint)
                                .offset(y: hovering && !reduceMotion ? 1.5 : 0)
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .padding(10)
                .frame(minWidth: 240, maxWidth: 300, alignment: .leading)
                .background(.background.opacity(hovering ? 0.7 : 0.45),
                            in: .rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                }
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.25, bounce: 0), value: hovering)
            .help("Download and save to a folder you choose")
            .accessibilityLabel("Document, \(name)")
            .accessibilityHint("Downloads it and asks where to save it.")
            if store.didFail(chat: chat, message: message) {
                RetryDownload(chat: chat, message: message, store: store)
            }
        }
    }
}

/// The type of a file at a glance: its extension on a colour that groups
/// it (PDF red, text blue, sheets green, slides orange, archives brown).
private struct FileTile: View {
    let ext: String

    private var colour: Color {
        switch ext {
        case "pdf": .red
        case "doc", "docx", "pages", "rtf", "txt", "odt", "md": .blue
        case "xls", "xlsx", "csv", "numbers", "ods": .green
        case "ppt", "pptx", "key", "odp": .orange
        case "zip", "rar", "7z", "gz", "tar": .brown
        default: .gray
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(colour.gradient)
            .frame(width: 38, height: 46)
            .overlay(alignment: .topTrailing) {
                // The folded corner of a page.
                Triangle().fill(.white.opacity(0.35)).frame(width: 11, height: 11)
            }
            .overlay(alignment: .bottom) {
                Text(ext.isEmpty ? "FILE" : ext.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding([.horizontal, .bottom], 4)
            }
            .shadow(color: colour.opacity(0.35), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
