struct Greeter { var name = "world"; func greet() -> String { "v2 HI \(name)" } }
final class Counter { func value() -> Int { 2 } }
class Base { func label() -> String { "base-v2" } }
protocol P { func p() -> String }
extension Greeter: P { func p() -> String { "p-v2" } }
func genericCall<T: P>(_ t: T) -> String { t.p() }
