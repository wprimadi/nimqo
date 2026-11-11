import NimqoCore
import SwiftUI

/// Under the posts of a channel the user runs: text to post to every
/// follower. Return posts; Shift-Return starts a new line.
struct ChannelComposer: View {
    let channel: String
    let store: ChannelStore
    @State private var text = ""
    @State private var posting = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var canPost: Bool {
        !posting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
                TextField("Post to followers", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        post()
                        return .handled
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassSurface(in: .rect(cornerRadius: 18, style: .continuous))
                Button("Post", systemImage: posting ? "ellipsis" : "paperplane.fill", action: post)
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .disabled(!canPost)
                    .help("Posts to everyone who follows this channel")
            }
        }
        .padding(Theme.Spacing.medium)
        .onAppear { focused = true }
    }

    private func post() {
        guard canPost else { return }
        posting = true
        problem = nil
        let sent = text
        Task {
            problem = await store.post(sent, to: channel)
            if problem == nil, text == sent {
                text = ""
            }
            posting = false
        }
    }
}

/// A new channel: its name and what it is about. Made public by WhatsApp
/// once created, so it says so before.
struct NewChannelSheet: View {
    let store: ChannelStore
    @State private var name = ""
    @State private var about = ""
    @State private var creating = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $about, axis: .vertical)
                        .lineLimit(2 ... 5)
                } footer: {
                    Text("Anyone on WhatsApp can find and follow a channel and read what you post.")
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Channel") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 300)
        .windowLook()
    }

    private func create() {
        creating = true
        problem = nil
        Task {
            problem = await store.create(name: name, description: about)
            creating = false
            if problem == nil {
                dismiss()
            }
        }
    }
}
