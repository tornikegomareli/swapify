final class Counter {
    var a = 1
    var count = 5
    var note = "a note long enough to live on the heap"
    init() {}
    func step() {
        count += 1
        note += "+"
    }
    func describe() -> String { "a=\(a) count=\(count) note=\(note)" }
}
