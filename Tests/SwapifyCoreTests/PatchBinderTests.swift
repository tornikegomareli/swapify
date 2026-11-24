import Foundation
import Testing
@testable import SwapifyCore

/// A patch of a file that defines `Foo`, which the app has and exports, and `Bar`,
/// which is new in the edit. Shaped like Swift's IR, reduced to what the binder reads.
@Suite struct PatchBinderTests {
    static let patch = #"""
        %swift.type = type { i64 }
        @"$s1A3FooVMf" = internal constant <{ ptr, ptr, i64, ptr }> <{ ptr null, ptr @"$sytWV", i64 512, ptr @"$s1A3FooVMn" }>, align 8
        @"$s1A3FooVN" = alias %swift.type, getelementptr inbounds (<{ ptr, ptr, i64, ptr }>, ptr @"$s1A3FooVMf", i32 0, i32 2)
        @"$s1A3FooVMn" = constant <{ i32, i32 }> <{ i32 81, i32 0 }>, section "__TEXT,__constg_swiftt", align 4
        @"$s1A3FooVHn" = private constant i32 trunc (i64 sub (i64 ptrtoint (ptr @"$s1A3FooVMn" to i64), i64 ptrtoint (ptr @"$s1A3FooVHn" to i64)) to i32), section "__TEXT, __swift5_types, regular", align 4
        @"$s1A3BarVMn" = constant <{ i32, i32 }> <{ i32 81, i32 0 }>, section "__TEXT,__constg_swiftt", align 4
        @"$s1A3BarVHn" = private constant i32 trunc (i64 sub (i64 ptrtoint (ptr @"$s1A3BarVMn" to i64), i64 ptrtoint (ptr @"$s1A3BarVHn" to i64)) to i32), section "__TEXT, __swift5_types, regular", align 4
        @"symbolic _____ 1A3FooV" = linkonce_odr hidden constant <{ i8, i32, i8 }> <{ i8 1, i32 trunc (i64 sub (i64 ptrtoint (ptr @"$s1A3FooVMn" to i64), i64 ptrtoint (ptr getelementptr inbounds (<{ i8, i32, i8 }>, ptr @"symbolic _____ 1A3FooV", i32 0, i32 1) to i64)) to i32), i8 0 }>, section "__TEXT,__swift5_typeref, regular", align 2
        @"$s1A3runyyFTX" = global { ptr, ptr } { ptr @"$s1A3runyyF", ptr null }, align 8
        @llvm.used = appending global [3 x ptr] [ptr @"$s1A3FooVHn", ptr @"$s1A3BarVHn", ptr @"$s1A3runyyFTX"], section "llvm.metadata"

        define swiftcc { ptr, i64 } @"$s1A3FooVMa"(i64 %0) #0 {
        entry:
          ret { ptr, i64 } { ptr getelementptr inbounds (<{ ptr, ptr, i64, ptr }>, ptr @"$s1A3FooVMf", i32 0, i32 2), i64 0 }
        }

        define swiftcc ptr @"$s1A3runyyF"() #0 {
        entry:
          %0 = load ptr, ptr @"symbolic _____ 1A3FooV", align 8
          ret ptr getelementptr inbounds (<{ ptr, ptr, i64, ptr }>, ptr @"$s1A3FooVMf", i32 0, i32 2)
        }

        attributes #0 = { noinline }

        """#
    static let exports: Set<String> = ["$s1A3FooVMn", "$s1A3FooVN", "$s1A3FooVMa", "$s1A3runyyF", "$s1A3runyyFTX"]

    let lines: [String]

    init() throws {
        lines = try PatchBinder.bind(Self.patch, exports: Self.exports).ir.split(separator: "\n").map(String.init)
    }

    func line(defining name: String) -> String? {
        lines.first { $0.hasPrefix("@\"\(name)\" =") || $0.contains("@\"\(name)\"(") }
    }

    @Test func importsWhatTheAppExports() {
        #expect(line(defining: "$s1A3FooVMn") == #"@"$s1A3FooVMn" = external global i8, align 8"#)
        #expect(line(defining: "$s1A3FooVN") == #"@"$s1A3FooVN" = external global i8, align 8"#)
        #expect(line(defining: "$s1A3FooVMa") == #"declare swiftcc { ptr, i64 } @"$s1A3FooVMa"(i64) #0"#)
    }

    @Test func newCodeUsesTheAppsMetadata() {
        #expect(lines.contains(#"  ret ptr @"$s1A3FooVN""#))
        #expect(!lines.contains { $0.contains("$s1A3FooVMf") })
    }

    @Test func keepsBodiesAndChainRoots() {
        #expect(lines.contains(#"define swiftcc ptr @"$s1A3runyyF"() #0 {"#))
        #expect(line(defining: "$s1A3runyyFTX") != nil)
    }

    @Test func keepsTheRecordsOfNewTypesOnly() {
        #expect(line(defining: "$s1A3BarVHn") != nil)
        #expect(line(defining: "$s1A3BarVMn") != nil)
        #expect(line(defining: "$s1A3FooVHn") == nil)
        #expect(lines.contains(#"@llvm.used = appending global [2 x ptr] [ptr @"$s1A3BarVHn", ptr @"$s1A3runyyFTX"], section "llvm.metadata""#))
    }

    @Test func makesSymbolicReferencesToTheAppIndirect() throws {
        let symbolic = try #require(line(defining: "symbolic _____ 1A3FooV"))
        #expect(symbolic.contains(#"<{ i8 2, i32 trunc (i64 sub (i64 ptrtoint (ptr @"got.$s1A3FooVMn" to i64)"#))
        #expect(lines.contains(#"@"got.$s1A3FooVMn" = private unnamed_addr constant ptr @"$s1A3FooVMn""#))
    }

    @Test func refusesARelativeReferenceIntoTheApp() {
        let patch = Self.patch.replacingOccurrences(of: "ptr @\"$s1A3BarVMn\" to i64), i64 ptrtoint (ptr @\"$s1A3BarVHn\"",
                                                    with: "ptr @\"$s1A3FooVMn\" to i64), i64 ptrtoint (ptr @\"$s1A3BarVHn\"")
        #expect(throws: SwapifyError.self) { try PatchBinder.bind(patch, exports: Self.exports) }
    }

    @Test func declarationDropsLinkageAndParameterNames() {
        #expect(PatchBinder.declaration("define internal swiftcc void @f(i64 %0, ptr swiftself %self) #2 {\n")
                == "declare swiftcc void @f(i64, ptr swiftself) #2\n")
    }

    @Test func readsDyldInfoExports() {
        let output = """
            /x/App.debug.dylib [arm64]:
                -exports:
                    offset      symbol
                    0x00007ED4  _$s3App4mainyyF
                    0x00010220  _$s3App4mainyyFTX
            """
        #expect(PatchBinder.exports(fromDyldInfo: output) == ["$s3App4mainyyF", "$s3App4mainyyFTX"])
    }
}
