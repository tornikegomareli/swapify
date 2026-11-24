import Foundation

struct Point {
    var x: Int
    let label: String
    func describe() -> String { "\(label) \(x)" }
}

class Shape {
    var sides = 3
    var stamp = Date(timeIntervalSince1970: 0)
    func area() -> Double { 0 }
    func perimeter() -> Double { 0 }
}

enum Mode {
    case on
    case off(Int)
}

private struct Secret {
    var code = 7
}

func secretCode() -> Int { Secret().code }
