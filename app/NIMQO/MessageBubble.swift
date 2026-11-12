import NimqoCore
import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let showsSender: Bool
    let chat: String
    let pictures: PictureStore
    /// Jumps to the quoted message of a reply.
    var openQuote: ((Int64) -> Void)?
    /// Buttons shown on hover; none for read-only posts.
    var actions: MessageActions?
    @State var hovering = false

    private var text: String {
        message.kind == .deleted && message.fromMe
            ? String(localized: "You deleted this message")
            : ChatMessage.describe(kind: message.kind, body: message.body)
    }

    /// Mentions by name, links clickable.
    private var rich: AttributedString {
        MessageText.attributed(text, mentions: message.mentions)
    }

    private var sender: String {
        message.displaySender
    }

    /// A photo or video fills its bubble edge to edge, nearly.
    private var isVisual: Bool {
        message.hasMedia && (message.kind == .image || message.kind == .video)
    }

    /// With no caption, the time sits on the picture, as on the phone.
    private var timeOnPicture: Bool {
        isVisual && message.body == nil
    }

    /// A sticker stands on its own, like in WhatsApp: no bubble.
    private var bubbleStyle: AnyShapeStyle {
        if message.kind == .sticker, message.hasMedia {
            AnyShapeStyle(.clear)
        } else if message.fromMe {
            AnyShapeStyle(.tint.opacity(0.2))
        } else {
            AnyShapeStyle(.quaternary)
        }
    }

    private var time: Date {
        Date(timeIntervalSince1970: TimeInterval(message.timestampSecs))
    }

    private var stamp: some View {
        HStack(spacing: 4) {
            Text(time, format: .dateTime.hour().minute())
            if message.edited {
                Text("Edited")
            }
            if message.starred {
                Image(systemName: "star.fill").accessibilityLabel("Starred")
            }
            if let symbol = deliverySymbol {
                Image(systemName: symbol.name)
                    .foregroundStyle(symbol.tint)
                    .accessibilityLabel(symbol.label)
            }
        }
        .font(.caption2)
    }

    /// The time on a dark chip over the picture's corner.
    @ViewBuilder
    private var pictureStamp: some View {
        if timeOnPicture {
            stamp
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        // Links and mentions are found once per draw, not once per use.
        let rich = rich
        HStack {
            if message.fromMe {
                Spacer(minLength: Theme.Spacing.large)
                hoverBar
            }
            VStack(alignment: .leading, spacing: isVisual ? 4 : 2) {
                Group {
                    if showsSender, !message.fromMe {
                        Text(sender).font(.caption.bold()).foregroundStyle(.tint)
                    }
                    if message.forwarded {
                        Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                    }
                    if let reply = message.reply {
                        if let seq = reply.seq, let openQuote {
                            Button { openQuote(seq) } label: { QuoteView(reply: reply) }
                                .buttonStyle(.plain)
                                .contentShape(.rect)
                                .help("Show the original message")
                        } else {
                            QuoteView(reply: reply)
                        }
                    }
                }
                .padding(.horizontal, isVisual ? 8 : 0)
                .padding(.top, isVisual ? 4 : 0)
                if message.hasMedia {
                    switch message.kind {
                    case .video where message.gif: GifMessageView(chat: chat, message: message, store: pictures)
                        .overlay(alignment: .bottomTrailing) { pictureStamp }
                    case .video: VideoMessageView(chat: chat, message: message, store: pictures)
                        .overlay(alignment: .bottomTrailing) { pictureStamp }
                    case .audio: AudioMessageView(chat: chat, message: message, store: pictures)
                    case .document: DocumentMessageView(chat: chat, message: message, store: pictures)
                    case .image: MessagePictureView(chat: chat, message: message, store: pictures)
                        .overlay(alignment: .bottomTrailing) { pictureStamp }
                    default: MessagePictureView(chat: chat, message: message, store: pictures)
                    }
                }
                // A shown picture needs only its caption; a document shows its own name.
                if message.isCard {
                    MessageCardView(chat: chat, message: message, store: pictures)
                } else if message.kind == .call {
                    CallEntry(message.body).label
                } else if !(message.hasMedia && (message.body == nil || message.kind == .document)) {
                    Text(rich)
                        .italic(message.kind != .text && !message.hasMedia)
                        .textSelection(.enabled)
                        .padding(.horizontal, isVisual ? 8 : 0)
                    if message.hasLink {
                        LinkPreviewView(chat: chat, message: message, store: pictures)
                    }
                }
                if !timeOnPicture {
                    stamp
                        .foregroundStyle(.secondary)
                        .padding([.horizontal, .bottom], isVisual ? 8 : 0)
                }
            }
            .padding(.horizontal, isVisual ? 4 : Theme.Spacing.medium)
            .padding(.vertical, isVisual ? 4 : Theme.Spacing.small)
            .background(bubbleStyle, in: .rect(cornerRadius: isVisual ? 16 : 12, style: .continuous))
            .overlay(alignment: message.fromMe ? .bottomLeading : .bottomTrailing) {
                if let reactions = message.reactions {
                    Text(reactions)
                        .font(.caption)
                        .padding(.horizontal, 4)
                        .background(.background, in: .capsule)
                        .offset(y: 10)
                }
            }
            .padding(.bottom, message.reactions == nil ? 0 : 10)
            if !message.fromMe {
                hoverBar
                Spacer(minLength: Theme.Spacing.large)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(sender), \(String(rich.characters)), \(time.formatted(date: .omitted, time: .shortened))"
                + (message.forwarded ? ", forwarded" : "")
                + (message.edited ? ", edited" : "")
                + (message.starred ? ", starred" : "")
                + (message.reactions.map { ", reactions \($0)" } ?? "")
                + (deliverySymbol.map { ", \($0.label)" } ?? "")
        )
        .accessibilityAction(named: "Show the original message") {
            if let seq = message.reply?.seq {
                openQuote?(seq)
            }
        }
    }
}
