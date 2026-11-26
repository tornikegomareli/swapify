class Counter {
    var a = 1
    var count = 5
    var note = "a note long enough to live on the heap"
    init() {}
    func step() {
        count += 1
        note += "+"
    }
    func doubled() -> Int { count * 2 }
    func describe() -> String { "a=\(a) count=\(count) doubled=\(doubled()) note=\(note.count) chars" }
}

final class Special: Counter {
    var extra = 9
    override func describe() -> String { "special(extra=\(extra)) " + super.describe() }
}
