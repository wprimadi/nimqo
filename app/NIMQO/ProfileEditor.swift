import AppKit
import NimqoCore
import SwiftUI
import UniformTypeIdentifiers

/// This account as others see it: the picture (drop one on it, or choose
/// one), the name and the About, each saved for every device as it is
/// changed.
struct ProfileEditor: View {
    let core: Core?
    let avatars: AvatarStore
    @State private var profile: MyProfile?
    @State private var failed = false
    @State private var name = ""
    @State private var about = ""
    @State private var photo: NSImage?
    @State private var busy: Field?
    @State private var saved: Field?
    @State private var problem: String?
    @State private var choosing = false
    @State private var dropping = false
    @State private var shown = false
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Field: Hashable {
        case photo, name, about
    }

    private static let presets = [
        "Available", "Busy", "At work", "In a meeting", "At the gym",
        "Sleeping", "Urgent calls only", "Battery about to die",
    ]

    var body: some View {
        VStack(spacing: 18) {
            hero
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if profile != nil {
                VStack(spacing: 12) {
                    nameField
                    aboutField
                }
                .disabled(core == nil)
                .opacity(shown || reduceMotion ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 12)
            } else if failed {
                ContentUnavailableView("Profile unavailable", systemImage: "wifi.slash",
                                       description: Text("It appears once NIMQO is connected to WhatsApp."))
            } else {
                ProgressView().padding()
            }
        }
        .padding(22)
        .frame(width: 420)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: problem)
        .task { await load() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                NSImage(contentsOf: url).map(setPhoto)
            }
        }
    }

    // MARK: Picture

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.accentColor, .pink, .orange, .accentColor], center: .center))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(busy == .photo && !reduceMotion ? 360 : 0))
                    .animation(busy == .photo && !reduceMotion
                        ? .linear(duration: 1.2).repeatForever(autoreverses: false) : .default, value: busy)
                    .blur(radius: dropping ? 6 : 0)
                picture
                    .frame(width: 128, height: 128)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                    .overlay { photoHover }
            }
            .scaleEffect(dropping && !reduceMotion ? 1.06 : 1)
            .shadow(color: .accentColor.opacity(0.35), radius: dropping ? 24 : 14, y: 6)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: dropping)
            .onDrop(of: [.image, .fileURL], isTargeted: $dropping, perform: drop)
            .accessibilityLabel("Profile picture")
            .accessibilityHint("Drop a picture, or use Choose Picture.")
            HStack(spacing: 8) {
                Button("Choose Picture…", systemImage: "photo") { choosing = true }
                if avatars.image(for: profile?.id ?? "") != nil || photo != nil {
                    Button("Remove", systemImage: "trash", role: .destructive) { removePhoto() }
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(core == nil || profile == nil || busy == .photo)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background {
            HeroBackdrop(id: profile?.id ?? "", avatars: avatars)
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let photo {
            Image(nsImage: photo).resizable().scaledToFill()
        } else if let id = profile?.id, let image = avatars.image(for: id) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }

    private var photoHover: some View {
        ZStack {
            Circle().fill(.black.opacity(dropping ? 0.45 : 0))
            if dropping {
                Label("Drop", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else if saved == .photo {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(for: .image) { data, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Task { @MainActor in setPhoto(image) }
        }
        return true
    }

    private func setPhoto(_ image: NSImage) {
        guard let jpeg = Self.squareJPEG(image) else {
            problem = String(localized: "That picture can't be used.")
            return
        }
        photo = NSImage(data: jpeg)
        save(.photo) { try await $0.setMyPhoto(jpeg: jpeg) }
    }

    private func removePhoto() {
        photo = nil
        save(.photo) { try await $0.setMyPhoto(jpeg: nil) }
    }

    /// The middle square, 640 px, as WhatsApp keeps profile pictures.
    static func squareJPEG(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(source.width, source.height)
        let crop = CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        guard let square = source.cropping(to: crop),
              let context = CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: 640, height: 640))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: Name and About

    private var nameField: some View {
        ProfileField(title: "Name", symbol: "person.text.rectangle", limit: 25, text: $name,
                     prompt: "Your name", busy: busy == .name, saved: saved == .name,
                     changed: name.trimmingCharacters(in: .whitespaces) != profile?.name) { saveName() }
            .focused($focus, equals: .name)
    }

    private var aboutField: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProfileField(title: "About", symbol: "quote.opening", limit: 139, text: $about,
                         prompt: "Say something about yourself", busy: busy == .about, saved: saved == .about,
                         changed: about.trimmingCharacters(in: .whitespaces) != (profile?.about ?? "")) { saveAbout() }
                .focused($focus, equals: .about)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.self) { preset in
                        PresetChip(text: preset, chosen: about == preset) {
                            about = preset
                            saveAbout()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }

    private func saveName() {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard text != profile?.name else { return }
        save(.name) { try await $0.setMyName(name: text) }
    }

    private func saveAbout() {
        let text = about.trimmingCharacters(in: .whitespaces)
        guard text != (profile?.about ?? "") else { return }
        save(.about) { try await $0.setMyAbout(text: text) }
    }

    private func save(_ field: Field, _ change: @escaping (Core) async throws -> Void) {
        guard let core else { return }
        problem = nil
        busy = field
        Task {
            do {
                try await change(core)
                switch field {
                case .name: profile?.name = name.trimmingCharacters(in: .whitespaces)
                case .about: profile?.about = about.trimmingCharacters(in: .whitespaces)
                case .photo:
                    if let id = profile?.id {
                        avatars.invalidate([id])
                    }
                }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.5)) { saved = field }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation {
                    if saved == field {
                        saved = nil
                    }
                }
            } catch {
                problem = CoreModel.message(for: error)
                if field == .photo {
                    photo = nil
                }
            }
            busy = nil
        }
    }

    private func load() async {
        guard let core else {
            failed = true
            return
        }
        profile = await core.myProfile()
        failed = profile == nil
        name = profile?.name ?? ""
        about = profile?.about ?? ""
        if let id = profile?.id {
            avatars.request(id)
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.3)) { shown = true }
    }
}

/// A labelled field that saves on Return or when it loses focus, with its
/// characters left, and a tick when saved.
private struct ProfileField: View {
    let title: LocalizedStringKey
    let symbol: String
    let limit: Int
    @Binding var text: String
    let prompt: LocalizedStringKey
    let busy: Bool
    let saved: Bool
    let changed: Bool
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Group {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else if focused || changed {
                        Text("\(limit - text.count)")
                            .monospacedDigit()
                            .foregroundStyle(text.count > limit ? .red : .secondary)
                            .contentTransition(.numericText())
                    }
                }
                .font(.caption)
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in
                    if !now {
                        commit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.primary.opacity(focused ? 0.08 : 0.05), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
                }
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

private struct PresetChip: View {
    let text: String
    let chosen: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Text(LocalizedStringKey(text))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(chosen ? AnyShapeStyle(Color.accentColor.gradient)
                    : AnyShapeStyle(.primary.opacity(hovering ? 0.12 : 0.06)), in: .capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
