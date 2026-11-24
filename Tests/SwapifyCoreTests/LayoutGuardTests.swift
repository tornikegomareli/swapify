import Foundation
import Testing
@testable import SwapifyCore

/// Fixtures/LayoutGuard/<case>/Types.swift is one edit of base/Types.swift. <case>.ll is its
/// IR, compiled as a device build compiles it, then reduced to the descriptor and string lines:
///   xcrun swiftc -frontend -emit-ir -primary-file <case>/Types.swift -module-name Fixture
///     -enable-implicit-dynamic -enable-testing -enable-private-imports -parse-as-library
///     -target arm64-apple-ios27.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -o x.ll
///   grep -E '^@("\$s[^"]*(Mn|MF)"|"symbolic |\.str|[0-9]+ |"got\.)' x.ll > <case>.ll
@Suite struct LayoutGuardTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LayoutGuard")

    func change(_ edit: String) throws -> LayoutGuard.Change? {
        func module(_ name: String) throws -> IRModule {
            IRModule(try String(contentsOf: Self.fixtures.appendingPathComponent(name + ".ll"), encoding: .utf8))
        }
        return LayoutGuard.change(from: try module("base"), to: try module(edit))
    }

    @Test func bodyOnlyEditPasses() throws {
        #expect(try change("body") == nil)
    }

    @Test func newTypePasses() throws {
        #expect(try change("newtype") == nil)
    }

    @Test func addedStoredPropertyIsRefused() throws {
        #expect(try change("added") == .init(type: "$s7Fixture5PointVMn", reason: "stored properties changed"))
    }

    @Test func renamedStoredPropertyIsRefused() throws {
        #expect(try change("renamed") == .init(type: "$s7Fixture5PointVMn", reason: "property 'x' renamed or moved"))
    }

    @Test func retypedStoredPropertyIsRefused() throws {
        #expect(try change("retyped") == .init(type: "$s7Fixture5PointVMn", reason: "property 'x' changed type"))
    }

    @Test func letToVarIsRefused() throws {
        #expect(try change("letvar")
                == .init(type: "$s7Fixture5PointVMn", reason: "property 'label' changed between let and var"))
    }

    @Test func newClassMethodIsRefused() throws {
        #expect(try change("method") == .init(type: "$s7Fixture5ShapeCMn", reason: "methods added or removed"))
    }

    @Test func newEnumCaseIsRefused() throws {
        #expect(try change("cases") == .init(type: "$s7Fixture4ModeOMn", reason: "cases changed"))
    }

    @Test func privateTypesAreGuardedToo() throws {
        let change = try #require(try change("privatefield"))
        #expect(change.type.contains("Secret"))
        #expect(change.reason == "stored properties changed")
    }
}
