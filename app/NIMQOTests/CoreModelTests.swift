import Foundation
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

    @Test func disclosureIsRememberedAndGatesStart() throws {
        let defaults = try #require(UserDefaults(suiteName: "nimqo.tests.\(UUID())"))
        let model = CoreModel(defaults: defaults)
        #expect(!model.hasAcceptedDisclosure)
        model.acceptDisclosure()
        #expect(CoreModel(defaults: defaults).hasAcceptedDisclosure)
    }

    @Test func pairCodeIsGroupedAndClearedAfterPairing() {
        let model = CoreModel()
        model.update(state: .pairing)
        model.update(pairCode: "ABCDEFGH")
        #expect(model.pairCode == "ABCD-EFGH")
        model.update(state: .connected)
        #expect(model.pairCode == nil)
    }

    @Test func throttledPairCodeSaysWhenToRetry() {
        let model = CoreModel()
        model.pairCodeFailed(throttled: true, retryAfterSecs: 120)
        #expect(model.pairCodeMessage?.contains("2 minutes") == true)
    }

    @Test func chatRowsNameTheChatAndDescribeMedia() {
        func chat(name: String?, phone: String?, group: Bool, kind: MessageKind, body: String?) -> ChatSummary {
            ChatSummary(Chat(
                id: "x", isGroup: group, name: name, phone: phone, lastActivitySecs: 0,
                lastKind: kind, lastBody: body, lastFromMe: false
            ))
        }
        #expect(chat(name: "Ana", phone: "+62", group: false, kind: .text, body: "hi").title == "+62 ~Ana")
        #expect(chat(name: "Ana", phone: nil, group: false, kind: .text, body: "hi").title == "~Ana")
        #expect(chat(name: nil, phone: "+62", group: false, kind: .text, body: "hi").title == "+62")
        #expect(chat(name: nil, phone: nil, group: true, kind: .text, body: nil).title == "Group")
        #expect(chat(name: "Family", phone: nil, group: true, kind: .text, body: nil).title == "Family")
        #expect(chat(name: nil, phone: nil, group: false, kind: .image, body: "beach").preview == "Photo: beach")
        #expect(chat(name: nil, phone: nil, group: false, kind: .document, body: "a.pdf").preview == "a.pdf")
        #expect(chat(name: nil, phone: nil, group: false, kind: .sticker, body: nil).preview == "Sticker")
    }

    @Test func startDoesNothingUnderTests() {
        let model = CoreModel()
        model.start()
        #expect(model.failure == nil && model.state == nil)
    }
}
