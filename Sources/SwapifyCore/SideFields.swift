import Foundation

/// Stored properties that an edit adds to a class the app was built with. Objects the
/// app made keep their layout. Each new field lives in side storage attached to the
/// object (Agent/SideFields.m), and the patch's IR is rewritten to reach it there:
///
/// - Field accesses. Code reaches a stored field of a class with one instruction,
///   `getelementptr inbounds %T…C, ptr %object, i32 0, i32 <element>`. The class's
///   struct type goes back to the built layout, accesses to existing fields get their
///   built element, and accesses to a new field call a helper that returns its address
///   in side storage, after storing its initial value there on first use.
/// - Vtable calls. Class metadata puts the field offsets before the vtable, so a new
///   stored property moves every method's slot. IR does not say which class a vtable
///   load is for, but the edit's SIL does (`class_method`): the two are matched in
///   order, function by function. A call to an existing member gets the member's slot
///   as built. A call to a new member calls the patch's implementation directly: no
///   class the app was built with can override a member it has never seen.
///
/// Whatever the rewrite cannot prove refuses the patch, and the edit needs a rebuild.
/// docs/research/spikes/06-side-fields has the derivation and the measurements.
enum SideFields {
    struct File {
        /// The file's IR as it was built. Nil for a file that is new since the build.
        var original: IRModule?
        /// The IR and the SIL of the edit.
        var ir: String
        var sil: String
    }

    enum Outcome: Equatable {
        /// The rewritten IR of each file, in order; the type descriptors (`$s…Mn`) of the
        /// classes whose layout the edit changed, which the agent's guard then skips; and the
        /// new fields in side storage, as `<$s…C>.<name>` (none when only methods were added).
        case rewritten([String], types: [String], fields: [String])
        /// `type` is the `$s…Mn` symbol of the class the rewrite could not keep valid.
        case refused(type: String, reason: String)
    }

    static func rewrite(_ files: [File]) -> Outcome {
        do {
            var rewriter = Rewriter(files)
            return try rewriter.run()
        } catch let refusal as Refusal {
            return .refused(type: refusal.type, reason: refusal.reason)
        } catch {
            return .refused(type: "", reason: "\(error)")
        }
    }

    /// A class of `classes` that a file other than `patched` declares a subclass of:
    /// such a subclass's own vtable slots move too, and its metadata is not in the patch.
    /// A text search, so a false match only costs a rebuild.
    static func subclassElsewhere(of classes: [String], sources: [String], patched: Set<String>) -> String? {
        for file in sources where !patched.contains(file) {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for name in classes {
                let pattern = "class\\s+\\w+[^{\\n]*:\\s*([\\w.]+\\.)?\(NSRegularExpression.escapedPattern(for: name))\\b"
                if text.range(of: pattern, options: .regularExpression) != nil { return name }
            }
        }
        return nil
    }

    struct Refusal: Error {
        var type: String
        var reason: String
    }
}

private struct Rewriter {
    let files: [SideFields.File]
    let edited: [IRModule]
    var texts: [String]

    init(_ files: [SideFields.File]) {
        self.files = files
        texts = files.map(\.ir)
        edited = files.map { IRModule($0.ir) }
    }

    /// A field after the rewrite: its element in the built layout, or a key into side storage.
    enum Target: Equatable {
        case element(Int)
        case side(String)
    }

    struct SideField {
        var owner: String  // the declaring class, `$s…C`
        var name: String
        var type: String   // the symbol of its mangled type name, `symbolic Si`
    }

    var before: [String: String] = [:]  // class struct type `%T…C` -> body, as built
    var after: [String: String] = [:]   // and in the edit
    var changed = Set<String>()         // struct types whose body the edit changed
    var plans: [String: [Int: Target]] = [:]  // struct type -> new element -> target
    var sideFields: [String: SideField] = [:]  // key `<owner>.<name>`
    var helperUses: [Int: Set<String>] = [:]   // file -> side fields it calls
    var reportedNames: [String: String] = [:]  // key -> the property a person wrote, for macro backing fields

    mutating func run() throws -> SideFields.Outcome {
        for original in files.compactMap(\.original) {
            before.merge(Self.structTypes(original.entities.map(\.text).joined())) { first, _ in first }
        }
        for text in texts { after.merge(Self.structTypes(text)) { first, _ in first } }
        changed = Set(after.filter { name, body in before[name].map { $0 != body } == true }.keys)
        // A struct type stops at the first field of a resilient type, so it can stay the same
        // while the fields change (a new `@Published` property). Field descriptors decide too.
        for (index, file) in files.enumerated() {
            guard let original = file.original else { continue }
            for entity in edited[index].entities where entity.kind == .global {
                guard let name = entity.name, name.hasPrefix("$s"), name.hasSuffix("CMF") else { continue }
                let mangled = String(name.dropLast(2))
                if let old = Self.ownFields(original, mangled), let new = Self.ownFields(edited[index], mangled),
                   old.map(\.name) != new.map(\.name) || old.map(\.type) != new.map(\.type) || old.map(\.flags) != new.map(\.flags) {
                    changed.insert(Self.llvmType(mangled))
                }
            }
        }
        var changedTypes = Set<String>()
        for llvm in changed.sorted() {
            _ = try plan(for: llvm)
            changedTypes.insert("$s" + llvm.dropFirst(2) + "Mn")
        }
        for llvm in changed {  // every module gets the built layout, after all plans read the edit's
            for index in texts.indices {
                texts[index] = texts[index].replacingOccurrences(of: "\(llvm) = type <{ \(after[llvm]!) }>",
                                                                 with: "\(llvm) = type <{ \(before[llvm]!) }>")
            }
        }
        for index in texts.indices { try rewriteFields(in: index) }
        let moved = try rewriteVtableCalls()
        changedTypes.formUnion(moved.map { $0 + "Mn" })
        guard !changedTypes.isEmpty else { throw SideFields.Refusal(type: "", reason: "no class layout changed") }
        try checkUnmatchedSlots(moved: moved)
        try checkNewSubclasses(of: Set(changedTypes.map { String($0.dropLast(2)) }))
        try checkStoredKeyPaths()
        try addHelpers()
        let fields = sideFields.map { key, field in "\(field.owner).\(reportedNames[key] ?? field.name)" }.sorted()
        return .rewritten(texts, types: changedTypes.sorted(), fields: fields)
    }

    // MARK: What the rewrite does not cover

    /// A changed class whose slots moved, but whose vtable calls nothing matched: its SIL
    /// table was not found. Its calls would keep the edit's slots.
    func checkUnmatchedSlots(moved: Set<String>) throws {
        for llvm in changed {
            let mangled = "$s" + llvm.dropFirst(2)
            guard !moved.contains(mangled), let file = definingFile(mangled), let original = files[file].original,
                  let old = Self.slots(original, mangled), let new = Self.slots(edited[file], mangled) else { continue }
            if new.contains(where: { old[$0.key] != $0.value }) {
                throw SideFields.Refusal(type: mangled + "Mn", reason: "its vtable calls could not be matched")
            }
        }
    }

    /// A class new in the patch whose superclass the edit changed: its own metadata has
    /// the edit's layout, which neither the built slots nor side storage describe.
    func checkNewSubclasses(of classes: Set<String>) throws {
        for (index, module) in edited.enumerated() {
            for entity in module.entities where entity.kind == .global {
                guard let name = entity.name, name.hasPrefix("$s"), name.hasSuffix("CMF") else { continue }
                let mangled = String(name.dropLast(2))
                guard files[index].original?[name] == nil else { continue }  // the class was built
                var ancestor = Self.superclass(module, mangled)
                while case .swift(let parent) = ancestor {
                    if classes.contains(parent) {
                        throw SideFields.Refusal(type: parent + "Mn", reason: "a new class in the patch subclasses it")
                    }
                    ancestor = definingFile(parent).map { Self.superclass(edited[$0], parent) } ?? .none
                }
            }
        }
    }

    /// A key path to a stored property of a class holds the field's offset inline
    /// (swift/ABI/KeyPath.h: component discriminator 3 in bits 24 to 30), which is the
    /// edit's layout. `@Observable` names computed properties, which are not affected.
    func checkStoredKeyPaths() throws {
        for text in texts {
            for line in text.split(separator: "\n") where line.hasPrefix("@keypath") && !line.hasPrefix("@keypath_once") {
                for element in IRModule.elements(of: String(line)) ?? [] where element.hasPrefix("i32 ") {
                    guard let header = Int64(element.dropFirst(4)), (header >> 24) & 0x7F == 3 else { continue }
                    throw SideFields.Refusal(type: "", reason: "a key path to a stored property of a class")
                }
            }
        }
    }

    // MARK: Struct types and field plans

    /// Every `%T…C = type <{ … }>` of a module: name -> body.
    static func structTypes(_ text: String) -> [String: String] {
        var types: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("%T") {
            guard let equals = line.range(of: " = type <{ "), line.hasSuffix(" }>"),
                  line[..<equals.lowerBound].hasSuffix("C") else { continue }
            types[String(line[..<equals.lowerBound])] = String(line[equals.upperBound..<line.index(line.endIndex, offsetBy: -3)])
        }
        return types
    }

    /// The file that defines class `mangled` (`$s…C`): the one with its field descriptor.
    func definingFile(_ mangled: String) -> Int? {
        edited.firstIndex { $0[mangled + "MF"] != nil }
    }

    static func llvmType(_ mangled: String) -> String { "%T" + mangled.dropFirst(2) }

    /// Struct element index of each stored field: element 0 is the object header (or the
    /// Objective-C superclass), `[N x i8]` is padding.
    static func fieldElements(_ body: String) -> [Int] {
        splitTopLevel(Substring(body)).enumerated().compactMap { index, element in
            index > 0 && !(element.hasPrefix("[") && element.hasSuffix(" x i8]")) ? index : nil
        }
    }

    /// The class's own stored fields, from its field descriptor: name, type symbol, and
    /// flags (`let` or `var`).
    static func ownFields(_ module: IRModule, _ mangled: String) -> [(name: String, type: String, flags: String)]? {
        guard let line = module[mangled + "MF"]?.text, let e = IRModule.elements(of: line), e.count >= 5 else { return nil }
        return stride(from: 5, to: e.count - 2, by: 3).map { i in
            let name = IRModule.relativeTarget(e[i + 2]).flatMap { module[$0]?.text }.flatMap(IRModule.cString) ?? "?"
            return (name, IRModule.relativeTarget(e[i + 1]) ?? String(e[i + 1]), String(e[i]))
        }
    }

    enum Superclass: Equatable {
        case none, objc, swift(String), foreign
    }

    static func superclass(_ module: IRModule, _ mangled: String) -> Superclass {
        guard let line = module[mangled + "MF"]?.text, let e = IRModule.elements(of: line), e.count >= 2,
              let target = IRModule.relativeTarget(e[1]) else { return .none }
        if target.hasPrefix("symbolic _____ ") { return .swift("$s" + target.dropFirst("symbolic _____ ".count)) }
        return target.hasPrefix("symbolic So") ? .objc : .foreign
    }

    /// New element -> target for the objects of class `llvm`, superclass fields first,
    /// as the struct type lays them out.
    mutating func plan(for llvm: String) throws -> [Int: Target] {
        if let known = plans[llvm] { return known }
        let mangled = "$s" + llvm.dropFirst(2)
        let refuse = { (reason: String) in SideFields.Refusal(type: mangled + "Mn", reason: reason) }
        guard let file = definingFile(mangled), let original = files[file].original else {
            throw refuse("its file is not in the patch")
        }
        let module = edited[file]
        guard let newBody = after[llvm], let oldBody = before[llvm],
              let newOwn = Self.ownFields(module, mangled), let oldOwn = Self.ownFields(original, mangled)
        else { throw refuse("its layout could not be read") }
        let newElements = Self.fieldElements(newBody), oldElements = Self.fieldElements(oldBody)

        // Superclass fields come first. They keep their places unless the superclass changed too.
        var result: [Int: Target] = [:]
        var inheritedNew = 0, inheritedOld = 0
        guard Self.superclass(module, mangled) == Self.superclass(original, mangled) else { throw refuse("its superclass changed") }
        switch Self.superclass(module, mangled) {
        case .none, .objc:
            break
        case .foreign:
            throw refuse("its superclass is in another module")
        case .swift(let parent):
            let parentType = Self.llvmType(parent)
            guard let parentNew = after[parentType] else { throw refuse("its superclass's layout is not in the patch") }
            inheritedNew = Self.fieldElements(parentNew).count
            if changed.contains(parentType) {
                result = try plan(for: parentType)
                inheritedOld = Self.fieldElements(before[parentType]!).count
            } else {
                inheritedOld = inheritedNew
                for element in newElements.prefix(inheritedNew) { result[element] = .element(element) }
            }
        }

        // The class's own fields, by name. The struct type stops at the first field of a
        // resilient type (an observation registrar); later fields use offset globals,
        // which the agent copies from the app, so a new field must come before them.
        let oldNames = oldOwn.map(\.name)
        guard newOwn.map(\.name).filter(oldNames.contains) == oldNames else { throw refuse("existing stored properties moved") }
        for old in oldOwn {
            guard let new = newOwn.first(where: { $0.name == old.name }) else { continue }
            if new.type != old.type { throw refuse("property '\(old.name)' changed type") }
            if new.flags != old.flags { throw refuse("property '\(old.name)' changed between let and var") }
        }
        let oldIndex = Dictionary(zip(oldNames, oldElements.dropFirst(inheritedOld)), uniquingKeysWith: { first, _ in first })
        let ownElements = Array(newElements.dropFirst(inheritedNew))
        for (position, field) in newOwn.enumerated() {
            let existed = oldNames.contains(field.name)
            guard position < ownElements.count else {
                if existed { continue }
                throw refuse("new property '\(field.name)' comes after a property of resilient type")
            }
            if existed {
                guard let old = oldIndex[field.name] else { throw refuse("property '\(field.name)' moved past a resilient one") }
                result[ownElements[position]] = .element(old)
            } else {
                let key = "\(mangled).\(field.name)"
                sideFields[key] = SideField(owner: mangled, name: field.name, type: field.type)
                result[ownElements[position]] = .side(key)
            }
        }
        plans[llvm] = result
        return result
    }

    // MARK: Field accesses

    mutating func rewriteFields(in index: Int) throws {
        guard !plans.isEmpty else { return }
        var lines = texts[index].components(separatedBy: "\n")
        var function = "", selfObject = ""
        var uses = Set<String>()
        for (number, line) in lines.enumerated() {
            if line.hasPrefix("define ") {
                function = IRModule.names(in: line).first ?? ""
                selfObject = line.range(of: "ptr swiftself ").map { String(line[$0.upperBound...].prefix { $0 != ")" && $0 != "," }) } ?? ""
            }
            guard line.contains("%T"), let type = plans.keys.first(where: { line.contains($0 + ",") || line.contains($0 + " ") })
            else { continue }
            if line.hasPrefix(type + " = type") { continue }
            guard let access = Self.fieldAccess(line), access.type == type, let target = plans[type]?[access.element] else {
                throw SideFields.Refusal(type: "$s" + type.dropFirst(2) + "Mn",
                                         reason: "an access to its fields the rewrite does not handle: \(line.trimmingCharacters(in: .whitespaces).prefix(120))")
            }
            switch target {
            case .element(let element):
                lines[number] = String(line.dropLast(access.elementText.count)) + "\(element)"
            case .side(let key):
                // A designated initializer stores the first value of its own object's fields.
                let initializing = function.hasSuffix("fc") && access.base == selfObject ? "true" : "false"
                lines[number] = "\(access.result) = call ptr @\"swapify.side.\(key)\"(ptr \(access.base), i1 \(initializing))"
                uses.insert(key)
            }
        }
        texts[index] = lines.joined(separator: "\n")
        helperUses[index, default: []].formUnion(uses)
    }

    /// `%r = getelementptr inbounds[ nuw] %T…C, ptr %base, i32 0, i32 N`.
    static func fieldAccess(_ line: String) -> (result: String, type: String, base: String, element: Int, elementText: String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 10, parts[1] == "=", parts[2] == "getelementptr", parts[3] == "inbounds" else { return nil }
        let rest = parts[4] == "nuw" ? parts.dropFirst(5) : parts.dropFirst(4)
        let r = Array(rest)
        guard r.count == 7, r[0].hasSuffix(","), r[1] == "ptr", r[2].hasSuffix(","), r[3] == "i32", r[4] == "0,", r[5] == "i32",
              let element = Int(r[6]) else { return nil }
        let indent = line.prefix { $0 == " " }
        return (String(indent + parts[0]), String(r[0].dropLast()), String(r[2].dropLast()), element, String(r[6]))
    }

    // MARK: Vtable calls

    struct VTable {
        var mangled: String
        var entries: [String: String]  // member key -> implementation symbol
    }

    /// `sil_vtable` blocks of every file: qualified class name -> table. A member is its
    /// name and its type, because overloads share a name.
    func vtables() -> [String: VTable] {
        var tables: [String: VTable] = [:]
        for file in files {
            var name: String?, entries: [String: String] = [:]
            for line in file.sil.split(separator: "\n") {
                if line.hasPrefix("sil_vtable ") {
                    name = line.dropLast(2).split(separator: " ").last.map(String.init)
                    entries = [:]
                } else if let current = name {
                    if line == "}" {
                        // The header has the bare name (`ViewModel`); members and the deallocator have the
                        // qualified one (`Feature.ViewModel`), as `class_method` does.
                        let suffix = ".deinit!deallocator"
                        let own = entries.first { key, _ in
                            key.hasSuffix(suffix) && key.dropFirst().dropLast(suffix.count).split(separator: ".").last.map(String.init) == current
                        }
                        if let own {
                            tables[String(own.key.dropFirst().dropLast(suffix.count))] = VTable(mangled: String(own.value.dropLast(2)), entries: entries)
                        }
                        name = nil
                    } else if let entry = Self.vtableEntry(line) {
                        entries[entry.key] = entry.implementation
                    }
                }
            }
        }
        return tables
    }

    /// `  #Counter.a!getter: (Counter) -> () -> Int : @$s…Sivg	// …` -> ("#Counter.a!getter : <type>", symbol).
    static func vtableEntry(_ line: Substring) -> (key: String, implementation: String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("#"), let colon = trimmed.range(of: ": ") else { return nil }
        let member = trimmed[..<colon.lowerBound]
        let rest = trimmed[colon.upperBound...]
        if rest.hasPrefix("@") {  // the deallocator has no type
            return (String(member), String(rest.dropFirst().prefix { !$0.isWhitespace }))
        }
        guard let at = rest.range(of: " : @", options: .backwards) else { return nil }
        return ("\(member) : \(rest[..<at.lowerBound])", String(rest[at.upperBound...].prefix { !$0.isWhitespace }))
    }

    /// SIL function symbol -> the members its `class_method` instructions name, in order.
    static func classMethodCalls(_ sil: String) -> [String: [String]] {
        var calls: [String: [String]] = [:]
        var function: String?
        for line in sil.split(separator: "\n") {
            if line.hasPrefix("sil "), line.hasSuffix("{"), let at = line.range(of: " @") {
                function = String(line[at.upperBound...].prefix { $0 != " " })
                calls[function!] = []
            } else if line.hasPrefix("} // end sil function") {
                function = nil
            } else if let function, let call = line.range(of: " = class_method %") {
                let operands = line[call.upperBound...]
                guard let member = operands.range(of: ", #"), let type = operands.range(of: " : ", range: member.upperBound..<operands.endIndex),
                      let end = operands.range(of: ", $@", range: type.upperBound..<operands.endIndex) else { continue }
                calls[function]!.append("#\(operands[member.upperBound..<type.lowerBound]) : \(operands[type.upperBound..<end.lowerBound])")
            }
        }
        return calls
    }

    static let sizes = ["ptr": 8, "i64": 8, "i32": 4, "i16": 2, "i8": 1]

    /// Implementation symbol -> vtable slot, in words from the address point of the class's
    /// full metadata (`$s…Mf`; the `$s…N` alias names the address point).
    static func slots(_ module: IRModule, _ mangled: String) -> [String: Int]? {
        guard let line = module[mangled + "Mf"]?.text, let alias = module[mangled + "N"]?.text,
              let point = alias.range(of: "i32 0, i32 ", options: .backwards).flatMap({ Int(alias[$0.upperBound...].prefix { $0.isNumber }) })
        else { return nil }
        let groups = braceGroups(line)
        guard groups.count == 2 else { return nil }
        let types = splitTopLevel(groups[0]), values = splitTopLevel(groups[1])
        guard types.count == values.count, point < types.count else { return nil }
        var offsets: [Int] = [], at = 0
        for type in types {
            guard let size = sizes[String(type)] else { return nil }
            offsets.append(at)
            at += size
        }
        var result: [String: Int] = [:]
        for (index, value) in values.enumerated() where types[index] == "ptr" && offsets[index] > offsets[point] {
            guard value.hasPrefix("ptr @"), (offsets[index] - offsets[point]) % 8 == 0,
                  let name = IRModule.names(in: String(value)).first, String(value) == "ptr " + (value.hasPrefix("ptr @\"") ? "@\"\(name)\"" : "@\(name)")
            else { continue }
            if result[name] == nil { result[name] = (offsets[index] - offsets[point]) / 8 }
        }
        return result
    }

    /// Rewrites vtable calls to classes whose slots the edit moved. Returns those classes.
    mutating func rewriteVtableCalls() throws -> Set<String> {
        let tables = vtables()
        var moved: [String: (old: [String: Int], new: [String: Int])] = [:]  // `$s…C` -> slots
        for table in tables.values where !table.mangled.isEmpty {
            guard let file = edited.firstIndex(where: { $0[table.mangled + "Mf"] != nil }), let original = files[file].original,
                  let old = Self.slots(original, table.mangled), let new = Self.slots(edited[file], table.mangled) else { continue }
            if new.contains(where: { old[$0.key] != $0.value }) { moved[table.mangled] = (old, new) }
        }
        guard !moved.isEmpty else { return [] }
        let movedNames = Set(tables.filter { moved[$0.value.mangled] != nil }.keys)

        for index in texts.indices {
            let calls = Self.classMethodCalls(files[index].sil)
            var lines = texts[index].components(separatedBy: "\n")
            var function: String?, sites: [(gep: Int, load: Int, slot: Int)] = [], isas = Set<Substring>()
            var declared = Set<String>()
            for (number, line) in lines.enumerated() {
                if line.hasPrefix("define ") {
                    function = IRModule.names(in: line).first
                    sites = []
                    isas = []
                } else if line == "}", let current = function {
                    let members = calls[current] ?? []
                    if members.contains(where: { movedNames.contains(Self.declaringClass($0)) }) {
                        guard members.count == sites.count else {
                            throw SideFields.Refusal(type: "", reason: "the vtable calls of \(current) do not match its SIL")
                        }
                        for (member, site) in zip(members, sites) {
                            guard let table = tables[Self.declaringClass(member)], let slots = moved[table.mangled] else { continue }
                            guard let implementation = table.entries[member], slots.new[implementation] == site.slot else {
                                throw SideFields.Refusal(type: table.mangled + "Mn", reason: "a vtable call in \(current) does not match the metadata")
                            }
                            if let old = slots.old[implementation] {
                                lines[site.gep] = String(lines[site.gep].dropLast(String(site.slot).count)) + "\(old)"
                            } else {
                                if tables.values.contains(where: { ($0.entries[member] ?? implementation) != implementation }) {
                                    throw SideFields.Refusal(type: table.mangled + "Mn", reason: "a class in the patch overrides its new member \(member)")
                                }
                                let result = lines[site.load].prefix { $0 != "=" }.dropLast()
                                lines[site.load] = "\(result) = getelementptr i8, ptr @\"\(implementation)\", i64 0"
                                if edited[index][implementation] == nil { declared.insert(implementation) }
                            }
                        }
                    }
                    function = nil
                } else if function != nil {
                    let parts = line.split(separator: " ")
                    // %isa = load ptr, ptr %object, align 8
                    if parts.count == 8, parts[1] == "=", parts[2] == "load", parts[3] == "ptr,", parts[4] == "ptr",
                       parts[6] == "align", parts[7] == "8" {
                        isas.insert(parts[0])
                    }
                    // %slot = getelementptr inbounds ptr, ptr %isa, i64 N, then %f = load ptr, ptr %slot, align 8, !invariant.load !M
                    if parts.count == 9, parts[1] == "=", parts[2] == "getelementptr", parts[3] == "inbounds", parts[4] == "ptr,",
                       parts[5] == "ptr", isas.contains(parts[6].dropLast()), parts[7] == "i64", let slot = Int(parts[8]),
                       number + 1 < lines.count {
                        let next = lines[number + 1].split(separator: " ")
                        if next.count >= 10, next[2] == "load", next[3] == "ptr,", next[4] == "ptr", next[5] == parts[0] + ",",
                           lines[number + 1].contains("!invariant.load") {
                            sites.append((number, number + 1, slot))
                        }
                    }
                }
            }
            for name in declared.sorted() { lines.append("declare hidden void @\"\(name)\"()") }
            texts[index] = lines.joined(separator: "\n")
        }
        return Set(moved.keys)
    }

    /// `#Counter.a!getter : <type>` -> `Counter`.
    static func declaringClass(_ member: String) -> String {
        let name = member.dropFirst().prefix { $0 != " " }
        guard let dot = name.lastIndex(of: ".") else { return String(name) }
        return String(name[..<dot])
    }

    // MARK: Helpers

    /// Defines each side field's helper in the file that defines its class, and declares
    /// it in the other files that call it.
    mutating func addHelpers() throws {
        var defined = Set<String>()
        for (key, field) in sideFields.sorted(by: { $0.key < $1.key }) {
            guard let file = definingFile(field.owner) else { continue }
            let (text, backs) = try helper(key: key, field: field, in: texts[file])
            texts[file] += text
            if let backs { reportedNames[key] = backs }
            defined.insert(key)
            helperUses[file, default: []].remove(key)
        }
        for index in texts.indices {
            if texts[index].contains("define hidden ptr @\"swapify.side.") {
                texts[index] += "declare ptr @SWPSideField(ptr, ptr, ptr, ptr, i32, ptr)\ndeclare void @SWPSideFieldReady(ptr, ptr)\n"
            }
            for key in (helperUses[index] ?? []).sorted() where !texts[index].contains("define hidden ptr @\"swapify.side.\(key)\"") {
                texts[index] += "declare hidden ptr @\"swapify.side.\(key)\"(ptr, i1)\n"
            }
        }
    }

    /// The helper that returns the address of a side field, storing its initial value
    /// there on first use.
    /// Also returns the property a macro's backing field (`_count`) backs, if it took that property's initial value.
    func helper(key: String, field: SideField, in text: String) throws -> (String, backs: String?) {
        let refuse = { (reason: String) in SideFields.Refusal(type: field.owner + "Mn", reason: reason) }
        // A property's initial value: `<owner><length><name>[private discriminator]<type>vpfi`.
        func initialValue(_ name: String) -> (returns: String, symbol: String, parameters: String, type: String)? {
            let prefix = "\(field.owner)\(name.utf8.count)\(name)"
            for line in text.split(separator: "\n") where line.hasPrefix("define ") && line.contains("@\"\(prefix)") {
                guard let open = line.range(of: "@\"\(prefix)"), let close = line.range(of: "\"(", range: open.upperBound..<line.endIndex),
                      line[open.lowerBound..<close.lowerBound].hasSuffix("vpfi"),
                      let swiftcc = line.range(of: "swiftcc ") else { continue }
                let symbol = String(line[line.index(after: open.lowerBound)..<close.lowerBound].dropFirst())
                var type = symbol.dropFirst(prefix.count).dropLast(4)  // between the name and `vpfi`
                if type.hasPrefix("33_"), let ll = type.range(of: "LL") { type = type[ll.upperBound...] }
                let parameters = line[close.upperBound...].prefix { $0 != ")" }
                return (String(line[swiftcc.upperBound..<open.lowerBound].dropLast()), symbol, String(parameters), String(type))
            }
            return nil
        }
        // Backing storage made by a macro (@Observable's `_count`) has no initial value of its
        // own; it takes its property's, if that has the same type.
        var initial = initialValue(field.name), backs: String?
        if initial == nil, field.name.hasPrefix("_"), let backed = initialValue(String(field.name.dropFirst())),
           field.type == "symbolic " + backed.type {
            initial = backed
            backs = String(field.name.dropFirst())
        }
        guard let initial else { throw refuse("new property '\(field.name)' has no initial value") }
        guard !initial.parameters.contains("sret"), initial.parameters.isEmpty else {
            throw refuse("the initial value of '\(field.name)' is returned indirectly")
        }
        let symbol = field.type.contains("\"") ? field.type : "\"\(field.type)\""
        // The storage key carries the type: a later edit that retypes the field gets new storage.
        let storageKey = "\(key)#\(field.type.replacingOccurrences(of: "\"", with: ""))"
        return ("""

        @"swapify.key.\(key)" = private unnamed_addr constant [\(storageKey.utf8.count + 1) x i8] c"\(storageKey)\\00"
        define hidden ptr @"swapify.side.\(key)"(ptr %object, i1 %initializing) {
        entry:
          %fresh = alloca i8, align 1
          %flag = zext i1 %initializing to i32
          %slot = call ptr @SWPSideField(ptr %object, ptr @"swapify.key.\(key)", ptr @\(symbol), ptr @"\(field.owner)Mn", i32 %flag, ptr %fresh)
          %freshByte = load i8, ptr %fresh, align 1
          %isFresh = icmp ne i8 %freshByte, 0
          br i1 %isFresh, label %initialize, label %done
        initialize:
          %value = call swiftcc \(initial.returns) @"\(initial.symbol)"()
          store \(initial.returns) %value, ptr %slot, align 8
          call void @SWPSideFieldReady(ptr %object, ptr @"swapify.key.\(key)")
          br label %done
        done:
          ret ptr %slot
        }

        """, backs)
    }
}

// MARK: Text

/// The top-level comma-separated parts of `text`.
private func splitTopLevel(_ text: Substring) -> [Substring] {
    var parts: [Substring] = [], depth = 0, start = text.startIndex
    for index in text.indices {
        switch text[index] {
        case "<", "{", "[", "(": depth += 1
        case ">", "}", "]", ")": depth -= 1
        case "," where depth == 0:
            parts.append(text[start..<index].drop { $0 == " " })
            start = text.index(after: index)
        default: break
        }
    }
    parts.append(text[start...].drop { $0 == " " })
    return parts.map { $0.reversed().drop { $0 == " " }.reversed() }.map { Substring(String($0)) }
}

/// The contents of the `<{ … }>` groups after ` = ` in a global's line: its type, then its value.
private func braceGroups(_ line: String) -> [Substring] {
    guard let equals = line.range(of: " = ") else { return [] }
    var groups: [Substring] = [], depth = 0, start = line.startIndex
    var index = equals.upperBound
    while index < line.endIndex, groups.count < 2 {
        let c = line[index]
        if c == "<", line[line.index(after: index)...].hasPrefix("{") {
            if depth == 0 { start = line.index(index, offsetBy: 3) }
            depth += 1
            index = line.index(after: index)
        } else if c == "}", line[line.index(after: index)...].hasPrefix(">") {
            depth -= 1
            if depth == 0 { groups.append(line[start..<line.index(before: index)]) }
            index = line.index(after: index)
        }
        index = line.index(after: index)
    }
    return groups
}
