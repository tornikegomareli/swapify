import Observation
@Observable class Model {
    var a = 1
    init() {}
    func step() {}
    func describe() -> String { "a=\(a)" }
}
