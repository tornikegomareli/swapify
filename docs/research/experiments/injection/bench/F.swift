struct Acc { var v = 0; mutating func add(_ x: Int) { v &+= x &* 3 } }
func step(_ a: inout Acc, _ i: Int) { a.add(i) }
