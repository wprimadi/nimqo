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
    @State private var hoveringPhoto = false
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Field: Hashable {
        case photo, name, about
    }

    /// "+62…" from the account's own chat id.
    private var phone: String? {
        guard let id = profile?.id, id.hasSuffix("@s.whatsapp.net") else { return nil }
        return "+" + id.prefix { $0 != "@" && $0 != ":" }
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 16) {
                if let problem {
                    ProblemBanner(text: problem)
                }
                if profile != nil {
                    nameField
                    aboutField
                } else if failed {
                    ContentUnavailableView("Profile unavailable", systemImage: "wifi.slash",
                                           description: Text("It appears once NIMQO is connected to WhatsApp."))
                } else {
                    ProgressView().padding()
                }
            }
            .disabled(core == nil)
            .padding(20)
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
        }
        .frame(width: 460)
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

    /// Edge to edge: the picture in a turning ring over a wash of its own
    /// colours, and the name and About as people will see them, live as
    /// they are typed.
    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                ProfileRing(busy: busy == .photo, glowing: dropping || hoveringPhoto)
                    .frame(width: 112, height: 112)
                picture
                    .frame(width: 104, height: 104)
                    .clipShape(.circle)
                    .overlay { photoHover }
                    .onHover { hoveringPhoto = $0 }
                    .onTapGesture {
                        if core != nil, profile != nil {
                            choosing = true
                        }
                    }
            }
            .overlay(alignment: .bottomTrailing) {
                CameraMenu(hasPhoto: hasPhoto, choose: { choosing = true }, remove: removePhoto)
                    .disabled(core == nil || profile == nil || busy == .photo)
                    .offset(x: -4, y: -4)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .scaleEffect(dropping && !reduceMotion ? 1.06 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: dropping)
            .onDrop(of: [.image, .fileURL], isTargeted: $dropping, perform: drop)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Profile picture")
            .accessibilityHint("Drop a picture, or click to choose one.")
            ProfileCaption(name: shownName, phone: phone, about: about)
        }
        // As on a chat's profile card: a rounded card inset from the edges.
        .padding(.top, 22)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background { HeroBackdrop(id: profile?.id ?? "", avatars: avatars) }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .padding([.top, .horizontal], 16)
    }

    private var shownName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? String(localized: "Your name") : typed
    }

    private var hasPhoto: Bool {
        avatars.image(for: profile?.id ?? "") != nil || photo != nil
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
            Circle().fill(.black.opacity(dropping ? 0.45 : hoveringPhoto && busy != .photo ? 0.35 : 0))
            if dropping {
                Label("Drop", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else if hoveringPhoto, busy != .photo, saved != .photo {
                Label("Change", systemImage: "camera.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .labelStyle(.titleAndIcon)
                    .transition(.opacity)
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

    // MARK: Name and About

    private var nameField: some View {
        ProfileField(title: "Name", symbol: "person.text.rectangle", limit: 25, text: $name,
                     prompt: "Your name", footer: "Shown to people you message who haven't saved your number.",
                     busy: busy == .name, saved: saved == .name,
                     changed: name.trimmingCharacters(in: .whitespaces) != profile?.name) { saveName() }
            .focused($focus, equals: .name)
    }

    private var aboutField: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileField(title: "About", symbol: "quote.opening", limit: 139, text: $about,
                         prompt: "Say something about yourself", footer: nil,
                         busy: busy == .about, saved: saved == .about,
                         changed: about.trimmingCharacters(in: .whitespaces) != (profile?.about ?? "")) { saveAbout() }
                .focused($focus, equals: .about)
            FlowLayout(spacing: 6) {
                ForEach(Self.presets, id: \.text) { preset in
                    PresetChip(text: preset.text, symbol: preset.symbol, chosen: about == preset.text) {
                        about = preset.text
                        saveAbout()
                    }
                }
            }
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
