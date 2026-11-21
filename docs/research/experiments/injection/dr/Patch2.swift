@_private(sourceFile: "Types.swift") import App
extension Greeter {
    @_dynamicReplacement(for: greet())
    func greet_v2() -> String { "v2 hi \(name)" }
}
@_dynamicReplacement(for: makeShape())
func makeShape_v2() -> some CustomStringConvertible { "now-a-String" }
extension Counter {
    @_dynamicReplacement(for: value())
    func value_v2() -> Int { 2 }
}
extension Base {
    @_dynamicReplacement(for: label())
    func label_v2() -> String { "base-v2" }
}
@_dynamicReplacement(for: globalComputed)
var globalComputed_v2: String { "computed-v2" }
