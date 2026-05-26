import Foundation

/// Minimal hand-rolled TOML parser, intentionally restricted to the subset
/// that `UZoraConfig` needs (~30 keys).
///
/// **Supported subset:**
/// - Top-level `key = value` pairs
/// - Nested tables `[a.b.c]`
/// - Values: strings (basic `"..."`, no triple-quoted / literal `'...'`),
///   integers, floats, booleans, arrays
/// - Arrays may span multiple lines (matching `[` / `]` is honoured)
/// - Comments starting with `#`
/// - UTF-8 input, LF or CRLF line endings
///
/// **Out of scope** (rejected or silently ignored):
/// - Inline tables `{ a = 1, b = 2 }`
/// - Arrays of tables `[[servers]]`
/// - Dates / times — handle as strings at the caller side
/// - Multi-line strings, escape sequences beyond `\"`, `\\`, `\n`, `\t`, `\r`, `\0`
/// - Literal strings (`'...'`), hex/oct/bin integers
public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([(String, TOMLValue)])  // ordered for deterministic emit

    public static func == (lhs: TOMLValue, rhs: TOMLValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.table(let a), .table(let b)):
            guard a.count == b.count else { return false }
            for (i, pair) in a.enumerated() {
                if pair.0 != b[i].0 || pair.1 != b[i].1 { return false }
            }
            return true
        default: return false
        }
    }

    public var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var asInt: Int64? {
        if case .integer(let i) = self { return i }
        return nil
    }

    public var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var asArray: [TOMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var asTable: [(String, TOMLValue)]? {
        if case .table(let t) = self { return t }
        return nil
    }

    /// Lookup by key in a table; returns nil for non-tables or missing.
    public func value(forKey key: String) -> TOMLValue? {
        guard case .table(let entries) = self else { return nil }
        return entries.first(where: { $0.0 == key })?.1
    }
}

/// Errors emitted by the parser.
public enum TOMLParseError: Swift.Error, CustomStringConvertible, Equatable {
    case unexpectedCharacter(Character, line: Int)
    case unterminatedString(line: Int)
    case malformedNumber(String, line: Int)
    case malformedArray(line: Int)
    case malformedTableHeader(line: Int)
    case duplicateKey(String, line: Int)
    case invalidValue(String, line: Int)

    public var description: String {
        switch self {
        case .unexpectedCharacter(let c, let l): return "line \(l): unexpected character '\(c)'"
        case .unterminatedString(let l): return "line \(l): unterminated string literal"
        case .malformedNumber(let s, let l): return "line \(l): malformed number '\(s)'"
        case .malformedArray(let l): return "line \(l): malformed array"
        case .malformedTableHeader(let l): return "line \(l): malformed table header"
        case .duplicateKey(let k, let l): return "line \(l): duplicate key '\(k)'"
        case .invalidValue(let s, let l): return "line \(l): invalid value '\(s)'"
        }
    }
}

/// Hand-rolled TOML parser. Stateless; safe to instantiate per parse.
public struct TOMLParser {

    public init() {}

    /// Parse a TOML document.
    public func parse(_ input: String) throws -> TOMLValue {
        let builder = OrderedTable()
        let lines = Self.splitLines(input)
        var currentPath: [String] = []
        var i = 0
        while i < lines.count {
            let lineNo = i + 1
            let line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                i += 1
                continue
            }

            // Table header `[a.b.c]`
            if line.first == "[" {
                guard let endIdx = line.firstIndex(of: "]"),
                      endIdx == line.index(before: line.endIndex) else {
                    throw TOMLParseError.malformedTableHeader(line: lineNo)
                }
                let inner = String(line[line.index(after: line.startIndex)..<endIdx])
                    .trimmingCharacters(in: .whitespaces)
                let parts = inner.split(separator: ".").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
                    throw TOMLParseError.malformedTableHeader(line: lineNo)
                }
                currentPath = parts
                try builder.ensurePath(currentPath, lineNo: lineNo)
                i += 1
                continue
            }

            // Key = value
            guard let eqIdx = line.firstIndex(of: "=") else {
                throw TOMLParseError.unexpectedCharacter(line.first ?? " ", line: lineNo)
            }
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var rest = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw TOMLParseError.unexpectedCharacter("=", line: lineNo)
            }

            // Quoted keys: "foo bar" = ...
            let unquotedKey: String
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
                unquotedKey = String(key.dropFirst().dropLast())
            } else {
                unquotedKey = key
            }

            // Multi-line array: stitch following lines until brackets balance.
            if rest.hasPrefix("["), bracketDepth(rest) > 0 {
                var j = i + 1
                while j < lines.count, bracketDepth(rest) > 0 {
                    let nextRaw = stripComment(lines[j]).trimmingCharacters(in: .whitespaces)
                    rest += " " + nextRaw
                    j += 1
                }
                i = j
            } else {
                i += 1
            }

            let value = try parseValue(rest, lineNo: lineNo)
            try builder.set(path: currentPath, key: unquotedKey, value: value, lineNo: lineNo)
        }
        return builder.value
    }

    // MARK: - Bracket depth

    /// Returns the *net* unclosed `[` depth in `s`, accounting for string
    /// literals. Used to detect when a multi-line array spans more rows.
    private func bracketDepth(_ s: String) -> Int {
        var depth = 0
        var inString = false
        var prev: Character = " "
        for c in s {
            if c == "\"" && prev != "\\" {
                inString.toggle()
            }
            if !inString {
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1 }
            }
            prev = c
        }
        return depth
    }

    // MARK: - Line helpers

    private static func splitLines(_ input: String) -> [String] {
        // Normalise CRLF to LF then split.
        let normalised = input.replacingOccurrences(of: "\r\n", with: "\n")
        return normalised.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Strip a trailing `#` comment, honouring string literals.
    private func stripComment(_ line: String) -> String {
        var out = ""
        var inString = false
        var prev: Character = " "
        for c in line {
            if c == "\"" && prev != "\\" {
                inString.toggle()
            }
            if c == "#" && !inString {
                break
            }
            out.append(c)
            prev = c
        }
        return out
    }

    // MARK: - Value parser

    private func parseValue(_ raw: String, lineNo: Int) throws -> TOMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { throw TOMLParseError.invalidValue("", line: lineNo) }

        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }

        if s.hasPrefix("\"") {
            return try .string(parseQuotedString(s, lineNo: lineNo))
        }

        if s.hasPrefix("[") {
            return try parseArray(s, lineNo: lineNo)
        }

        if let i = Int64(s) {
            return .integer(i)
        }
        if let d = Double(s) {
            if s.contains(".") || s.contains("e") || s.contains("E") {
                return .double(d)
            }
            // Non-Int64 representable integer → fall through to double.
            return .double(d)
        }
        throw TOMLParseError.invalidValue(s, line: lineNo)
    }

    private func parseQuotedString(_ s: String, lineNo: Int) throws -> String {
        guard s.hasPrefix("\"") else {
            throw TOMLParseError.invalidValue(s, line: lineNo)
        }
        var out = ""
        var i = s.index(after: s.startIndex)
        var closed = false
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                i = s.index(after: i)
                if i >= s.endIndex { break }
                let esc = s[i]
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                default: out.append(esc)
                }
            } else if c == "\"" {
                closed = true
                break
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        if !closed { throw TOMLParseError.unterminatedString(line: lineNo) }
        return out
    }

    private func parseArray(_ s: String, lineNo: Int) throws -> TOMLValue {
        guard s.hasPrefix("["), s.hasSuffix("]") else {
            throw TOMLParseError.malformedArray(line: lineNo)
        }
        let inner = String(s.dropFirst().dropLast())
        // Split on top-level commas (respecting nested arrays + strings).
        var items: [String] = []
        var depth = 0
        var inString = false
        var current = ""
        var prev: Character = " "
        for c in inner {
            if c == "\"" && prev != "\\" { inString.toggle() }
            if !inString {
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1 }
                if c == "," && depth == 0 {
                    let t = current.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { items.append(t) }
                    current = ""
                    prev = c
                    continue
                }
            }
            current.append(c)
            prev = c
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            items.append(trimmed)
        }
        var values: [TOMLValue] = []
        for item in items {
            values.append(try parseValue(item, lineNo: lineNo))
        }
        return .array(values)
    }
}

// MARK: - Ordered table builder

/// Builds the root table while preserving insertion order so the emitted
/// TOML stays deterministic. Caller passes a path (list of table segments)
/// + key + value; the builder ensures the path exists then sets the leaf.
private final class OrderedTable {
    var value: TOMLValue = .table([])

    func ensurePath(_ path: [String], lineNo: Int) throws {
        try Self.ensurePath(in: &value, path: path, lineNo: lineNo)
    }

    func set(path: [String], key: String, value v: TOMLValue, lineNo: Int) throws {
        try Self.set(in: &value, path: path, key: key, value: v, lineNo: lineNo)
    }

    private static func ensurePath(in node: inout TOMLValue, path: [String], lineNo: Int) throws {
        guard !path.isEmpty else { return }
        guard case .table(var entries) = node else {
            throw TOMLParseError.malformedTableHeader(line: lineNo)
        }
        defer { node = .table(entries) }
        if let idx = entries.firstIndex(where: { $0.0 == path[0] }) {
            var child = entries[idx].1
            if case .table = child {
                try ensurePath(in: &child, path: Array(path.dropFirst()), lineNo: lineNo)
                entries[idx] = (path[0], child)
            } else {
                throw TOMLParseError.duplicateKey(path[0], line: lineNo)
            }
        } else {
            var newChild: TOMLValue = .table([])
            try ensurePath(in: &newChild, path: Array(path.dropFirst()), lineNo: lineNo)
            entries.append((path[0], newChild))
        }
    }

    private static func set(in node: inout TOMLValue, path: [String], key: String, value v: TOMLValue, lineNo: Int) throws {
        guard case .table(var entries) = node else {
            throw TOMLParseError.malformedTableHeader(line: lineNo)
        }
        defer { node = .table(entries) }
        if path.isEmpty {
            if entries.contains(where: { $0.0 == key }) {
                throw TOMLParseError.duplicateKey(key, line: lineNo)
            }
            entries.append((key, v))
            return
        }
        if let idx = entries.firstIndex(where: { $0.0 == path[0] }) {
            var child = entries[idx].1
            try set(in: &child, path: Array(path.dropFirst()), key: key, value: v, lineNo: lineNo)
            entries[idx] = (path[0], child)
        } else {
            var newChild: TOMLValue = .table([])
            try set(in: &newChild, path: Array(path.dropFirst()), key: key, value: v, lineNo: lineNo)
            entries.append((path[0], newChild))
        }
    }
}

// MARK: - Emitter

/// Render a `TOMLValue.table([...])` back to TOML text. Output is
/// deterministic (preserves insertion order).
public struct TOMLEmitter {

    public init() {}

    public func emit(_ value: TOMLValue) -> String {
        guard case .table(let entries) = value else {
            return formatScalar(value)
        }
        var out = ""
        // Top-level scalars first.
        for (k, v) in entries where !isTable(v) {
            out += "\(k) = \(formatScalar(v))\n"
        }
        // Then sub-tables recursively.
        for (k, v) in entries where isTable(v) {
            emitTable(value: v, path: [k], into: &out)
        }
        return out
    }

    private func emitTable(value: TOMLValue, path: [String], into out: inout String) {
        guard case .table(let entries) = value else { return }
        out += "\n[\(path.joined(separator: "."))]\n"
        for (k, v) in entries where !isTable(v) {
            out += "\(k) = \(formatScalar(v))\n"
        }
        for (k, v) in entries where isTable(v) {
            emitTable(value: v, path: path + [k], into: &out)
        }
    }

    private func isTable(_ v: TOMLValue) -> Bool {
        if case .table = v { return true }
        return false
    }

    private func formatScalar(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s):
            return "\"\(escapeString(s))\""
        case .integer(let i):
            return String(i)
        case .double(let d):
            if d.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.1f", d)
            }
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .array(let items):
            return "[\(items.map(formatScalar).joined(separator: ", "))]"
        case .table:
            return "{}"
        }
    }

    private func escapeString(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            default: out.append(c)
            }
        }
        return out
    }
}
