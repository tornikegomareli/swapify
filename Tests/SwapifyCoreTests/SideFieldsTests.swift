import Foundation
import Testing
@testable import SwapifyCore

/// The iOS simulator SDK, which simulator patches compile against.
private let simulatorSDK: String? = {
    let result = try? Shell.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}()

/// SideFields on small modules compiled for the iOS simulator with the real toolchain.
/// Each case compiles its files as built and as edited, rewrites the edit, and compiles
/// the rewritten IR with clang. docs/research/spikes/06-side-fields runs the same
/// rewrites and checks the objects at run time; scripts/e2e.py checks them in an app.
@Suite(.enabled(if: simulatorSDK != nil, "needs Xcode with the iOS simulator SDK"))
struct SideFieldsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swapify-side-\(UUID().uuidString)")

    struct Result {
        var outcome: SideFields.Outcome
        /// The rewritten IR by file name, after it compiled with clang.
        var ir: [String: String] = [:]
    }

    /// Compiles every file of `edited` as it is there and as it is in `built` (when there),
    /// rewrites the edit, and compiles each rewritten module to an object.
    func rewrite(built: [String: String], edited: [String: String]) throws -> Result {
        let app = root.appendingPathComponent("App"), copies = root.appendingPathComponent("built")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let frontend = try Shell.run(["xcrun", "--find", "swift-frontend"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = edited.keys.sorted()
        for name in names { try edited[name]!.write(to: app.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        for (name, source) in built { try source.write(to: copies.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let paths = names.map { app.appendingPathComponent($0).path }

        let files = try names.map { name -> SideFields.File in
            let file = app.appendingPathComponent(name).path
            let command = [frontend, "-frontend", "-c", "-primary-file", file] + paths.filter { $0 != file }
                + ["-module-name", "App", "-target", "arm64-apple-ios27.0-simulator", "-sdk", simulatorSDK!,
                   "-enable-implicit-dynamic", "-Onone", "-parse-as-library",
                   "-plugin-path", URL(fileURLWithPath: frontend).deletingLastPathComponent().deletingLastPathComponent().path + "/lib/swift/host/plugins"]
            let stem = root.appendingPathComponent(name).path
            for step in [FrontendCommand.patchIR(command, primary: file, output: stem + ".ll"),
                         FrontendCommand.patchSIL(command, primary: file, output: stem + ".sil")] {
                let run = try Shell.run(step)
                try #require(run.succeeded, "\(run.output)")
            }
            var original: IRModule?
            if built[name] != nil {
                let copy = copies.appendingPathComponent(name).path
                let run = try Shell.run(FrontendCommand.patchIR(command, primary: file, source: copy, output: stem + ".built.ll"))
                try #require(run.succeeded, "\(run.output)")
                original = IRModule(try String(contentsOfFile: stem + ".built.ll", encoding: .utf8))
            }
            return SideFields.File(original: original, ir: try String(contentsOfFile: stem + ".ll", encoding: .utf8),
                                   sil: try String(contentsOfFile: stem + ".sil", encoding: .utf8))
        }

        var result = Result(outcome: SideFields.rewrite(files))
        guard case .rewritten(let texts, _, _) = result.outcome else { return result }
        for (name, text) in zip(names, texts) {
            let ir = root.appendingPathComponent(name + ".side.ll").path
            try text.write(toFile: ir, atomically: true, encoding: .utf8)
            let command = [frontend, "-target", "arm64-apple-ios27.0-simulator"]
            let object = try Shell.run(FrontendCommand.compileIR(command, ir: ir, output: ir + ".o"))
            #expect(object.succeeded, "\(name): \(object.output.prefix(1500))")
            result.ir[name] = text
        }
        return result
    }

    static let counter = """
        class Counter {
            var a = 1
            init() {}
            func step() {}
            func describe() -> String { "a=\\(a)" }
        }

        final class Special: Counter {
            var extra = 9
            override func describe() -> String { "special(\\(extra)) " + super.describe() }
        }

        """

    @Test func nonFinalClassAndItsSubclassKeepTheirLayout() throws {
        let edited = Self.counter
            .replacingOccurrences(of: "    var a = 1\n    init() {}", with: "    var a = 1\n    var count = 5\n    var note = \"a note long enough for the heap\"\n    init() {}")
            .replacingOccurrences(of: "    func step() {}", with: "    func step() {\n        count += 1\n        note += \"+\"\n    }\n    func doubled() -> Int { count * 2 }")
            .replacingOccurrences(of: "\"a=\\(a)\"", with: "\"a=\\(a) \\(count) \\(doubled()) \\(note)\"")
        let result = try rewrite(built: ["Counter.swift": Self.counter], edited: ["Counter.swift": edited])
        guard case .rewritten(_, let types, let fields) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(types == ["$s3App7CounterCMn", "$s3App7SpecialCMn"])
        #expect(fields == ["$s3App7CounterC.count", "$s3App7CounterC.note"])
        let ir = try #require(result.ir["Counter.swift"])
        #expect(ir.contains("%T3App7CounterC = type <{ %swift.refcounted, %TSi }>"))
        #expect(ir.contains("define hidden ptr @\"swapify.side.$s3App7CounterC.count\""))
        #expect(ir.contains("define hidden ptr @\"swapify.side.$s3App7CounterC.note\""))
        #expect(ir.contains("call ptr @\"swapify.side.$s3App7CounterC.count\"(ptr %0, i1 true)"))  // the designated initializer
        #expect(ir.contains("getelementptr i8, ptr @\"$s3App7CounterC5countSivg\", i64 0"))  // a new member, called directly
        #expect(ir.contains("getelementptr i8, ptr @\"$s3App7CounterC7doubledSiyF\", i64 0"))
    }

    @Test func observableClassUsedFromAnotherFile() throws {
        let model = "import Observation\n\n@Observable class Model {\n    var a = 1\n}\n"
        let view = "func show(_ model: Model) -> String { \"\\(model.a)\" }\n"
        let result = try rewrite(
            built: ["Model.swift": model, "View.swift": view],
            edited: ["Model.swift": model.replacingOccurrences(of: "    var a = 1\n", with: "    var a = 1\n    var count = 5\n"),
                     "View.swift": "func show(_ model: Model) -> String { \"\\(model.a) \\(model.count)\" }\n"])
        guard case .rewritten(_, let types, let fields) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(types == ["$s3App5ModelCMn"])
        #expect(fields == ["$s3App5ModelC.count"])  // the property, not the macro's backing field
        #expect(result.ir["Model.swift"]?.contains("define hidden ptr @\"swapify.side.$s3App5ModelC._count\"") == true)
        // The view reads `count` through the vtable as edited; it now calls the getter directly.
        let view2 = try #require(result.ir["View.swift"])
        #expect(view2.contains("getelementptr i8, ptr @\"$s3App5ModelC5countSivg\", i64 0"))
        #expect(view2.contains("declare hidden void @\"$s3App5ModelC5countSivg\"()"))
    }

    @Test func aMethodAddedToANonFinalClassIsCalledDirectly() throws {
        let edited = Self.counter
            .replacingOccurrences(of: "    func step() {}", with: "    func reset() { a = 0 }\n    func step() { reset() }")
        let result = try rewrite(built: ["Counter.swift": Self.counter], edited: ["Counter.swift": edited])
        guard case .rewritten(_, let types, let fields) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(types == ["$s3App7CounterCMn", "$s3App7SpecialCMn"])
        #expect(fields.isEmpty)
        #expect(result.ir["Counter.swift"]?.contains("getelementptr i8, ptr @\"$s3App7CounterC5resetyyF\", i64 0") == true)
    }

    /// The body of the function whose name starts with `prefix`.
    func body(_ ir: String, _ prefix: String) -> String {
        guard let start = ir.components(separatedBy: "\n").firstIndex(where: { $0.hasPrefix("define ") && $0.contains("@\"\(prefix)") })
        else { return "" }
        let lines = ir.components(separatedBy: "\n")[start...]
        return lines.prefix { $0 != "}" }.joined(separator: "\n")
    }

    @Test func aClassNestedInAnotherTypeGetsItsVtableCallsRewritten() throws {
        let built = "enum Feature {\n    class ViewModel {\n        var a = 1\n        init() {}\n        func f() -> Int { a }\n    }\n}\n"
        let edited = built.replacingOccurrences(of: "        var a = 1\n", with: "        var a = 1\n        var count = 5\n")
            .replacingOccurrences(of: "func f() -> Int { a }", with: "func f() -> Int { a + count }")
        let result = try rewrite(built: ["Feature.swift": built], edited: ["Feature.swift": edited])
        guard case .rewritten(_, let types, _) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(types == ["$s3App7FeatureO9ViewModelCMn"])
        #expect(result.ir["Feature.swift"]?.contains("getelementptr i8, ptr @\"$s3App7FeatureO9ViewModelC5countSivg\", i64 0") == true)
    }

    @Test func onlyTheInitializersOwnObjectStoresItsFirstValue() throws {
        let built = "final class Box {\n    var a = 1\n    init() {}\n}\n\nfinal class Row {\n    let label: Int\n    init(box: Box) { label = box.a }\n}\n"
        let edited = built.replacingOccurrences(of: "    var a = 1\n", with: "    var a = 1\n    var b = 2\n")
            .replacingOccurrences(of: "label = box.a", with: "label = box.b")
        let result = try rewrite(built: ["Box.swift": built], edited: ["Box.swift": edited])
        let ir = try #require(result.ir["Box.swift"])
        // Box's initializer stores b of its own object; Row's reads b of a Box that may predate the patch.
        #expect(body(ir, "$s3App3BoxCACycfc").contains("@\"swapify.side.$s3App3BoxC.b\"(ptr %0, i1 true)"))
        let row = body(ir, "$s3App3RowC3boxAcA3BoxC_tcfc")
        #expect(row.contains("@\"swapify.side.$s3App3BoxC.b\"") && row.contains("i1 false)") && !row.contains("i1 true)"))
        // The storage key carries the field's type, so retyping it later gets new storage.
        #expect(ir.contains("c\"$s3App3BoxC.b#symbolic Si\\00\""))
        #expect(ir.contains("call void @SWPSideFieldReady(ptr %object"))
    }

    @Test func aNewSubclassOfAChangedClassIsRefused() throws {
        let edited = Self.counter
            .replacingOccurrences(of: "    var a = 1\n    init() {}", with: "    var a = 1\n    var count = 5\n    init() {}")
            + "final class Fancy: Counter {}\n"
        let result = try rewrite(built: ["Counter.swift": Self.counter], edited: ["Counter.swift": edited])
        #expect(result.outcome == .refused(type: "$s3App7CounterCMn", reason: "a new class in the patch subclasses it"))
    }

    @Test func aKeyPathToAStoredPropertyIsRefused() throws {
        let built = "final class Box {\n    var a = 1\n    init() {}\n}\n"
        let edited = "final class Box {\n    var a = 1\n    var count = 5\n    init() {}\n}\n"
            + "func path() -> ReferenceWritableKeyPath<Box, Int> { \\Box.count }\n"
        let result = try rewrite(built: ["Box.swift": built], edited: ["Box.swift": edited])
        #expect(result.outcome == .refused(type: "", reason: "a key path to a stored property of a class"))
    }

    @Test func aChangedSuperclassIsRefused() throws {
        let bases = "class BaseA {\n    var x = 1\n    init() {}\n}\n\nclass BaseB {\n    var z = \"z\"\n    init() {}\n}\n\n"
        let result = try rewrite(built: ["Model.swift": bases + "class Model: BaseA {\n    var m = 1\n}\n"],
                                 edited: ["Model.swift": bases + "class Model: BaseB {\n    var m = 1\n}\n"])
        #expect(result.outcome == .refused(type: "$s3App5ModelCMn", reason: "its superclass changed"))
    }

    @Test func aStructChangeIsRefused() throws {
        let built = "struct Point {\n    var x = 1\n}\n"
        let result = try rewrite(built: ["Point.swift": built],
                                 edited: ["Point.swift": "struct Point {\n    var x = 1\n    var y = 2\n}\n"])
        #expect(result.outcome == .refused(type: "", reason: "no class layout changed"))
    }

    @Test func aNewPropertyWithoutAnInitialValueIsRefused() throws {
        let built = "final class Box {\n    var a = 1\n    init() {}\n}\n"
        let result = try rewrite(built: ["Box.swift": built],
                                 edited: ["Box.swift": "final class Box {\n    var a = 1\n    var b: Int\n    init() { b = 2 }\n}\n"])
        #expect(result.outcome == .refused(type: "$s3App3BoxCMn", reason: "new property 'b' has no initial value"))
    }

    @Test func aNewMemberOverriddenInThePatchIsRefused() throws {
        let edited = Self.counter
            .replacingOccurrences(of: "    var a = 1\n    init() {}", with: "    var a = 1\n    var count = 5\n    init() {}")
            .replacingOccurrences(of: "\"a=\\(a)\"", with: "\"a=\\(a) \\(count)\"")
            .replacingOccurrences(of: "    var extra = 9\n", with: "    var extra = 9\n    override var count: Int { get { 1 } set {} }\n")
        let result = try rewrite(built: ["Counter.swift": Self.counter], edited: ["Counter.swift": edited])
        guard case .refused(let type, let reason) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(type == "$s3App7CounterCMn")
        #expect(reason.hasPrefix("a class in the patch overrides its new member #Counter.count!getter"))
    }

    @Test func aPropertyWrapperWithAnotherStorageTypeIsRefused() throws {
        let built = "import Combine\n\nfinal class Store: ObservableObject {\n    @Published var a = 1\n}\n"
        let result = try rewrite(built: ["Store.swift": built],
                                 edited: ["Store.swift": built.replacingOccurrences(of: "    @Published var a = 1\n",
                                                                                    with: "    @Published var a = 1\n    @Published var b = 2\n")])
        // `Published<Int>` is resilient, so the struct type covers none of the fields: the new
        // `_b` would sit where only offset globals reach it.
        #expect(result.outcome == .refused(type: "$s3App5StoreCMn", reason: "its layout could not be read"))
    }

    @Test func anExistingPropertyThatChangesTypeIsRefused() throws {
        let built = "final class Box {\n    var a = 1\n    init() {}\n}\n"
        let result = try rewrite(built: ["Box.swift": built],
                                 edited: ["Box.swift": "final class Box {\n    var a = \"one\"\n    var b = 2\n    init() {}\n}\n"])
        #expect(result.outcome == .refused(type: "$s3App3BoxCMn", reason: "property 'a' changed type"))
    }

    @Test func findsASubclassInAnotherFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("Other.swift").path
        try "final class Fancy: Counter {}\n".write(toFile: other, atomically: true, encoding: .utf8)
        #expect(SideFields.subclassElsewhere(of: ["Counter"], sources: [other], patched: []) == "Counter")
        #expect(SideFields.subclassElsewhere(of: ["Count"], sources: [other], patched: []) == nil)
        #expect(SideFields.subclassElsewhere(of: ["Counter"], sources: [other], patched: [other]) == nil)
    }
}
