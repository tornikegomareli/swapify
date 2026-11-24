import Foundation

// Old call sites. This file is never reloaded. Every check prints one `SPIKE <stage> <check>: <value>` line.

private struct Baseline {
    let secretType: ObjectIdentifier
    let boxMetadata: UnsafeRawPointer
    let itemMetadata: UnsafeRawPointer
    let token: ObjectIdentifier
}

private var baseline: Baseline!
private var oldClosure: (() -> Int)!
private var oldBox: Box!

func say(_ text: String) { spike_say(text) }

func checkAll(_ stage: String) {
    func line(_ name: String, _ value: Any) { say("\(stage) \(name): \(value)") }
    if baseline == nil {  // v1 values, read by the app's own code before any patch
        baseline = Baseline(secretType: ObjectIdentifier(type(of: makeSecret())), boxMetadata: boxMetadata(),
                            itemMetadata: itemMetadata(), token: tokenID())
        oldClosure = makeHelperClosure()
        oldBox = Box(value: 7)
    }
    line("version()", version())
    line("old Box describe() via vtable", oldBox.describe())
    line("Item greet() via witness table", (Item(name: "x") as Greeter).greet())
    line("old Box greet() via witness table", (oldBox as Greeter).greet())
    line("compute(3), calls fileprivate helper", compute(3))
    line("closure made by v1 calling helper(5)", oldClosure())
    line("secretText(), private type and its static let", secretText())
    let box = makeBox(9)
    line("Box made by current code has the app's class", ObjectIdentifier(type(of: box)) == ObjectIdentifier(Box.self))
    line("its describe(), reads value through the field offset", box.describe())
    line("Box metadata seen by current code is the app's", boxMetadata() == baseline.boxMetadata)
    line("Item metadata seen by current code is the app's", itemMetadata() == baseline.itemMetadata)
    line("private Secret boxed by current code has the app's type",
         ObjectIdentifier(type(of: makeSecret())) == baseline.secretType)
    line("static let token read by current code is the app's", tokenID() == baseline.token)
    Store.hits += 1
    line("static var hits read by current code", "\(hitsSeen()) (app reads \(Store.hits))")
    line("Item boxed by current code as? Greeter", (makeItem("z") as Any) as? Greeter != nil)
    line("Box made by current code as? Greeter", (makeBox(1) as AnyObject) as? Greeter != nil)
    line("existential made by current code, greet()", greeterOfItem().greet())
    line("makeItems() [Item] built by current code", makeItems().map { $0.greet() })
    line("probeSummary(): key path, generic type, SwiftUI body", probeSummary())
}

func runBindTest() {
    checkAll("v1")
    for version in ["v2", "v3"] {
        let path = NSTemporaryDirectory() + "patch_\(version).dylib"
        guard spike_load_patch(path) == 0 else { return }
        checkAll(version)
    }
}
