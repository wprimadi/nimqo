import AppKit
import Network

/// Network, sleep/wake, and App Nap, held only while the core runs.
struct SystemObservers {
    private var monitor: NWPathMonitor?
    private var wakeToken: NSObjectProtocol?
    private var activity: NSObjectProtocol?

    @MainActor
    mutating func start(networkChanged: @escaping @MainActor (Bool) -> Void, didWake: @escaping @MainActor () -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            MainActor.assumeIsolated { networkChanged(available) } // monitor runs on .main
        }
        monitor.start(queue: .main)
        self.monitor = monitor

        // The socket rarely survives sleep; reconnect without waiting for a timeout.
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { didWake() }
        }

        // App Nap would throttle the core's keepalive timers while the window
        // is hidden. Idle system sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the WhatsApp connection alive"
        )
    }

    mutating func stop() {
        monitor?.cancel()
        monitor = nil
        if let wakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeToken)
        }
        wakeToken = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }
}
