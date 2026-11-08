import NimqoCore
import SwiftUI
import UniformTypeIdentifiers

/// Writes a status update the way it will be seen: a phone-shaped card over
/// a glow of its own colour, words on colour or a photo with a caption, and
/// one bar of tools under it. It goes to the audience set in the phone's
/// status privacy.
struct StatusComposer: View {
    let core: Core?
    @State private var text = ""
    @State private var photo: OutgoingFile?
    @State private var preview: NSImage?
    @State private var colour = StatusPalette.all[0]
    @State private var font = StatusFont.sans
    @State private var picking = false
    @State private var dropping = false
    @State private var posting = false
    @State private var leaving = false
    @State private var problem: String?
    @State private var posts = 0
    @State private var toast = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canPost: Bool {
        core != nil && !posting && text.count <= StatusPalette.maxCharacters && (photo != nil || !trimmed.isEmpty)
    }

    var body: some View {
        GeometryReader { geo in
            let height = min(max(geo.size.height - 200, 320), 640)
            ZStack {
                backdrop
                VStack(spacing: 18) {
                    card
                        .frame(width: height * 9 / 16, height: height)
                        .scaleEffect(leaving && !reduceMotion ? 0.86 : 1)
                        .offset(y: leaving && !reduceMotion ? -36 : 0)
                        .opacity(leaving ? 0 : 1)
                    toolbar
                    note
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if toast {
                    PostedToast(posts: posts)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                Task { await load(url) }
            }
        }
        .onAppear { focused = true }
    }

    // MARK: - Backdrop

    /// The pane glows in the update's colour, or its photo, softly blurred.
    private var backdrop: some View {
        ZStack {
            if let preview, !reduceTransparency {
                Image(nsImage: preview).resizable().scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.4)
                    .opacity(0.6)
                    .transition(.opacity)
            } else {
                RadialGradient(colors: [colour.color.opacity(reduceTransparency ? 0.35 : 0.55), .clear],
                               center: .center, startRadius: 40, endRadius: 520)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: colour)
        .animation(.easeInOut(duration: 0.45), value: preview == nil)
        .accessibilityHidden(true)
    }

    // MARK: - Card

    private var card: some View {
        ZStack {
            if let preview {
                // The whole photo, over a blur of itself, as the phone shows it.
                Image(nsImage: preview).resizable().scaledToFill().blur(radius: 24, opaque: true)
                Image(nsImage: preview).resizable().scaledToFit()
            } else {
                colour.color
                LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: 0) {
                StatusCardHeader(scrim: preview != nil)
                if preview == nil {
                    Spacer(minLength: 0)
                    words
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    caption
                }
            }
            if dropping {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(10)
                    .overlay { Label("Drop to use this photo", systemImage: "photo.badge.plus").font(.headline) }
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.35))
            }
        }
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: (preview == nil ? colour.color : .black).opacity(0.45), radius: 40, y: 22)
        .animation(.easeInOut(duration: 0.3), value: colour)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await load(url) }
            return true
        } isTargeted: { dropping = $0 }
    }

    /// Words on colour, larger the fewer there are.
    private var words: some View {
        TextField("", text: $text, prompt: Text("Type a status").foregroundStyle(.white.opacity(0.55)),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(font.preview(size: StatusPalette.size(for: text)))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .lineLimit(1 ... 12)
            .focused($focused)
            .padding(.horizontal, 26)
            .animation(.snappy(duration: 0.2), value: StatusPalette.size(for: text))
            .accessibilityLabel("Status text")
    }

    /// The caption over the photo's foot, growing upwards as it gets longer.
    private var caption: some View {
        TextField("", text: $text, prompt: Text("Add a caption…").foregroundStyle(.white.opacity(0.6)),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(.white)
            .lineLimit(1 ... 5)
            .focused($focused)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.5), in: .rect(cornerRadius: 16, style: .continuous))
            .padding(14)
            .accessibilityLabel("Caption")
    }

    // MARK: - Tools

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(photo == nil ? "Add Photo" : "Remove Photo",
                   systemImage: photo == nil ? "photo.badge.plus" : "photo.badge.minus", action: togglePhoto)
                .labelStyle(.iconOnly)
                .help(photo == nil ? "Add a photo (or drop one on the card)" : "Back to a text status")
            if photo == nil {
                Divider().frame(height: 22)
                StatusSwatches(colour: $colour)
                Divider().frame(height: 22)
                Button { font = font.next } label: {
                    Text("Aa").font(font.preview(size: 17)).frame(minWidth: 28)
                }
                .help("Font: \(font.name)")
                .accessibilityLabel("Font, \(font.name)")
            }
            CharacterRing(count: text.count)
            Button(action: post) {
                Group {
                    if posting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Post", systemImage: "paperplane.fill")
                    }
                }
                .frame(minWidth: 64)
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canPost)
            .help("Post (⌘↩)")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassSurface(in: .capsule)
        .animation(.snappy(duration: 0.25), value: photo == nil)
    }

    private var note: some View {
        Label(problem ?? "Shared with the audience set in WhatsApp's status privacy on your phone.",
              systemImage: problem == nil ? "person.2.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
    }

    // MARK: - Actions

    private func togglePhoto() {
        if photo == nil {
            picking = true
        } else {
            setPhoto(nil)
        }
    }

    private func setPhoto(_ file: OutgoingFile?) {
        withAnimation(.easeInOut(duration: 0.3)) {
            photo = file
            preview = file.flatMap { NSImage(data: $0.bytes) }
        }
        focused = true
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
        let (text, photo, colour, font) = (text, photo, colour, font)
        Task {
            do {
                try await core.postStatus(text: text, photo: photo, background: colour.rgb, font: font)
                await celebrate()
            } catch let CoreError.SendRefused(reason) {
                problem = reason
            } catch {
                problem = "The status wasn't posted. Try again."
            }
            posting = false
        }
    }

    /// The card lifts away, a fresh one fades in, and a check says it went.
    private func celebrate() async {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0)) { leaving = true }
        try? await Task.sleep(for: .seconds(0.45))
        text = ""
        photo = nil
        preview = nil
        posts += 1
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            leaving = false
            toast = true
        }
        try? await Task.sleep(for: .seconds(1.8))
        withAnimation(.easeOut(duration: 0.3)) { toast = false }
        focused = true
    }
}
