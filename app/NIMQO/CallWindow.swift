import NimqoCore
import SwiftUI

/// The call's own small window: it floats over other apps while it rings,
/// grows when there is video, and closing it hangs up.
struct CallWindow: View {
    static let id = "call"
    let model: CoreModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: CallStore {
        model.calls
    }

    var body: some View {
        Group {
            if let call = store.current {
                CallScreen(call: call, store: store, chat: model.summary(of: call.chat), avatars: model.avatars)
            } else {
                Color.clear
            }
        }
        .background(FloatingWindow(floating: store.current?.phase == .incoming))
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0), value: store.current?.showsVideo)
        .onChange(of: store.current == nil) { _, gone in
            if gone {
                dismissWindow(id: Self.id)
            }
        }
        // The close button and ⌘W hang up, as they do in FaceTime.
        .onDisappear { store.hangUp() }
    }
}

extension CallStore.Call {
    var showsVideo: Bool {
        !isOver && (camera || peerVideo)
    }
}

private struct CallScreen: View {
    let call: CallStore.Call
    let store: CallStore
    let chat: ChatSummary
    let avatars: AvatarStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backdrop
            if call.showsVideo {
                videoLayout.transition(.opacity)
            } else {
                portrait.transition(.opacity)
            }
        }
        .frame(width: call.showsVideo ? 720 : 340, height: call.showsVideo ? 480 : 480)
        .environment(\.colorScheme, .dark)
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            Avatar(chat: chat, store: avatars, size: 480)
                .blur(radius: 60)
                .opacity(0.55)
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var portrait: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 36)
            ZStack {
                if call.phase == .incoming || call.phase == .calling {
                    Pulse(reduceMotion: reduceMotion)
                }
                Avatar(chat: chat, store: avatars, size: 112)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            }
            .frame(height: 170)
            Text(chat.title).font(.title.weight(.semibold)).lineLimit(1).padding(.horizontal, 20)
            CallStatus(call: call)
            if let problem = store.problem {
                Text(problem)
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            Spacer()
            CallControls(call: call, store: store)
                .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
    }

    private var videoLayout: some View {
        ZStack {
            if call.peerVideo {
                RemotePicture(remote: store.remote).transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    Avatar(chat: chat, store: avatars, size: 96)
                    Text(call.camera ? "Your camera is on" : " ").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).font(.headline)
                        CallStatus(call: call).font(.subheadline)
                    }
                    .shadow(radius: 6)
                    Spacer()
                    if call.camera {
                        LayerView(layer: store.preview)
                            .scaleEffect(x: -1, y: 1)
                            .frame(width: 168, height: 126)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.25)))
                            .shadow(radius: 10)
                            .transition(.scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity))
                            .accessibilityLabel("Your camera")
                    }
                }
                .padding(.top, 34)
                .padding(.horizontal, 18)
                Spacer()
                CallControls(call: call, store: store)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.bottom, 22)
            }
            .foregroundStyle(.white)
        }
    }
}

/// "Ringing…", the running time, or why it ended.
private struct CallStatus: View {
    let call: CallStore.Call

    var body: some View {
        Group {
            if call.phase == .connected, let since = call.connectedAt {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(since)),
                         format: .time(pattern: .minuteSecond))
                        .monospacedDigit()
                }
            } else {
                Text(text).contentTransition(.opacity)
            }
        }
        .font(.title3)
        .foregroundStyle(.white.opacity(0.75))
    }

    private var text: LocalizedStringKey {
        switch call.phase {
        case .incoming: call.video ? "WhatsApp video call" : "WhatsApp voice call"
        case .calling: "Calling…"
        case .connecting: "Connecting…"
        case .connected: " "
        case let .ended(reason): Self.ended(reason)
        }
    }

    private static func ended(_ reason: CallEnd) -> LocalizedStringKey {
        switch reason {
        case .local, .remote: "Call ended"
        case .declined: "Declined"
        case .noAnswer: "No answer"
        case .missed: "Missed call"
        case .elsewhere: "Answered on another device"
        case .failed: "Call failed"
        }
    }
}

private struct CallControls: View {
    let call: CallStore.Call
    let store: CallStore

    var body: some View {
        HStack(spacing: 22) {
            if call.isOver {
                EmptyView()
            } else if call.phase == .incoming {
                RoundButton(title: "Decline", symbol: "phone.down.fill", tint: .red) { store.decline() }
                    .keyboardShortcut(.cancelAction)
                if call.video {
                    RoundButton(title: "Voice", symbol: "phone.fill", tint: .green) { store.answer(video: false) }
                }
                RoundButton(title: "Accept", symbol: call.video ? "video.fill" : "phone.fill", tint: .green) {
                    store.answer(video: call.video)
                }
                // No Return shortcut: the ringing window can take focus
                // mid-typing, and a keystroke must never turn on the mic.
            } else {
                if call.peerAsks {
                    VideoAsk(store: store)
                }
                RoundButton(title: call.muted ? "Unmute" : "Mute", symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                            tint: call.muted ? .white : nil, foreground: call.muted ? .black : .white,
                            action: store.toggleMute)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                RoundButton(title: call.camera ? "Camera Off" : "Camera",
                            symbol: call.camera ? "video.fill" : "video.slash.fill",
                            tint: call.camera ? .white : nil, foreground: call.camera ? .black : .white,
                            action: store.toggleCamera)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                RoundButton(title: "End", symbol: "phone.down.fill", tint: .red) { store.hangUp() }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: call.peerAsks)
    }
}

/// The other side wants video; one click turns the camera on.
private struct VideoAsk: View {
    let store: CallStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Switch to video?").font(.callout.weight(.medium))
            Button("Not Now") { store.ignoreVideoAsk() }
            Button("Switch") { store.toggleCamera() }.buttonStyle(.borderedProminent).tint(.green)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: .capsule)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

private struct RoundButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color?
    var foreground: Color = .white
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 56, height: 56)
                    .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white.opacity(0.18)), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(hovered ? 1.06 : 1)
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside } }
        .accessibilityLabel(Text(title))
    }
}

/// Rings spreading out from the picture while it rings.
private struct Pulse: View {
    let reduceMotion: Bool
    @State private var spread = false

    var body: some View {
        ZStack {
            ForEach(0 ..< 2, id: \.self) { ring in
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 2)
                    .frame(width: 112, height: 112)
                    .scaleEffect(spread ? 1.6 : 1)
                    .opacity(spread ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 2).repeatForever(autoreverses: false)
                        .delay(Double(ring)), value: spread)
            }
        }
        .onAppear { spread = !reduceMotion }
        .accessibilityHidden(true)
    }
}

/// The other side's camera, turned upright.
private struct RemotePicture: View {
    let remote: RemoteVideo

    var body: some View {
        GeometryReader { geometry in
            let sideways = remote.turns % 2 == 1
            LayerView(layer: remote.layer)
                .frame(width: sideways ? geometry.size.height : geometry.size.width,
                       height: sideways ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(Double(remote.turns) * 90))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(remote.hasPicture ? 1 : 0)
        }
        .accessibilityLabel("Video")
    }
}

/// Keeps a ringing call above other apps' windows; draggable by its
/// background throughout.
private struct FloatingWindow: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
            view.window?.isMovableByWindowBackground = true
        }
    }
}
