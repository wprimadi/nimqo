import Foundation
import NimqoCore
import SwiftUI

/// A message's words as shown: "@number" mentions by name, and web and
/// mail links that open when clicked.
enum MessageText {
    /// Only these open: a message must not get a click to launch an app or
    /// a file.
    private static let schemes: Set<String> = ["http", "https", "mailto"]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String, mentions: [Mention]) -> AttributedString {
        let names = Dictionary(mentions.map { ($0.user, $0.name) }) { first, _ in first }
        var out = AttributedString()
        var shown = ""
        var tagged: [NSRange] = []
        var cursor = text.startIndex
        for match in text.matches(of: /@(\d{5,20})(?!\d)/) {
            guard let name = names[String(match.output.1)] else { continue }
            let before = String(text[cursor ..< match.range.lowerBound])
            out += AttributedString(before)
            shown += before
            let label = "@" + name
            var mention = AttributedString(label)
            mention.inlinePresentationIntent = .stronglyEmphasized
            mention.foregroundColor = .accentColor
            out += mention
            tagged.append(NSRange(location: (shown as NSString).length, length: (label as NSString).length))
            shown += label
            cursor = match.range.upperBound
        }
        out += AttributedString(String(text[cursor...]))
        shown += text[cursor...]

        let all = NSRange(location: 0, length: (shown as NSString).length)
        for link in detector?.matches(in: shown, range: all) ?? [] {
            guard let url = link.url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
                  !tagged.contains(where: { NSIntersectionRange($0, link.range).length > 0 }),
                  let range = Range(link.range, in: out) else { continue }
            out[range].link = url
            out[range].underlineStyle = .single
        }
        return out
    }
}
