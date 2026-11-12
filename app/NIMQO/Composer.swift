import NimqoCore
import SwiftUI

/// The message field with attach and send, floating as glass over the
/// timeline; above it, a refusal, the message being replied to, or the one
/// being edited.
struct Composer: View {
    let send: @MainActor (String, Int64?) async -> String?
    let sendFile: @MainActor (URL, String?) async -> String?
    @Binding var replyingTo: ChatMessage?
    @Binding var dropped: [URL]
    @Binding var editing: ChatMessage?
    /// Replaces an own message's text; returns why it was refused.
    var edit: @MainActor (Int64, String) async -> String? = { _, _ in nil }
    /// Up Arrow in an empty field edits this one, as in WhatsApp.
    var lastEditable: ChatMessage?
    /// Sends a recorded voice note; nil where none can be sent.
    var sendVoice: (@MainActor (Data) async -> String?)?
    /// Stickers to pick and send; nil where none can be sent.
    var stickers: StickerPicking?
    /// Sends a new poll; nil where none can be sent.
    var sendPoll: (@MainActor (String, [String], Bool) async -> String?)?
    /// A group's members, to mention with "@"; nil elsewhere.
    var members: (@MainActor () -> [GroupMember])?
    /// Each "@Name" picked, and the number it is sent as.
    @State var mentioned: [String: String] = [:]
    @State var mentionHighlight = 0
    @State var dismissedMention: String?
    @State private var pickingSticker = false
    @State private var recorder = VoiceRecorder()
    @State var text = ""
    /// What was typed before editing began, put back when it ends.
    @State private var stash = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var picking = false
    @State private var refusal: String?
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            // What sits above the field: a refusal, the message replied to.
            if refusal != nil || replyingTo != nil || editing != nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if let refusal {
                        Text(refusal).font(.caption).foregroundStyle(.red)
                    }
                    if let replyingTo {
                        HStack {
                            QuoteView(reply: Reply(
                                kind: replyingTo.kind,
                                body: MessageText.named(replyingTo.body, mentions: replyingTo.mentions),
                                fromMe: replyingTo.fromMe,
                                senderName: replyingTo.contactName ?? replyingTo.senderName,
                                seq: nil
                            ))
                            Spacer()
                            Button("Cancel reply", systemImage: "xmark.circle.fill") { self.replyingTo = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    if let editing {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: "pencil").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Editing").font(.caption.bold()).foregroundStyle(.tint)
                                Text(editing.body ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Cancel editing", systemImage: "xmark.circle.fill") { self.editing = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .keyboardShortcut(.cancelAction)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(in: .rect(cornerRadius: 18))
                // Rises out of the field it belongs to, and sinks back.
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if !suggestions.isEmpty {
                mentionList.transition(.opacity)
            }
            if recorder.state == .recording {
                RecordingBar(recorder: recorder, cancel: recorder.cancel, send: sendRecording)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                field.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: [replyingTo?.seq, editing?.seq])
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: recorder.state)
        .onAppear { focused = true }
        .onChange(of: replyingTo?.seq) {
            if replyingTo != nil {
                editing = nil
            }
            focused = true
        }
        .onChange(of: editing?.seq) { old, new in
            refusal = nil
            if old == nil, new != nil {
                stash = text
            }
            // Its own text to change; the draft comes back when it ends.
            text = editing?.body ?? stash
            if editing == nil {
                stash = ""
            }
            focused = true
        }
        .onChange(of: recorder.state) {
            switch recorder.state {
            case .denied:
                refusal = String(localized: """
                NIMQO may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone.
                """)
            case .failed:
                refusal = String(localized: "The microphone could not be started.")
            case .idle, .recording:
                break
            }
        }
        .onDisappear { recorder.cancel() }
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

    /// Nothing typed and nothing edited: the round button records instead.
    private var recordsVoice: Bool {
        sendVoice != nil && editing == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
            AttachMenu(attach: { picking = true }, sendPoll: sendPoll)
                .disabled(isSending)
            TextField("Message, or a caption for a file", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($focused)
                .onSubmit(submit)
                // Shift-Return starts a new line where the cursor is, as
                // Option-Return already does; Return alone sends.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return mentionKey(.return) }
                    NSApp.sendAction(#selector(NSText.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onKeyPress(keys: [.downArrow, .tab, .escape]) { mentionKey($0.key) }
                .onKeyPress(.upArrow) {
                    if mentionKey(.upArrow) == .handled {
                        return .handled
                    }
                    guard text.isEmpty, editing == nil, let lastEditable else { return .ignored }
                    replyingTo = nil
                    editing = lastEditable
                    return .handled
                }
                .padding(.leading, 14)
                .padding(.vertical, 8)
                .padding(.trailing, stickers == nil ? 34 : 62)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 0) {
                        if stickers != nil {
                            stickerButton
                        }
                        emojiButton
                    }
                }
                .glassSurface(in: .rect(cornerRadius: 18))
            Button(sendTitle, systemImage: sendSymbol, action: primary)
                .contentTransition(.symbolEffect(.replace))
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
                .buttonBorderShape(.circle)
                .glassButton(prominent: true)
                .controlSize(.extraLarge)
                .keyboardShortcut(.return, modifiers: .command)
                .help(recordsVoice ? String(localized: "Record a voice message") : "")
                .disabled(isSending || (!recordsVoice && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
        .glassGroup(spacing: Theme.Spacing.small)
    }

    /// One after another, stopping at the first refusal (the queue limit,
    /// for one), so its reason stays on screen. Text typed beforehand is
    /// the first file's caption.
    private func sendFiles(_ urls: [URL]) {
        refusal = nil
        isSending = true
        // While editing, the field holds the edit, not a caption.
        let draft = editing == nil ? text : ""
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

    /// Stickers from the chats, in a popover above the field.
    private var stickerButton: some View {
        Button("Stickers", systemImage: "face.smiling.inverse") { pickingSticker.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3)
            .foregroundStyle(pickingSticker ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help("Stickers")
            .padding(.trailing, 6)
            .padding(.bottom, 7)
            .popover(isPresented: $pickingSticker, arrowEdge: .top) {
                if let stickers {
                    StickerPicker(picking: stickers) { refused in
                        refusal = refused
                        pickingSticker = false
                        focused = true
                    }
                }
            }
    }

    /// The system's emoji picker, typing into the field (also Fn-E or Control-Command-Space).
    private var emojiButton: some View {
        Button("Emoji", systemImage: "face.smiling") {
            focused = true
            DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.secondary)
        .help("Emoji")
        .padding(.trailing, 10)
        .padding(.bottom, 7)
    }
}

extension Composer {
    private func submit() {
        // Return on an empty field does nothing, like other chat apps.
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let editing {
            return saveEdit(editing)
        }
        refusal = nil
        isSending = true
        let draft = text
        let reply = replyingTo
        Task {
            refusal = await send(withMentions(draft), reply?.seq)
            // Keep the draft when it was refused, so nothing typed is lost.
            if refusal == nil, text == draft {
                text = ""
                mentioned = [:]
                if replyingTo?.seq == reply?.seq {
                    replyingTo = nil
                }
            }
            isSending = false
        }
    }

    private var sendTitle: LocalizedStringKey {
        if editing != nil {
            return "Save Edit"
        }
        return recordsVoice ? "Record Voice Message" : "Send"
    }

    private var sendSymbol: String {
        if editing != nil {
            return "checkmark"
        }
        return recordsVoice ? "mic.fill" : "arrow.up"
    }

    private func primary() {
        if recordsVoice {
            record()
        } else {
            submit()
        }
    }

    private func record() {
        refusal = nil
        Task { await recorder.start() }
    }

    private func sendRecording() {
        guard let pcm = recorder.finish(), let sendVoice else { return }
        isSending = true
        Task {
            refusal = await sendVoice(pcm)
            isSending = false
            focused = true
        }
    }

    /// Unchanged text just ends editing; nothing is sent.
    private func saveEdit(_ message: ChatMessage) {
        let draft = text
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != message.body else {
            editing = nil
            return
        }
        refusal = nil
        isSending = true
        Task {
            refusal = await edit(message.seq, withMentions(draft))
            if refusal == nil, editing?.seq == message.seq {
                editing = nil
            }
            isSending = false
        }
    }
}

/// The quoted message of a reply: who wrote it and what it said.
struct QuoteView: View {
    let reply: Reply

    private var name: String? {
        reply.fromMe == true ? "You" : reply.senderName
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let name {
                    Text(name).font(.caption.bold()).foregroundStyle(.tint)
                }
                Text(ChatMessage.describe(kind: reply.kind, body: reply.body))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Reply to \(name ?? "a message"): \(ChatMessage.describe(kind: reply.kind, body: reply.body))"
        )
    }
}
