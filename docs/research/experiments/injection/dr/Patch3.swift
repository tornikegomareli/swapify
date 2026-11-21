@_private(sourceFile: "Types.swift") import App
extension Greeter {
    @_dynamicReplacement(for: greet())
    func greet_v3() -> String { "v3 hi \(name)" }
}
@_dynamicReplacement(for: makeShape())
func makeShape_v3() -> some CustomStringConvertible { "now-a-String" }
extension Counter {
    @_dynamicReplacement(for: value())
    func value_v3() -> Int { 3 }
}
extension Base {
    @_dynamicReplacement(for: label())
    func label_v3() -> String { "base-v3" }
}
@_dynamicReplacement(for: globalComputed)
var globalComputed_v3: String { "computed-v3" }
