import Foundation

/// The layout guard for device patches. New code runs on objects with the app's
/// layout, so an edit must not change a type's stored properties or a class's
/// vtable. On the simulator the agent compares type descriptors in memory
/// (Agent/Layout.m). A device patch is bound to the app's descriptors and has none
/// of its own, so the CLI compares the IR of the file as it was built with the IR
/// of the edit, before anything is sent to the phone.
enum LayoutGuard {
    struct Change: Equatable {
        /// The nominal type descriptor symbol, `$s…Mn`.
        var type: String
        var reason: String
    }

    /// The first type defined in both modules whose layout differs. Types new in
    /// the edit, and types it removed, are fine.
    static func change(from original: IRModule, to edited: IRModule) -> Change? {
        for entity in original.entities where entity.kind == .global {
            guard let name = entity.name, name.hasPrefix("$s"), name.hasSuffix("Mn"),
                  let new = edited[name], let kind = kind(entity.text), let newKind = Self.kind(new.text)
            else { continue }
            if kind != newKind { return Change(type: name, reason: "kind of type changed") }
            let fields = String(name.dropLast(2)) + "MF"
            if let reason = fieldChange(original, edited, descriptor: fields, kind: kind) {
                return Change(type: name, reason: reason)
            }
            if canonical(original, name) != canonical(edited, name) {
                let reason = kind == classKind ? "methods added or removed"
                    : kind == enumKind ? "cases changed" : "stored properties changed"
                return Change(type: name, reason: reason)
            }
        }
        return nil
    }

    static let classKind = 16, structKind = 17, enumKind = 18

    /// The context descriptor kind: the low 5 bits of the flags, the first word.
    private static func kind(_ line: String) -> Int? {
        guard let first = IRModule.elements(of: line)?.first,
              let flags = Int(first.split(separator: " ").last ?? "")
        else { return nil }
        let kind = flags & 0x1F
        return [classKind, structKind, enumKind].contains(kind) ? kind : nil
    }

    private struct Field: Equatable {
        var name: String
        var flags: String
        var type: String
    }

    /// Compares field records, like Agent/Layout.m: count, then name, `let` or `var`,
    /// and type of each.
    private static func fieldChange(_ original: IRModule, _ edited: IRModule, descriptor: String, kind: Int) -> String? {
        let old = fields(original, descriptor), new = fields(edited, descriptor)
        let countChanged = kind == enumKind ? "cases changed" : "stored properties changed"
        guard let old, let new else { return old == nil && new == nil ? nil : countChanged }
        guard old.count == new.count else { return countChanged }
        for (a, b) in zip(old, new) {
            if a.name != b.name { return "property '\(a.name)' renamed or moved" }
            if a.flags != b.flags { return "property '\(a.name)' changed between let and var" }
            if a.type != b.type { return "property '\(a.name)' changed type" }
        }
        return nil
    }

    /// The field records of a field descriptor: after a 5-word header, three words
    /// each: flags, mangled type name, field name.
    private static func fields(_ module: IRModule, _ descriptor: String) -> [Field]? {
        guard let line = module[descriptor]?.text, let elements = IRModule.elements(of: line), elements.count >= 5
        else { return nil }
        return stride(from: 5, to: elements.count - 2, by: 3).map { i in
            let name = IRModule.relativeTarget(elements[i + 2]).flatMap { module[$0]?.text }.flatMap(IRModule.cString)
            let type = IRModule.relativeTarget(elements[i + 1]).map { canonical(module, $0) }
            return Field(name: name ?? "?", flags: String(elements[i]), type: type ?? String(elements[i + 1]))
        }
    }

    /// A global's line with references to strings and mangled names replaced by
    /// their content, and references to itself by `@self`, so the same type compiles
    /// to the same text in two modules even when string numbering differs.
    static func canonical(_ module: IRModule, _ name: String, depth: Int = 0) -> String {
        guard let line = module[name]?.text, let equals = line.range(of: " = ") else { return "@" + name }
        let value = String(line[equals.upperBound...])
        var result = ""
        let bytes = Array(value.utf8)
        var i = 0, copied = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "@"), let (reference, end) = IRModule.scanName(bytes, from: i) else {
                i += 1
                continue
            }
            result += String(decoding: bytes[copied..<i], as: UTF8.self)
            if reference == name {
                result += "@self"
            } else if depth < 3, isData(reference) {
                result += "{" + canonical(module, reference, depth: depth + 1) + "}"
            } else {
                result += "@" + reference
            }
            i = end
            copied = end
        }
        return result + String(decoding: bytes[copied...], as: UTF8.self)
    }

    /// Strings and mangled type names: compiler-numbered constants whose names
    /// carry no meaning.
    private static func isData(_ name: String) -> Bool {
        name.hasPrefix(".str") || name.hasPrefix("symbolic ") || name.hasPrefix("got.") || name.allSatisfy(\.isNumber)
    }
}
