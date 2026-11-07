import NimqoCore
import SwiftUI
import UniformTypeIdentifiers

/// Posts a status update: words on colour, or a photo with a caption.
/// During development the core shows it to the test number only.
struct StatusComposer: View {
    let core: Core?
    @State private var text = ""
    @State private var photo: OutgoingFile?
    @State private var preview: NSImage?
    @State private var picking = false
    @State private var posting = false
    @State private var problem: String?
    @State private var posted = false
    @FocusState private var focused: Bool

    private var canPost: Bool {
        core != nil && !posting && (photo != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            card
            HStack {
                Button(photo == nil ? "Add Photo…" : "Change Photo…", systemImage: "photo") { picking = true }
                if photo != nil {
                    Button("Remove Photo", systemImage: "xmark") { setPhoto(nil) }
                }
                Spacer()
                if posting {
                    ProgressView().controlSize(.small)
                }
                Button("Post", action: post)
                    .keyboardShortcut(.return, modifiers: .command)
                    .glassButton(prominent: true)
                    .disabled(!canPost)
            }
            .frame(maxWidth: 420)
            Text(problem ?? (posted ? "Posted to My Status." : "Only the test number can see it during development."))
                .font(.callout)
                .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                Task { await load(url) }
            }
        }
        .onAppear { focused = true }
    }

    /// The update as it will look: the photo, or the text on the phone's colour.
    private var card: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFill()
            } else {
                Color(red: 0x1E / 255, green: 0x6E / 255, blue: 0x4F / 255)
            }
            VStack {
                if preview != nil {
                    Spacer()
                }
                TextField(preview == nil ? "Type a status" : "Add a caption", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(preview == nil ? .system(size: 26, weight: .semibold) : .body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .lineLimit(preview == nil ? 10 : 3)
                    .focused($focused)
                    .padding(Theme.Spacing.medium)
                    .background(preview == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.black.opacity(0.45)))
            }
        }
        .frame(width: 420, height: 420 * 16 / 11)
        .frame(maxHeight: 560)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }

    private func setPhoto(_ file: OutgoingFile?) {
        photo = file
        preview = file.flatMap { NSImage(data: $0.bytes) }
    }

    private func load(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let file = try? await OutgoingFiles.prepare(url), file.kind == .photo else {
            problem = "That file couldn't be read as a photo."
            return
        }
        problem = nil
        setPhoto(file)
    }

    private func post() {
        guard let core, canPost else { return }
        posting = true
        problem = nil
        posted = false
        let (text, photo) = (text, photo)
        Task {
            do {
                try await core.postStatus(text: text, photo: photo)
                self.text = ""
                setPhoto(nil)
                posted = true
            } catch let CoreError.SendRefused(reason) {
                problem = reason
            } catch {
                problem = "The status wasn't posted. Try again."
            }
            posting = false
        }
    }
}
