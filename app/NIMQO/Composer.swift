import NimqoCore
import SwiftUI

/// The message field with attach and send, floating as glass over the
/// timeline; above it, a refusal or the message being replied to.
struct Composer: View {
    let send: @MainActor (String, Int64?) async -> String?
    let sendFile: @MainActor (URL, String?) async -> String?
    @Binding var replyingTo: ChatMessage?
    @Binding var dropped: [URL]
    @State private var text = ""
    @State private var picking = false
    @State private var refusal: String?
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            // What sits above the field: a refusal, the message replied to.
            if refusal != nil || replyingTo != nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if let refusal {
                        Text(refusal).font(.caption).foregroundStyle(.red)
                    }
                    if let replyingTo {
                        HStack {
                            QuoteView(reply: Reply(
                                kind: replyingTo.kind,
                                body: replyingTo.body,
                                fromMe: replyingTo.fromMe,
                                senderName: replyingTo.contactName ?? replyingTo.senderName
                            ))
                            Spacer()
                            Button("Cancel reply", systemImage: "xmark.circle.fill") { self.replyingTo = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(in: .rect(cornerRadius: 18))
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
                Button("Attach a photo or file", systemImage: "plus") { picking = true }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .glassButton()
                    .controlSize(.extraLarge)
                    .disabled(isSending)
                TextField("Message, or a caption for a file", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: .rect(cornerRadius: 18))
                Button("Send", systemImage: "arrow.up", action: submit)
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
                    .buttonBorderShape(.circle)
                    .glassButton(prominent: true)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .glassGroup(spacing: Theme.Spacing.small)
        }
        .onAppear { focused = true }
        .onChange(of: replyingTo?.seq) { focused = true }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            sendFiles([url])
        }
        .onChange(of: dropped) {
            guard !dropped.isEmpty, !isSending else { return }
            let urls = dropped
            dropped = []
            sendFiles(urls)
        }
        .focusedSceneValue(\.attachFile, $picking)
    }

    /// One after another, stopping at the first refusal (the queue limit,
    /// for one), so its reason stays on screen. Text typed beforehand is
    /// the first file's caption.
    private func sendFiles(_ urls: [URL]) {
        refusal = nil
        isSending = true
        let draft = text
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            for (index, url) in urls.enumerated() {
                // A dropped file is readable only while its access is held.
                let scoped = url.startAccessingSecurityScopedResource()
                refusal = await sendFile(url, index == 0 && !typed.isEmpty ? typed : nil)
                if index == 0, refusal == nil, !typed.isEmpty, text == draft {
                    text = ""
                }
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
                if refusal != nil {
                    break
                }
            }
            isSending = false
            if !dropped.isEmpty {
                let more = dropped
                dropped = []
                sendFiles(more)
            }
        }
    }

    private func submit() {
        // Return on an empty field does nothing, like other chat apps.
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refusal = nil
        isSending = true
        let draft = text
        let reply = replyingTo
        Task {
            refusal = await send(draft, reply?.seq)
            // Keep the draft when it was refused, so nothing typed is lost.
            if refusal == nil, text == draft {
                text = ""
                if replyingTo?.seq == reply?.seq {
                    replyingTo = nil
                }
            }
            isSending = false
        }
    }
}
