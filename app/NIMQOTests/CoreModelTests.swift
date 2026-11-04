@testable import NIMQO
import NimqoCore
import Testing

@MainActor
struct CoreModelTests {
    @Test func qrIsClearedOnceNoLongerPairing() {
        let model = CoreModel()
        model.update(state: .pairing)
        model.update(qrPayload: "payload")
        #expect(model.qrPayload == "payload")

        model.update(state: .connected)
        #expect(model.qrPayload == nil)
        #expect(model.state == .connected)
    }

    @Test func mainWindowStaysThroughReconnectsButNotTerminalStates() {
        let model = CoreModel()
        for state in [ConnectionState.connected, .reconnecting, .offline] {
            model.update(state: state)
            #expect(model.isSessionUp, "\(state)")
        }
        for state in [ConnectionState.loggedOut, .streamReplaced, .clientOutdated, .notPaired] {
            model.update(state: state)
            #expect(!model.isSessionUp, "\(state)")
        }
    }

    @Test func banShowsHowLongItLasts() {
        let model = CoreModel()
        model.update(state: .temporaryBan(expiresInSecs: 3600))
        #expect(model.statusText.contains("1 hour"))
    }

    @Test func storageFailureSaysItFailsClosed() {
        let message = CoreModel.message(for: CoreError.Storage(detail: "x"))
        #expect(message.contains("will not continue"))
    }

    @Test func startDoesNothingUnderTests() {
        let model = CoreModel()
        model.start()
        #expect(model.failure == nil && model.state == nil)
    }
}
