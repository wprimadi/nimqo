import NimqoCore
import SwiftUI

/// A new group in two steps: pick people, then name it. Opens the group
/// once WhatsApp has made it.
struct NewGroup: View {
    let core: Core?
    let avatars: AvatarStore
    let back: () -> Void
    let created: (ChatSummary) -> Void
    @State private var picked: [Contact] = []
    @State private var naming = false
    @State private var name = ""
    @State private var problem: String?
    @State private var creating = false
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// WhatsApp's limit for a group's name.
    static let nameLimit = 100

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if naming {
                    details.transition(push(from: .trailing))
                } else {
                    PeoplePicker(core: core, avatars: avatars, picked: $picked)
                        .padding(.horizontal, 18)
                        .transition(push(from: .leading))
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0), value: naming)
        .onChange(of: name) {
            problem = nil
            if name.count > Self.nameLimit {
                name = String(name.prefix(Self.nameLimit))
            }
        }
    }

    private func push(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button("Back", systemImage: "chevron.backward") {
                if naming {
                    naming = false
                } else {
                    back()
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3.weight(.semibold))
            .keyboardShortcut(.cancelAction)
            .disabled(creating)
            VStack(alignment: .leading, spacing: 0) {
                Text(naming ? "Name the Group" : "Add Members").font(.title2.bold())
                    .contentTransition(.opacity)
                Text(naming ? "Step 2 of 2" : "Step 1 of 2").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var details: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "person.3.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Color.green.gradient, in: .circle)
                .shadow(color: .green.opacity(0.35), radius: 14, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .onSubmit(create)
                    .disabled(creating)
                Capsule()
                    .fill(nameFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(height: 2)
                    .animation(.easeOut(duration: 0.2), value: nameFocused)
                Text("\(name.count)/\(Self.nameLimit)")
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 300)
            members
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .onAppear { nameFocused = true }
    }

    private var members: some View {
        VStack(spacing: 8) {
            HStack(spacing: -10) {
                ForEach(picked.prefix(6), id: \.id) { contact in
                    Avatar(chat: contact.summary, store: avatars, size: 34)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
                if picked.count > 6 {
                    Text("+\(picked.count - 6)")
                        .font(.caption.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: .circle)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }
            Text(picked.map(\.name).formatted(.list(type: .and)))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(maxWidth: 320)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(picked.isEmpty ? "Choose at least one person" : "\(picked.count) selected")
                    .font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if creating {
                ProgressView().controlSize(.small)
            }
            if naming {
                Button("Create Group", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || creating)
            } else {
                Button("Next") { naming = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(picked.isEmpty)
                    .help("Next (⌘↩)")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func create() {
        guard let core, !trimmed.isEmpty, !creating else { return }
        creating = true
        problem = nil
        let (subject, ids) = (trimmed, picked.map(\.id))
        Task {
            do {
                let id = try await core.createGroup(subject: subject, members: ids)
                created(ChatSummary(id: id, title: subject, isGroup: true, phone: nil, preview: "",
                                    lastActivity: .now, unread: 0, timer: nil, muted: false))
            } catch {
                problem = CoreModel.message(for: error)
            }
            creating = false
        }
    }
}
