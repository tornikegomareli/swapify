import Foundation

/// Rewrites the IR of a device patch so that dyld binds it to the app's own types,
/// instead of the patch defining copies whose accessors the simulator agent would
/// overwrite with jumps. A device cannot write code pages, so this is how a device
/// patch shares the app's types. See docs/architecture.md, "On a device".
///
/// 1. Import: every global or alias the app exports, except chain roots (`$s…TX`)
///    and replacement keys (`$s…Tx`), becomes an external declaration, and so do the
///    accessor functions the app exports (`Ma`, `vau`, `Wl`, `Wa`). Code that names
///    a type's metadata as a constant getelementptr into the patch's `$s…Mf` gets
///    the imported `$s…N` instead.
/// 2. Keep: every function with external linkage (the new bodies), every chain
///    root, every definition that another module of the patch declares, and what
///    they reference. The patch's own metadata, and the records
///    that would register it, are dropped. Types and conformances the app does not
///    export (new in the edit) keep their records.
/// 3. A direct symbolic reference to an imported descriptor cannot point into
///    another image, so it becomes an indirect one through a local `got.` pointer,
///    as Swift emits for types of other modules.
enum PatchBinder {
    struct Result {
        var ir: String
        var imported: Int
        var keptFunctions: Int
        var dropped: Int
    }

    static let accessors = ["Ma", "vau", "Wl", "Wa"]
    static let registrationSections = ["swift5_types", "swift5_proto", "swift5_fieldmd", "swift5_assocty",
                                       "objc_classlist"]

    /// Symbol names, without the leading underscore, from `dyld_info -exports` output.
    static func exports(fromDyldInfo output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0].hasPrefix("0x"), fields[1].hasPrefix("_") else { continue }
            names.insert(String(fields[1].dropFirst()))
        }
        return names
    }

    static func bind(_ source: String, exports: Set<String>, keep: Set<String> = []) throws -> Result {
        try bind(IRModule(source), exports: exports, keep: keep)
    }

    /// `keep`: names that other modules of the same patch declare. Those that this
    /// module defines and the app does not export are kept, such as the metadata of
    /// a new type that only another file uses.
    static func bind(_ module: IRModule, exports: Set<String>, keep: Set<String> = []) throws -> Result {
        var imported = Set<String>()
        for entity in module.entities {
            guard let name = entity.name, exports.contains(name) else { continue }
            if entity.kind == .global, !name.hasSuffix("TX"), !name.hasSuffix("Tx") { imported.insert(name) }
            if entity.kind == .function, accessors.contains(where: name.hasSuffix) { imported.insert(name) }
        }

        // Code names a type's metadata as the alias's expression, not as the alias.
        var aliases: [(expression: String, alias: String)] = []
        for entity in module.entities where entity.kind == .global {
            if let name = entity.name, imported.contains(name), let expression = aliasExpression(entity.text) {
                aliases.append((expression, IRModule.quoted(name)))
            }
        }
        var texts: [String: String] = [:]
        for entity in module.entities {
            guard let name = entity.name, !imported.contains(name) else { continue }
            var text = entity.text
            for (expression, alias) in aliases where IRModule.contains(text, expression) {
                text = text.replacingOccurrences(of: expression, with: alias)
            }
            texts[name] = text
        }

        var roots = module.entities.compactMap { entity -> String? in
            guard let name = entity.name, !imported.contains(name) else { return nil }
            let local = ["internal", "private", "linkonce_odr", "weak_odr"].contains { entity.text.hasPrefix("define \($0)") }
            // `$s…To` thunks are the Objective-C entry points of @objc members: the agent puts
            // them into the app's classes, so they stay although nothing in the patch calls them.
            return (entity.kind == .function && (!local || name.hasSuffix("To"))) || name.hasSuffix("TX") || name.hasSuffix("Tx") ? name : nil
        }
        let declared = module.declarations
        roots += keep.filter { texts[$0] != nil && !declared.contains($0) }
        // A type or conformance only the patch defines keeps the records that register it.
        for entity in module.entities where entity.kind == .global && isRegistration(entity.text) {
            if let name = entity.name, let owner = owner(of: name), module[owner] != nil, !imported.contains(owner) {
                roots.append(name)
            }
        }
        var reachable = Set<String>()
        while let name = roots.popLast() {
            guard !reachable.contains(name), !imported.contains(name), let text = texts[name] else { continue }
            reachable.insert(name)
            roots += IRModule.names(in: text).filter { $0 != name }
        }

        var output = ""
        var got = Set<String>()
        var relative: [(String, String)] = []
        for entity in module.entities {
            guard let name = entity.name else {
                output += entity.text
                continue
            }
            if name == "llvm.used" || name == "llvm.compiler.used" {
                let keep = Set(IRModule.names(in: entity.text)).filter { $0 != name && reachable.contains($0) }.sorted()
                if !keep.isEmpty {
                    let items = keep.map { "ptr \(IRModule.quoted($0))" }.joined(separator: ", ")
                    output += "@\(name) = appending global [\(keep.count) x ptr] [\(items)], section \"llvm.metadata\"\n"
                }
            } else if imported.contains(name) {
                output += entity.kind == .function ? declaration(entity.text)
                    : "\(IRModule.quoted(name)) = external global i8, align 8\n"
            } else if reachable.contains(name), let text = texts[name] {
                let indirect = makeIndirect(text, imported: imported, got: &got)
                relative += relativeTargets(indirect).filter(imported.contains).map { (name, $0) }
                output += indirect
            }
        }
        for target in got.sorted() where module["got." + target] == nil {
            output += "\(IRModule.quoted("got." + target)) = private unnamed_addr constant ptr \(IRModule.quoted(target))\n"
        }
        if let (from, to) = relative.first {
            throw SwapifyError("The patch needs a relative reference from \(from) to the app's \(to), which a separate image cannot have.")
        }
        let named = module.entities.compactMap(\.name)
        return Result(ir: output, imported: imported.count,
                      keptFunctions: reachable.filter { module[$0]?.kind == .function }.count,
                      dropped: named.filter { !imported.contains($0) && !reachable.contains($0)
                          && $0 != "llvm.used" && $0 != "llvm.compiler.used" }.count)
    }

    /// The expression of `@N = alias <type>, getelementptr …`.
    static func aliasExpression(_ line: String) -> String? {
        guard let alias = line.range(of: " = alias "), IRModule.definedName(line) != nil,
              let comma = line[alias.upperBound...].firstIndex(of: ",")
        else { return nil }
        let rest = line[line.index(after: comma)...]
        guard rest.hasPrefix(" getelementptr") else { return nil }
        let expression = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return expression.hasSuffix(")") ? expression : nil
    }

    /// In `__TEXT` or `__DATA`, in one of the sections that register types and conformances.
    private static func isRegistration(_ line: String) -> Bool {
        let bytes = Array(line.utf8), marker = Array(#"section "__"#.utf8)
        guard let start = IRModule.offset(of: marker, in: bytes) else { return false }
        let section = bytes[(start + marker.count)...].prefix { $0 != UInt8(ascii: "\"") }
        let parts = String(decoding: section, as: UTF8.self).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[0] == "TEXT" || parts[0] == "DATA" else { return false }
        return registrationSections.contains { parts[1].hasPrefix("__" + $0) }
    }

    /// The type or conformance descriptor a registration record is for.
    static func owner(of record: String) -> String? {
        if record.hasPrefix("objc_classes_") { return String(record.dropFirst("objc_classes_".count)) }
        for (suffix, target) in [("Hn", "Mn"), ("MF", "Mn"), ("Hc", "Mc"), ("MA", "Mc")] where record.hasSuffix(suffix) {
            return record.dropLast(suffix.count) + target
        }
        return nil
    }

    /// `define <ret> @f(<params>) #n {` becomes `declare <ret> @f(<types>) #n`.
    static func declaration(_ define: String) -> String {
        let firstLine = define.prefix { $0 != "\n" }
        var head = String(firstLine.dropFirst("define ".count))
        if let brace = head.range(of: "{", options: .backwards) { head = String(head[..<brace.lowerBound]) }
        head = head.trimmingCharacters(in: .whitespaces)
        while let debug = head.range(of: #"\s*!dbg !\d+"#, options: .regularExpression) { head.removeSubrange(debug) }
        for linkage in ["internal ", "private ", "linkonce_odr ", "hidden ", "protected ", "dso_local "] {
            head = head.replacingOccurrences(of: linkage, with: "")
        }
        return "declare \(removingParameterNames(head))\n"
    }

    /// `(i64 %0, ptr %self)` becomes `(i64, ptr)`: a space, `%name`, then `,` or `)`.
    private static func removingParameterNames(_ head: String) -> String {
        let bytes = Array(head.utf8)
        var result: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: " "), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "%"),
               let last = result.last, last != UInt8(ascii: " ") {
                var end = i + 2
                while end < bytes.count, IRModule.isNameByte(bytes[end]) { end += 1 }
                if end > i + 2, end < bytes.count, bytes[end] == UInt8(ascii: ",") || bytes[end] == UInt8(ascii: ")") {
                    i = end
                    continue
                }
            }
            result.append(bytes[i])
            i += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    static let directReference = "i8 1, i32 trunc (i64 sub (i64 ptrtoint (ptr @"
    static let relativeReference = "sub (i64 ptrtoint (ptr @"

    /// Direct symbolic references to imported descriptors become indirect ones.
    private static func makeIndirect(_ text: String, imported: Set<String>, got: inout Set<String>) -> String {
        let bytes = Array(text.utf8), marker = Array(directReference.utf8), tail = Array(" to i64)".utf8)
        var result: [UInt8] = []
        var copied = 0, from = 0
        while let found = IRModule.offset(of: marker, in: bytes, from: from) {
            let at = found + marker.count - 1  // the `@`
            from = found + marker.count
            guard let (target, end) = IRModule.scanName(bytes, from: at), bytes[end...].starts(with: tail),
                  imported.contains(target)
            else { continue }
            got.insert(target)
            result += bytes[copied..<found]
            result += Array("i8 2, i32 trunc (i64 sub (i64 ptrtoint (ptr \(IRModule.quoted("got." + target)) to i64)".utf8)
            copied = end + tail.count
            from = copied
        }
        guard copied > 0 else { return text }
        return String(decoding: result + bytes[copied...], as: UTF8.self)
    }

    /// The targets of every relative reference, `sub (i64 ptrtoint (ptr @X to i64)`.
    private static func relativeTargets(_ text: String) -> [String] {
        let bytes = Array(text.utf8), marker = Array(relativeReference.utf8), tail = Array(" to i64)".utf8)
        var targets: [String] = []
        var from = 0
        while let found = IRModule.offset(of: marker, in: bytes, from: from) {
            from = found + marker.count
            if let (target, end) = IRModule.scanName(bytes, from: from - 1), bytes[end...].starts(with: tail) {
                targets.append(target)
            }
        }
        return targets
    }
}
