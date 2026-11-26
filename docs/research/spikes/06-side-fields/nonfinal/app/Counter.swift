class Counter {
    var a = 1
    init() {}
    func step() {}
    func describe() -> String { "a=\(a)" }
}

final class Special: Counter {
    var extra = 9
    override func describe() -> String { "special(extra=\(extra)) " + super.describe() }
}
