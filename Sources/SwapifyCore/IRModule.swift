import Foundation

/// A textual LLVM IR module, split into its top-level entities. Device patches are
/// built from IR: the layout guard reads type descriptors in it, and the binder
/// rewrites it. Swift's IR has one line per global and alias, and functions from
/// `define` to `}`.
struct IRModule {
    enum Kind { case global, function, other }

    struct Entity {
        var kind: Kind
        /// The symbol name without `@` and quotes. Nil for other lines.
        var name: String?
        /// The entity's lines, each with its newline.
        var text: String
    }

    var entities: [Entity] = []
    /// Index into `entities` by name.
    var index: [String: Int] = [:]

    init(_ source: String) {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) + "\n" }
        if source.hasSuffix("\n") { lines.removeLast() }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("define ") {
                var end = i
                while end < lines.count, !Self.closesFunction(lines[end]) { end += 1 }
                end = min(end, lines.count - 1)
                append(Entity(kind: .function, name: Self.names(in: line).first,
                              text: lines[i...end].joined()))
                i = end + 1
                continue
            }
            if line.hasPrefix("@"), let name = Self.definedName(line) {
                append(Entity(kind: .global, name: name, text: line))
            } else {
                append(Entity(kind: .other, name: nil, text: line))
            }
            i += 1
        }
    }

    /// `}` with nothing after it but whitespace.
    private static func closesFunction(_ line: String) -> Bool {
        line.hasPrefix("}") && line.dropFirst().allSatisfy(\.isWhitespace)
    }

    private mutating func append(_ entity: Entity) {
        if let name = entity.name { index[name] = entities.count }
        entities.append(entity)
    }

    subscript(name: String) -> Entity? { index[name].map { entities[$0] } }

    /// The name a global or alias line defines: `@name = …`.
    static func definedName(_ line: String) -> String? {
        guard let (name, end) = scanName(Array(line.utf8), from: 0) else { return nil }
        return line.utf8.dropFirst(end).starts(with: " = ".utf8) ? name : nil
    }

    /// Every `@name` in `text`, in order.
    static func names(in text: String) -> [String] {
        let bytes = Array(text.utf8)
        var names: [String] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "@"), let (name, end) = scanName(bytes, from: i) {
                names.append(name)
                i = end
            } else {
                i += 1
            }
        }
        return names
    }

    /// The name at `bytes[start]`, which must be `@`: `@"quoted"` (escapes kept as
    /// written) or `@[-a-zA-Z$._0-9]+`. Returns the name and the index after it.
    static func scanName(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "@") else { return nil }
        var i = start + 1
        if i < bytes.count, bytes[i] == UInt8(ascii: "\"") {
            i += 1
            let first = i
            while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard i < bytes.count, i > first else { return nil }
            return (String(decoding: bytes[first..<i], as: UTF8.self), i + 1)
        }
        let first = i
        while i < bytes.count, isNameByte(bytes[i]) { i += 1 }
        return i > first ? (String(decoding: bytes[first..<i], as: UTF8.self), i) : nil
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "$"),
             UInt8(ascii: "."), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    /// `@"name"` for names that need quotes, as Swift writes every `$s` symbol.
    static func quoted(_ name: String) -> String { "@\"\(name)\"" }

    // MARK: Constants

    /// The top-level elements of a global's initializer: `{ i32 1, i32 trunc (…) }`
    /// gives `["i32 1", "i32 trunc (…)"]`. Nil if the initializer is not a struct.
    static func elements(of line: String) -> [Substring]? {
        guard let equals = line.range(of: " = ") else { return nil }
        let rest = line[equals.upperBound...]
        // The value is the second brace group: the first is its type.
        var groups: [Substring] = []
        var depth = 0
        var start = rest.startIndex
        for i in rest.indices {
            let c = rest[i]
            if c == "{" { if depth == 0 { start = i }; depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { groups.append(rest[start...i]) }
                if groups.count == 2 { break }
            }
        }
        guard groups.count == 2 else { return nil }
        let body = groups[1].dropFirst().dropLast()
        var parts: [Substring] = []
        var level = 0
        var partStart = body.startIndex
        for i in body.indices {
            switch body[i] {
            case "(", "{", "[": level += 1
            case ")", "}", "]": level -= 1
            case "," where level == 0:
                parts.append(body[partStart..<i].trimmingCharacters(in: .whitespaces)[...])
                partStart = body.index(after: i)
            default: break
            }
        }
        parts.append(body[partStart...].trimmingCharacters(in: .whitespaces)[...])
        return parts
    }

    /// The symbol a relative reference element points at:
    /// `i32 trunc (i64 sub (i64 ptrtoint (ptr @X to i64), …))` gives `X`.
    static func relativeTarget(_ element: Substring) -> String? {
        guard let range = element.range(of: "ptrtoint (ptr @") else { return nil }
        let bytes = Array(element[element.index(before: range.upperBound)...].utf8)
        return scanName(bytes, from: 0)?.0
    }

    /// The bytes of a `c"…"` string constant, up to its first NUL.
    static func cString(_ line: String) -> String? {
        guard let open = line.range(of: "c\"") else { return nil }
        var bytes: [UInt8] = []
        var i = line.utf8.index(open.upperBound, offsetBy: 0)
        let utf8 = line.utf8
        while i < utf8.endIndex, utf8[i] != UInt8(ascii: "\"") {
            if utf8[i] == UInt8(ascii: "\\"), let hex = UInt8(String(line[utf8.index(after: i)...].prefix(2)), radix: 16) {
                if hex == 0 { break }
                bytes.append(hex)
                i = utf8.index(i, offsetBy: 3)
            } else {
                bytes.append(utf8[i])
                i = utf8.index(after: i)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
