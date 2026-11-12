import Foundation
@testable import NIMQO
import Testing

struct MessageTextTests {
    private func shown(_ text: String) -> String {
        String(MessageText.attributed(text, mentions: []).characters)
    }

    private func intent(of word: String, in text: String) -> InlinePresentationIntent? {
        let out = MessageText.attributed(text, mentions: [])
        guard let range = out.range(of: word) else { return nil }
        return out[range].runs.first?.inlinePresentationIntent
    }

    @Test func markersStyleAndDisappear() {
        #expect(shown("*bold* _it_ ~gone~ `code`") == "bold it gone code")
        #expect(intent(of: "bold", in: "a *bold* b") == .stronglyEmphasized)
        #expect(intent(of: "it", in: "_it_") == .emphasized)
        #expect(intent(of: "gone", in: "~gone~") == .strikethrough)
        #expect(intent(of: "both", in: "*_both_*") == [.stronglyEmphasized, .emphasized])
        #expect(shown("```let x = 1```") == "let x = 1")
    }

    @Test func plainTextAndLinksStayAsTyped() {
        #expect(shown("2*3*4 and snake_case_name") == "2*3*4 and snake_case_name")
        #expect(shown("* not bold *") == "• not bold *")
        #expect(shown("see https://example.com/a_b_c") == "see https://example.com/a_b_c")
        #expect(shown("`*kept*`") == "*kept*")
        #expect(shown("> quoted\n- item") == "▎ quoted\n• item")
    }
}

extension MessageTextTests {
    @Test func linksAreCopiedAsTyped() {
        let text = "see example.com/a_b or https://x.org, mail me@ex.com; file:///etc/passwd"
        #expect(MessageText.links(in: text) == ["example.com/a_b", "https://x.org", "me@ex.com"])
        #expect(MessageText.links(in: nil).isEmpty)
    }
}
