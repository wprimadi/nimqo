import AppKit
import SwiftUI

extension ProfileEditor {
    static let presets: [(text: String, symbol: String)] = [
        ("Available", "checkmark.circle.fill"), ("Busy", "minus.circle.fill"),
        ("At work", "briefcase.fill"), ("In a meeting", "person.3.fill"),
        ("At the gym", "dumbbell.fill"), ("Sleeping", "moon.zzz.fill"),
        ("Urgent calls only", "exclamationmark.bubble.fill"), ("Battery about to die", "battery.25percent"),
    ]

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
}

/// The camera badge on the picture: choose a new one, or remove it.
struct CameraMenu: View {
    let hasPhoto: Bool
    let choose: () -> Void
    let remove: () -> Void

    var body: some View {
        Menu {
            Button("Choose Picture…", systemImage: "photo", action: choose)
            if hasPhoto {
                Divider()
                Button("Remove Picture", systemImage: "trash", role: .destructive, action: remove)
            }
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2.5))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change profile picture")
    }
}

/// What went wrong, over the fields.
struct ProblemBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A labelled field that saves on Return or when it loses focus, with its
/// characters left, and a tick when saved.
struct ProfileField: View {
    let title: LocalizedStringKey
    let symbol: String
    let limit: Int
    @Binding var text: String
    let prompt: LocalizedStringKey
    let footer: LocalizedStringKey?
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
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PresetChip: View {
    let text: String
    let symbol: String
    let chosen: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Label(LocalizedStringKey(text), systemImage: symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(chosen ? AnyShapeStyle(Color.accentColor.gradient)
                    : AnyShapeStyle(.primary.opacity(hovering ? 0.12 : 0.06)), in: .capsule)
                .symbolEffect(.bounce, value: chosen)
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.spring(duration: 0.25, bounce: 0.4), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Under the picture: the name, number and About as people will see
/// them, following what is typed.
struct ProfileCaption: View {
    let name: String
    let phone: String?
    let about: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.title2.bold())
                .lineLimit(1)
                .contentTransition(.interpolate)
            if let phone {
                Text(phone).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if !about.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(about)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .contentTransition(.interpolate)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: name)
        .animation(reduceMotion ? nil : .snappy, value: about)
    }
}
