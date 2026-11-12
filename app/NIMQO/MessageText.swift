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

    /// `text` with its mentions by name, plain: for a quote of it.
    static func named(_ text: String?, mentions: [Mention]) -> String? {
        guard let text else { return nil }
        return String(attributed(text, mentions: mentions).characters)
    }

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
            tagged.append(link.range)
        }
        formatted(&out, shown: shown, untouched: tagged)
        return out
    }
}

/// WhatsApp's formatting: *bold*, _italic_, ~strikethrough~, `code`,
/// ```monospace```, "> " quotes and "- " or "* " lists. Links and mentions
/// are left as they are: a URL's underscores are not italics.
extension MessageText {
    /// A marker opens before a non-space and closes after one, on one line,
    /// with no letter or digit outside it (so 2*3*4 stays as typed).
    private static func inline(_ marker: String) -> NSRegularExpression? {
        let mark = NSRegularExpression.escapedPattern(for: marker)
        let open = "(?<![\\p{L}\\p{N}\(mark)])\(mark)(?=[^\\s\(mark)])"
        let close = "\(mark)(?![\\p{L}\\p{N}\(mark)])"
        return try? NSRegularExpression(pattern: open + "([^\\n]*?[^\\s\(mark)])?" + close)
    }

    private static let styles: [(NSRegularExpression?, InlinePresentationIntent)] = [
        // Code first: what is inside it is not formatted.
        (inline("`"), .code), (inline("*"), .stronglyEmphasized),
        (inline("_"), .emphasized), (inline("~"), .strikethrough),
    ]
    private static let block = try? NSRegularExpression(pattern: "```([\\s\\S]+?)```")
    private static let lines = try? NSRegularExpression(pattern: "^(> |[-*] )", options: .anchorsMatchLines)

    /// Styles `out` (whose text is `shown`) and drops the markers.
    fileprivate static func formatted(_ out: inout AttributedString, shown: String, untouched: [NSRange]) {
        let text = shown as NSString
        let all = NSRange(location: 0, length: text.length)
        var fenced: [NSRange] = []
        // Marker ranges, each with what replaces it ("" drops it).
        var edits: [(NSRange, String)] = []
        func clear(_ range: NSRange) -> Bool {
            !(untouched + fenced).contains { NSIntersectionRange($0, range).length > 0 }
        }
        func style(_ range: NSRange, _ intent: InlinePresentationIntent) {
            guard let span = Range(range, in: out) else { return }
            for run in out[span].runs {
                out[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
            }
        }
        for match in block?.matches(in: shown, range: all) ?? [] where clear(match.range) {
            style(match.range(at: 1), .code)
            edits += [(NSRange(location: match.range.location, length: 3), ""),
                      (NSRange(location: NSMaxRange(match.range) - 3, length: 3), "")]
            fenced.append(match.range)
        }
        for (pattern, intent) in styles {
            for match in pattern?.matches(in: shown, range: all) ?? [] where clear(match.range) {
                style(match.range, intent)
                if intent == .code {
                    fenced.append(match.range)
                }
                edits += [(NSRange(location: match.range.location, length: 1), ""),
                          (NSRange(location: NSMaxRange(match.range) - 1, length: 1), "")]
            }
        }
        for match in lines?.matches(in: shown, range: all) ?? [] where clear(match.range) {
            let quote = text.substring(with: match.range) == "> "
            if quote, let line = Range(text.lineRange(for: match.range), in: out) {
                out[line].foregroundColor = .secondary
            }
            edits.append((match.range, quote ? "▎ " : "• "))
        }
        // From the end, so the ranges still ahead stay where they were.
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            guard let span = Range(range, in: out) else { continue }
            var new = AttributedString(replacement)
            if replacement == "▎ " {
                new.foregroundColor = .secondary
            }
            out.replaceSubrange(span, with: new)
        }
    }
}
