import Observation
@Observable final class Model {
    var a = 1
    var count = 5
    init() {}
    func step() { count += 1 }
    func describe() -> String { "a=\(a) count=\(count)" }
}
