struct Greeter { var name = "world"; func greet() -> String { "v1 hello \(name)" } }
final class Counter { func value() -> Int { 1 } }
class Base { func label() -> String { "base-v1" } }
protocol P { func p() -> String }
extension Greeter: P { func p() -> String { "p-v1" } }
func genericCall<T: P>(_ t: T) -> String { t.p() }
