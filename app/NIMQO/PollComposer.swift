import NimqoCore
import SwiftUI

/// A new poll, from the composer's + menu: a question, 2 to 12 options
/// (a fresh one appears as the last is filled), one answer or many.
struct PollComposer: View {
    /// Sends it; returns why it was refused.
    let send: @MainActor (String, [String], Bool) async -> String?
    let done: () -> Void
    @State private var question = ""
    @State private var options = [Option(), Option()]
    @State private var multiple = false
    @State private var refusal: String?
    @State private var isSending = false
    @FocusState private var focus: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let questionField = UUID()
    private static let maxOptions = 12

    struct Option: Identifiable {
        let id = UUID()
        var text = ""
    }

    private var filled: [String] {
        options.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty && filled.count >= 2
            && Set(filled).count == filled.count && !isSending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New Poll", systemImage: "chart.bar.xaxis")
                .font(.headline)
                .foregroundStyle(.tint)
            TextField("Ask a question", text: $question, axis: .vertical)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(1 ... 3)
                .focused($focus, equals: Self.questionField)
            Divider()
            VStack(spacing: 6) {
                ForEach($options) { option in
                    row(option)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: options.map(\.id))
            Toggle("Allow multiple answers", isOn: $multiple)
                .toggleStyle(.switch)
                .controlSize(.small)
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(duplicate ? "Each option must be different." : "\(filled.count) of \(Self.maxOptions) options")
                    .font(.caption)
                    .foregroundStyle(duplicate ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Send Poll", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { focus = Self.questionField }
    }

    private var duplicate: Bool {
        Set(filled).count != filled.count
    }

    private func row(_ option: Binding<Option>) -> some View {
        let index = options.firstIndex { $0.id == option.wrappedValue.id } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: multiple ? "square" : "circle")
                .foregroundStyle(.tertiary)
                .contentTransition(.symbolEffect(.replace))
            TextField("Option \(index + 1)", text: option.text)
                .textFieldStyle(.plain)
                .focused($focus, equals: option.wrappedValue.id)
                .onSubmit { focus = options.dropFirst(index + 1).first?.id }
                .onChange(of: option.wrappedValue.text) { grow() }
            if options.count > 2, !option.wrappedValue.text.isEmpty {
                Button("Remove", systemImage: "minus.circle.fill") {
                    options.removeAll { $0.id == option.wrappedValue.id }
                    grow()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 9, style: .continuous))
    }

    /// One empty option at the end while there is room; no more than one.
    private func grow() {
        while options.count > 2, options.suffix(2).allSatisfy(\.text.isEmpty) {
            options.removeLast()
        }
        if options.last?.text.isEmpty == false, options.count < Self.maxOptions {
            options.append(Option())
        }
    }

    private func submit() {
        guard canSend else { return }
        isSending = true
        refusal = nil
        Task {
            if let why = await send(question, filled, multiple) {
                refusal = why
                isSending = false
            } else {
                done()
            }
        }
    }
}

/// The composer's +: a photo or file, or a poll, which opens from it.
struct AttachMenu: View {
    let attach: () -> Void
    let sendPoll: (@MainActor (String, [String], Bool) async -> String?)?
    @State private var makingPoll = false

    var body: some View {
        Menu {
            Button("Photo or File…", systemImage: "paperclip", action: attach)
            if sendPoll != nil {
                Button("Poll…", systemImage: "chart.bar.xaxis") { makingPoll = true }
            }
        } label: {
            Label("Attach", systemImage: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .glassButton()
        .controlSize(.extraLarge)
        .fixedSize()
        .popover(isPresented: $makingPoll, arrowEdge: .top) {
            if let sendPoll {
                PollComposer(send: sendPoll) { makingPoll = false }
            }
        }
    }
}

extension CoreModel {
    /// Sends a new poll to `chat`; returns why it was refused.
    func sendPoll(_ question: String, options: [String], multiple: Bool, to chat: String) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached {
            Result { try core.sendPoll(chatId: chat, question: question, options: options, multiple: multiple) }
        }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }
}
