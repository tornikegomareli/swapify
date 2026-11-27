import Foundation

/// A type whose metadata is static (a struct or enum with a fixed layout, such as a
/// private `ViewModifier` with `Double` fields) has it in the patch too, as `$s…Mf`, with
/// `$s…N` at its address point. Code that names it directly, rather than through the
/// metadata accessor that the agent jumps to the app's, gets the patch's copy: a second
/// type to the runtime. SwiftUI then cannot cast a view built with it to the app's
/// (issue #7).
///
/// In a simulator patch, each such reference in a function becomes a load from a slot,
/// `swapify.meta.<$s…N>`, that holds the patch's own metadata. The agent writes the
/// app's metadata into every slot whose type the app has (Agent/Patcher.m), and a type
/// new since the build keeps its own. A device patch gets the same from dyld: the binder
/// binds such references to the app's `$s…N` (PatchBinder).
enum MetadataSlots {
    static func rewrite(_ ir: String) -> String {
        let types = staticMetadata(ir)
        guard !types.isEmpty else { return ir }
        var lines = ir.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count + 64)
        var used = Set<String>()
        var counter = 0
        var inFunction = false
        for line in lines {
            if line.hasPrefix("define ") { inFunction = true }
            else if line == "}" { inFunction = false }
            guard inFunction, !line.hasPrefix("define "), line.contains("@\"$s"), !line.contains(" = phi ") else {
                output.append(line)
                continue
            }
            var rewritten = line
            var loads: [String] = []
            for reference in references(in: line, types: types).reversed() {
                counter += 1
                let value = "%swp.meta.\(counter)"
                loads.append("  \(value) = load ptr, ptr @\"swapify.meta.\(reference.metadata)\", align 8")
                var replacement = value
                if reference.delta != 0 {
                    loads.append("  \(value).at = getelementptr inbounds i8, ptr \(value), i64 \(reference.delta)")
                    replacement = value + ".at"
                }
                rewritten.replaceSubrange(reference.range, with: replacement)
                used.insert(reference.metadata)
            }
            output.append(contentsOf: loads)
            output.append(rewritten)
        }
        lines = output
        for metadata in used.sorted() {
            lines.append("@\"swapify.meta.\(metadata)\" = internal global ptr @\"\(metadata)\", align 8")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct StaticMetadata {
        var metadata: String  // `$s…N`
        var addressPoint: Int  // byte offset of `$s…N` in `$s…Mf`
        var offsets: [Int]     // byte offset of each element of `$s…Mf`
    }

    /// `$s…Mf` -> its `$s…N`, from the aliases `@"$s…N" = … alias %swift.type,
    /// getelementptr inbounds (<{ … }>, ptr @"$s…Mf", i32 0, i32 K)`.
    static func staticMetadata(_ ir: String) -> [String: StaticMetadata] {
        let sizes = ["ptr": 8, "i64": 8, "i32": 4, "i16": 2, "i8": 1]
        var types: [String: StaticMetadata] = [:]
        for line in ir.split(separator: "\n") where line.hasPrefix("@\"$s") && line.contains(" alias %swift.type, getelementptr inbounds (<{ ") {
            guard let name = IRModule.definedName(String(line)), name.hasSuffix("N"),
                  let open = line.range(of: "getelementptr inbounds (<{ "), let close = line.range(of: " }>, ptr @\"", range: open.upperBound..<line.endIndex),
                  let full = line[close.upperBound...].split(separator: "\"").first, full.hasSuffix("Mf"),
                  let point = line.range(of: "i32 0, i32 ", options: .backwards).flatMap({ Int(line[$0.upperBound...].prefix { $0.isNumber }) })
            else { continue }
            var offsets: [Int] = [], at = 0
            for type in line[open.upperBound..<close.lowerBound].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                offsets.append(at)
                at += sizes[type] ?? 0
            }
            guard point < offsets.count else { continue }
            types[String(full)] = StaticMetadata(metadata: name, addressPoint: offsets[point], offsets: offsets)
        }
        return types
    }

    struct Reference {
        var range: Range<String.Index>
        var metadata: String
        var delta: Int
    }

    /// The references to static metadata in one instruction that are its own operands.
    /// A reference inside a constant expression or an aggregate constant stays: an
    /// instruction cannot use a loaded value there.
    static func references(in line: String, types: [String: StaticMetadata]) -> [Reference] {
        var found: [Reference] = []
        var search = line.startIndex..<line.endIndex
        while let start = line.range(of: "@\"$s", range: search) {
            guard let end = line[start.upperBound...].firstIndex(of: "\"") else { break }
            let name = String(line[line.index(after: start.lowerBound)..<end].dropFirst())
            search = line.index(after: end)..<line.endIndex
            var reference: Reference?
            if name.hasSuffix("Mf"), let type = types[name],
               let gep = line.range(of: "getelementptr inbounds (<{ ", options: .backwards, range: line.startIndex..<start.lowerBound),
               line[gep.upperBound..<start.lowerBound].hasSuffix(" }>, ptr "),
               line[gep.upperBound..<start.lowerBound].range(of: "(") == nil,
               let tail = line[line.index(after: end)...].range(of: ")"),
               line[line.index(after: end)..<tail.lowerBound].hasPrefix(", i32 0, i32 "),
               let element = Int(line[line.index(after: end)..<tail.lowerBound].dropFirst(", i32 0, i32 ".count)),
               element < type.offsets.count {
                reference = Reference(range: gep.lowerBound..<tail.upperBound, metadata: type.metadata,
                                      delta: type.offsets[element] - type.addressPoint)
            } else if let type = types.values.first(where: { $0.metadata == name }) {
                reference = Reference(range: start.lowerBound..<line.index(after: end), metadata: type.metadata, delta: 0)
            }
            if let reference, isOperand(line, at: reference.range.lowerBound) { found.append(reference) }
        }
        return found
    }

    /// The constant at `index` is an instruction's operand: `ptr <constant>` with no
    /// enclosing aggregate (`{ … }`, `[ … ]`) or constant expression (`ptrtoint (…)`).
    static func isOperand(_ line: String, at index: String.Index) -> Bool {
        guard line[..<index].hasSuffix("ptr ") else { return false }
        var parens: [String.Index] = []
        var braces = 0
        for i in line[..<index].indices {
            switch line[i] {
            case "(": parens.append(i)
            case ")": _ = parens.popLast()
            case "{", "[": braces += 1
            case "}", "]": braces -= 1
            default: break
            }
        }
        guard braces == 0 else { return false }
        guard let open = parens.last else { return true }
        // The innermost open parenthesis is a call's argument list (`@f(`, `%f(`), not a
        // constant expression (`ptrtoint (`, `getelementptr inbounds (`, `bitcast (`).
        let before = line[..<open]
        return before.hasSuffix("\"") || before.last.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } == true
            && !["ptrtoint", "inttoptr", "bitcast", "getelementptr", "inbounds", "trunc", "sub", "add", "zext", "sext",
                 "select", "icmp", "addrspacecast", "nuw", "nsw"].contains(where: { before.hasSuffix(" " + $0) || before.hasSuffix($0) && before.count == $0.count })
    }
}
