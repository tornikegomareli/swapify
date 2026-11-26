import Observation
@Observable final class Model {
    var a = 1
    init() {}
    func step() {}
    func describe() -> String { "a=\(a)" }
}
