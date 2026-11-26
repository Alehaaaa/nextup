import Foundation

/// A small YAML reader for the provider (search engine) files the Flutter app downloads:
/// block maps and lists by indentation, `- key: value` list items, inline `[a, b]` lists,
/// quoted and plain scalars, numbers, booleans and comments. Not a full YAML implementation.
public enum MiniYAML {
    public struct ParseError: Error, LocalizedError {
        public let line: Int
        public let reason: String
        public var errorDescription: String? { "Line \(line): \(reason)" }
    }

    struct Line {
        var indent: Int
        var text: String
        var number: Int
    }

    public static func parse(_ text: String) throws -> Any? {
        var lines: [Line] = []
        for (index, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let withoutComment = stripComment(raw)
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }
            let indent = withoutComment.prefix(while: { $0 == " " }).count
            lines.append(Line(indent: indent, text: trimmed, number: index + 1))
        }
        guard !lines.isEmpty else { return nil }
        var i = 0
        return try block(&lines, &i, indent: lines[0].indent)
    }

    // MARK: Blocks

    private static func isListItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private static func block(_ lines: inout [Line], _ i: inout Int, indent: Int) throws -> Any? {
        guard i < lines.count else { return nil }
        return isListItem(lines[i].text) ? try list(&lines, &i, indent: indent) : try map(&lines, &i, indent: indent)
    }

    private static func list(_ lines: inout [Line], _ i: inout Int, indent: Int) throws -> [Any] {
        var out: [Any] = []
        while i < lines.count, lines[i].indent == indent, isListItem(lines[i].text) {
            let rest = String(lines[i].text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                i += 1
                if i < lines.count, lines[i].indent > indent {
                    out.append(try block(&lines, &i, indent: lines[i].indent) ?? NSNull())
                } else {
                    out.append(NSNull())
                }
            } else if splitKey(rest) != nil {
                // "- key: value" opens a map whose keys sit where "key" starts.
                let column = indent + (lines[i].text.count - rest.count)
                lines[i] = Line(indent: column, text: rest, number: lines[i].number)
                out.append(try map(&lines, &i, indent: column))
            } else {
                out.append(scalar(rest))
                i += 1
            }
        }
        return out
    }

    private static func map(_ lines: inout [Line], _ i: inout Int, indent: Int) throws -> [String: Any] {
        var out: [String: Any] = [:]
        while i < lines.count, lines[i].indent == indent, !isListItem(lines[i].text) {
            let line = lines[i]
            guard let (key, rest) = splitKey(line.text) else {
                throw ParseError(line: line.number, reason: "expected “key: value”")
            }
            i += 1
            if rest.isEmpty {
                if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && isListItem(lines[i].text)) {
                    out[key] = try block(&lines, &i, indent: lines[i].indent) ?? NSNull()
                } else {
                    out[key] = NSNull()
                }
            } else {
                out[key] = scalar(rest)
            }
        }
        if i < lines.count, lines[i].indent > indent {
            throw ParseError(line: lines[i].number, reason: "unexpected indentation")
        }
        return out
    }

    // MARK: Scalars

    /// Splits "key: value" (or "key:") outside quotes.
    static func splitKey(_ text: String) -> (String, String)? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                if index == text.startIndex { quote = c }
            } else if c == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    let rawKey = text[..<index].trimmingCharacters(in: .whitespaces)
                    guard !rawKey.isEmpty, !rawKey.hasPrefix("["), !rawKey.hasPrefix("{") else { return nil }
                    let key = (scalar(rawKey) as? String) ?? rawKey
                    let value = next == text.endIndex ? "" : text[next...].trimmingCharacters(in: .whitespaces)
                    return (key, value)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func scalar(_ raw: String) -> Any {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { return unescape(String(text.dropFirst().dropLast())) }
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            return splitInline(inner).map { scalar($0) }
        }
        if text == "{}" { return [String: Any]() }
        switch text {
        case "true", "True", "yes": return true
        case "false", "False", "no": return false
        case "null", "~", "Null": return NSNull()
        default: break
        }
        if let int = Int(text) { return int }
        if let double = Double(text), text.contains(".") { return double }
        return text
    }

    private static func splitInline(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for c in text {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let next = iterator.next() else { out.append(c); continue }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            default: out.append("\\"); out.append(next)
            }
        }
        return out
    }

    /// Drops a trailing "# comment" that is not inside quotes.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == q && previous != "\\" { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " || previous == "\t" || index == line.startIndex {
                return String(line[..<index])
            }
            previous = c
            index = line.index(after: index)
        }
        return line
    }
}
