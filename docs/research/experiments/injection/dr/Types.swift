struct Greeter {
    var name = "world"
    func greet() -> String { "v1 hello \(name)" }
}
func makeShape() -> some CustomStringConvertible { 1 }
final class Counter { func value() -> Int { 1 } }
class Base { func label() -> String { "base-v1" } }
var globalComputed: String { "computed-v1" }
