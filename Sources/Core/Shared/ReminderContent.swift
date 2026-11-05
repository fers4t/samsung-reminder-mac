import Foundation

/// Samsung stores the body of a reminder as a tiny XML document:
/// `<content><CheckItem done="true">…</CheckItem><TextItem>…</TextItem></content>`.
/// This mirrors the reference implementation byte for byte so records written
/// here stay readable by the phone app.
public enum ReminderContent {
    public struct CheckItem: Hashable, Codable, Sendable {
        public var text: String
        public var done: Bool
        public init(text: String, done: Bool) { self.text = text; self.done = done }
    }

    static func xmlEscape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func xmlUnescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Free text of the reminder (the `<TextItem>`), falling back to plainText.
    public static func text(record: [String: JSONValue]) -> String {
        let xml = record["text"]?.string ?? ""
        if let start = xml.range(of: "<TextItem>"),
           let end = xml.range(of: "</TextItem>", range: start.upperBound..<xml.endIndex) {
            return xmlUnescape(String(xml[start.upperBound..<end.lowerBound]))
        }
        var plain = Substring(record["plainText"]?.string ?? "")
        while plain.last == "\n" { plain.removeLast() }
        return String(plain)
    }

    public static func checklist(record: [String: JSONValue]) -> [CheckItem] {
        var remaining = Substring(record["text"]?.string ?? "")
        var items: [CheckItem] = []
        while let start = remaining.range(of: "<CheckItem") {
            remaining = remaining[start.lowerBound...]
            guard let tagEnd = remaining.firstIndex(of: ">") else { break }
            let attributes = remaining[..<tagEnd]
            let contentStart = remaining.index(after: tagEnd)
            guard let close = remaining.range(of: "</CheckItem>", range: contentStart..<remaining.endIndex) else { break }
            items.append(CheckItem(text: xmlUnescape(String(remaining[contentStart..<close.lowerBound])),
                                   done: attributes.contains("done=\"true\"")))
            remaining = remaining[close.upperBound...]
        }
        return items
    }

    public static func xml(text: String, checklist: [CheckItem]) -> String {
        var body = ""
        for item in checklist {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            body += "<CheckItem done=\"\(item.done)\">\(xmlEscape(trimmed))</CheckItem>"
        }
        if !text.isEmpty { body += "<TextItem>\(xmlEscape(text))</TextItem>" }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?><content>\(body)</content>"
    }

    public static func plainText(text: String, checklist: [CheckItem]) -> String {
        var lines = checklist.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !text.isEmpty { lines.append(text) }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
