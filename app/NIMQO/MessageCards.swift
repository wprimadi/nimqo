import AppKit
import NimqoCore
import SwiftUI

extension ChatMessage {
    /// Drawn as a card (`MessageCardView`), not as text.
    var isCard: Bool {
        [.poll, .location, .contact, .buttons].contains(kind)
    }
}

/// Opens a chat, starting one when it has no messages yet.
struct OpenChatAction {
    let open: @MainActor (ChatSummary) -> Void

    @MainActor
    func callAsFunction(_ chat: ChatSummary) {
        open(chat)
    }
}

extension EnvironmentValues {
    @Entry var openChat: OpenChatAction?
}

/// A poll, a place, contacts or buttons, loaded from the core; the message's line
/// of text stands in until then.
struct MessageCardView: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var card: MessageCard?
    @State private var loaded = false

    var body: some View {
        Group {
            switch card {
            case let .poll(poll):
                PollCardView(chat: chat, seq: message.seq, poll: poll, core: store.core, reload: load)
            case let .place(place): PlaceCardView(place: place)
            case let .people(people): PeopleCardView(people: people)
            case let .buttons(buttons): ButtonsCardView(chat: chat, seq: message.seq, card: buttons, core: store.core)
            case nil:
                Text(message.body ?? "")
                    .italic()
                    .redacted(reason: loaded ? [] : .placeholder)
            }
        }
        .task(id: message.revision) { await load() }
    }

    private func load() async {
        card = await store.core?.messageCard(chatId: chat, seq: message.seq)
        loaded = true
    }
}

// MARK: Poll

private struct PollCardView: View {
    let chat: String
    let seq: Int64
    let poll: PollCard
    let core: Core?
    let reload: () async -> Void
    /// Picked here, shown at once while the vote goes out.
    @State private var picked: Set<String>?
    @State private var problem: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mine: Set<String> {
        picked ?? Set(poll.choices.filter(\.mine).map(\.name))
    }

    private static let badge = LinearGradient(colors: [.teal, .accentColor], startPoint: .topLeading,
                                              endPoint: .bottomTrailing)

    private var most: UInt32 {
        max(poll.choices.map(\.votes).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Self.badge, in: .rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(poll.question).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(poll.multiple ? "Select one or more" : "Select one")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                ForEach(poll.choices, id: \.name) { choice in
                    PollChoiceRow(choice: choice, chosen: mine.contains(choice.name), multiple: poll.multiple,
                                  share: Double(choice.votes) / Double(most), enabled: poll.open && core != nil,
                                  pick: { toggle(choice.name) })
                }
            }
            HStack {
                Text(poll.voters == 1 ? "1 vote" : "\(poll.voters) votes")
                    .contentTransition(.numericText())
                if !poll.open {
                    Text("· Votes can't be read here").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(width: 280, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.25), value: poll)
    }

    private func toggle(_ name: String) {
        guard let core else { return }
        var next = mine
        if next.contains(name) {
            next.remove(name)
        } else {
            if !poll.multiple {
                next.removeAll()
            }
            next.insert(name)
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4)) { picked = next }
        problem = nil
        let choices = poll.choices.map(\.name).filter(next.contains)
        Task {
            do {
                try await core.voteInPoll(chatId: chat, seq: seq, choices: choices)
                await reload()
            } catch {
                problem = CoreModel.message(for: error)
            }
            picked = nil
        }
    }
}

private struct PollChoiceRow: View {
    let choice: PollChoice
    let chosen: Bool
    let multiple: Bool
    /// Of the most voted choice, 0 to 1.
    let share: Double
    let enabled: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: mark)
                    .font(.system(size: 16))
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: chosen)
                Text(choice.name).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text("\(choice.votes)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(alignment: .leading) {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(bar)
                        .frame(width: max(0, geometry.size.width * share))
                }
            }
            .background(.primary.opacity(hovering && enabled ? 0.07 : 0.04),
                        in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(choice.name), \(choice.votes) votes")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var bar: AnyShapeStyle {
        chosen ? AnyShapeStyle(Color.accentColor.opacity(0.28)) : AnyShapeStyle(.primary.opacity(0.08))
    }

    private var mark: String {
        if multiple {
            return chosen ? "checkmark.square.fill" : "square"
        }
        return chosen ? "checkmark.circle.fill" : "circle"
    }
}

// MARK: Place

/// The sender's map picture (nothing is fetched to draw it), the place's
/// name, and Open in Maps.
private struct PlaceCardView: View {
    let place: PlaceCard
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let data = place.thumbnail, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        MapSketch()
                    }
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white, .red)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .offset(y: hovering ? -6 : 0)
                }
                .frame(width: 260, height: 140)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if place.live {
                        LiveBadge().padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name ?? (place.live ? "Live location" : "Location")).font(.callout.weight(.semibold))
                    Text(place.address ?? coordinates)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Label("Open in Maps", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.medium)).foregroundStyle(.tint).padding(.top, 4)
                }
                .padding(10)
            }
            .frame(width: 260, alignment: .leading)
            .background(.primary.opacity(0.05))
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(.spring(duration: 0.3, bounce: 0.4)) { hovering = over } }
        .help("Open in Maps")
        .contextMenu {
            Button("Copy Coordinates", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(coordinates, forType: .string)
            }
        }
    }

    private var coordinates: String {
        String(format: "%.5f, %.5f", place.latitude, place.longitude)
    }

    private func open() {
        var url = URLComponents(string: "maps://")
        url?.queryItems = [URLQueryItem(name: "ll", value: "\(place.latitude),\(place.longitude)"),
                           URLQueryItem(name: "q", value: place.name ?? coordinates)]
        if let link = url?.url {
            NSWorkspace.shared.open(link)
        }
    }
}

/// Streets drawn from nothing, for a place sent without a picture.
private struct MapSketch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.green.opacity(0.12)))
            var roads = Path()
            for step in stride(from: -size.height, to: size.width, by: 38) {
                roads.move(to: CGPoint(x: step, y: size.height))
                roads.addLine(to: CGPoint(x: step + size.height, y: 0))
            }
            for step in stride(from: 0, to: size.height, by: 30) {
                roads.move(to: CGPoint(x: 0, y: step))
                roads.addLine(to: CGPoint(x: size.width, y: step + 12))
            }
            context.stroke(roads, with: .color(.primary.opacity(0.12)), lineWidth: 3)
        }
        .background(.background)
    }
}

private struct LiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            // A symbol effect pulses in Core Animation: a phaseAnimator
            // re-rendered the window every frame, on or off screen.
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: !reduceMotion)
            Text("LIVE").font(.caption2.weight(.heavy))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .capsule)
    }
}

// MARK: Contacts

private struct PeopleCardView: View {
    let people: [PersonCard]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, person in
                PersonRow(person: person)
            }
            if people.count > 3 {
                Button(expanded ? "Show Fewer" : "Show All \(people.count)") {
                    withAnimation(.spring(duration: 0.35)) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(width: 260, alignment: .leading)
    }

    private var shown: ArraySlice<PersonCard> {
        expanded ? people[...] : people.prefix(3)
    }
}

private struct PersonRow: View {
    let person: PersonCard
    @Environment(\.openChat) private var openChat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(initials)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name.isEmpty ? String(localized: "Contact") : person.name)
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    if let phone = person.phones.first {
                        Text(phone).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 6) {
                // The chat is the vCard's WhatsApp number, which its name and
                // shown number need not match: it opens under that number.
                if let chat = person.chats.first, let openChat {
                    let number = "+" + chat.prefix { $0 != "@" }
                    Button("Message \(number)", systemImage: "message.fill") {
                        openChat(ChatSummary(id: chat, title: number, isGroup: false, phone: number, preview: "",
                                             lastActivity: .now, unread: 0, timer: nil, muted: false))
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Opens the chat with \(number), the WhatsApp number in this card")
                }
                if let phone = person.phones.first {
                    Button("Copy Number", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(phone, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var initials: String {
        let letters = person.name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        let hash = person.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}
