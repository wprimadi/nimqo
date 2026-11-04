@testable import NIMQO
import NimqoCore
import Testing

@MainActor
struct CoreModelTests {
    @Test func qrIsClearedOnceNoLongerWaitingForScan() {
        let model = CoreModel()
        model.update(status: .waitingForScan)
        model.update(qrPayload: "payload")
        #expect(model.qrPayload == "payload")

        model.update(status: .connected)
        #expect(model.qrPayload == nil)
        #expect(model.status == .connected)
    }

    @Test func storageFailureSaysItFailsClosed() {
        let message = CoreModel.message(for: CoreError.Storage(detail: "x"))
        #expect(message.contains("will not continue"))
    }

    @Test func startDoesNothingUnderTests() {
        let model = CoreModel()
        model.start()
        #expect(model.failure == nil && model.status == nil)
    }
}
