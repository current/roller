import Foundation

/// A small TOML reader/writer covering what Roller's config file uses:
/// tables (`[a]`, `[a.b]`, quoted keys), strings, integers, floats,
/// booleans, arrays (multi-line, trailing commas) and inline tables.
public indirect enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? {
        switch self {
        case .float(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
    public var int: Int? {
        switch self {
        case .integer(let i): return i
        case .float(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }
    public var array: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { return t }; return nil }
}

public struct TOMLError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    // MARK: Parsing

    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var p = Parser(Array(text.unicodeScalars))
        return try p.document()
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1
        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        func error(_ m: String) -> TOMLError { TOMLError(line: line, message: m) }

        mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        mutating func skipComment() {
            if peek == "#" { while let c = peek, c != "\n" { advance() } }
        }

        /// Skips whitespace, newlines and comments.
        mutating func skipAll() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
                else if c == "#" { skipComment() }
                else { break }
            }
        }

        mutating func expectLineEnd() throws {
            skipSpaces()
            skipComment()
            if peek == "\r" { advance() }
            guard atEnd || peek == "\n" else { throw error("expected end of line") }
        }

        mutating func document() throws -> [String: TOMLValue] {
            var root: [String: TOMLValue] = [:]
            var current: [String] = []
            while true {
                skipAll()
                guard let c = peek else { break }
                if c == "[" {
                    advance()
                    if peek == "[" { throw error("arrays of tables are not supported") }
                    skipSpaces()
                    current = try keyPath()
                    skipSpaces()
                    guard peek == "]" else { throw error("expected ]") }
                    advance()
                    try ensureTable(&root, current)
                    try expectLineEnd()
                } else {
                    let key = try keyPath()
                    skipSpaces()
                    guard peek == "=" else { throw error("expected = after key") }
                    advance()
                    skipSpaces()
                    let v = try value()
                    try insert(&root, current + key, v)
                    try expectLineEnd()
                }
            }
            return root
        }

        mutating func keyPath() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                parts.append(try key())
                skipSpaces()
                if peek == "." { advance() } else { break }
            }
            return parts
        }

        mutating func key() throws -> String {
            if peek == "\"" { return try basicString() }
            if peek == "'" { return try literalString() }
            var out = ""
            while let c = peek, c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_" || c == "-" {
                out.unicodeScalars.append(c)
                advance()
            }
            guard !out.isEmpty else { throw error("expected a key") }
            return out
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw error("expected a value") }
            switch c {
            case "\"": return .string(try basicString())
            case "'": return .string(try literalString())
            case "[": return try arrayValue()
            case "{": return try inlineTable()
            case "t", "f": return try boolValue()
            default: return try number()
            }
        }

        mutating func basicString() throws -> String {
            advance() // opening quote
            if peek == "\"" && i + 1 < s.count && s[i + 1] == "\"" {
                advance(); advance()
                return try multilineBasic()
            }
            var out = ""
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if c == "\n" { throw error("newline in string") }
                advance()
                if c == "\"" { return out }
                if c == "\\" { out.unicodeScalars.append(try escape()) } else { out.unicodeScalars.append(c) }
            }
        }

        mutating func multilineBasic() throws -> String {
            if peek == "\n" { advance() }
            var out = ""
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if c == "\"" && i + 2 < s.count && s[i + 1] == "\"" && s[i + 2] == "\"" {
                    advance(); advance(); advance()
                    return out
                }
                advance()
                if c == "\\" { out.unicodeScalars.append(try escape()) } else { out.unicodeScalars.append(c) }
            }
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let e = peek else { throw error("bad escape") }
            advance()
            switch e {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "b": return "\u{8}"
            case "f": return "\u{c}"
            case "u", "U":
                let n = e == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<n {
                    guard let h = peek else { throw error("bad unicode escape") }
                    hex.unicodeScalars.append(h)
                    advance()
                }
                guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { throw error("bad unicode escape") }
                return u
            default: throw error("unknown escape \\\(e)")
            }
        }

        mutating func literalString() throws -> String {
            advance()
            var out = ""
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if c == "\n" { throw error("newline in string") }
                advance()
                if c == "'" { return out }
                out.unicodeScalars.append(c)
            }
        }

        mutating func boolValue() throws -> TOMLValue {
            for (word, v) in [("true", true), ("false", false)] {
                let w = Array(word.unicodeScalars)
                if i + w.count <= s.count && Array(s[i..<i + w.count]) == w {
                    for _ in w { advance() }
                    return .bool(v)
                }
            }
            throw error("expected true or false")
        }

        mutating func number() throws -> TOMLValue {
            var raw = ""
            while let c = peek, ("0"..."9").contains(c) || c == "-" || c == "+" || c == "." || c == "_" || c == "e" || c == "E" {
                raw.unicodeScalars.append(c)
                advance()
            }
            let clean = raw.replacingOccurrences(of: "_", with: "")
            guard !clean.isEmpty else { throw error("expected a value") }
            if let n = Int(clean) { return .integer(n) }
            if let d = Double(clean) { return .float(d) }
            throw error("invalid number \(raw)")
        }

        mutating func arrayValue() throws -> TOMLValue {
            advance()
            var items: [TOMLValue] = []
            while true {
                skipAll()
                if peek == "]" { advance(); return .array(items) }
                items.append(try value())
                skipAll()
                if peek == "," { advance(); continue }
                skipAll()
                guard peek == "]" else { throw error("expected , or ] in array") }
                advance()
                return .array(items)
            }
        }

        mutating func inlineTable() throws -> TOMLValue {
            advance()
            var t: [String: TOMLValue] = [:]
            skipSpaces()
            if peek == "}" { advance(); return .table(t) }
            while true {
                skipSpaces()
                let k = try keyPath()
                skipSpaces()
                guard peek == "=" else { throw error("expected = in inline table") }
                advance()
                skipSpaces()
                try insert(&t, k, try value())
                skipSpaces()
                if peek == "," { advance(); continue }
                guard peek == "}" else { throw error("expected , or } in inline table") }
                advance()
                return .table(t)
            }
        }

        func ensureTable(_ root: inout [String: TOMLValue], _ path: [String]) throws {
            guard let first = path.first else { return }
            var sub = root[first]?.table ?? [:]
            if root[first] != nil && root[first]?.table == nil { throw error("\(first) is not a table") }
            try ensureTable(&sub, Array(path.dropFirst()))
            root[first] = .table(sub)
        }

        func insert(_ root: inout [String: TOMLValue], _ path: [String], _ v: TOMLValue) throws {
            guard let first = path.first else { return }
            if path.count == 1 {
                if root[first] != nil { throw error("duplicate key \(first)") }
                root[first] = v
                return
            }
            if root[first] != nil && root[first]?.table == nil { throw error("\(first) is not a table") }
            var sub = root[first]?.table ?? [:]
            try insert(&sub, Array(path.dropFirst()), v)
            root[first] = .table(sub)
        }
    }

    // MARK: Writing

    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    public static func key(_ k: String) -> String {
        let bare = !k.isEmpty && k.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        return bare ? k : quote(k)
    }

    public static func format(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .integer(let i): return String(i)
        case .float(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
            var s = String(format: "%.5f", d)
            while s.hasSuffix("0") { s.removeLast() }
            return s
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[" + a.map(format).joined(separator: ", ") + "]"
        case .table(let t):
            return "{ " + t.keys.sorted().map { "\(key($0)) = \(format(t[$0]!))" }.joined(separator: ", ") + " }"
        }
    }
}
