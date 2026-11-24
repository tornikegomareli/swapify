import Foundation

// v3 of App/Model.swift: only function bodies and strings differ.

class Box {
    var stamp = Date(timeIntervalSince1970: 0)  // Date is resilient, so `value`'s offset is a global ($s…Wvd)
    var value: Int
    init(value: Int) { self.value = value }
    func describe() -> String { "v3 box \(value)" }
}

struct Item: Greeter {
    let name: String
    func greet() -> String { "v3 hello \(name)" }
}

extension Box: Greeter {
    func greet() -> String { "v3 box \(value) greets" }
}

final class Token {}

enum Store {
    static let token = Token()
    static var hits = 0
}

private struct Secret {
    static let salt = "salt-v3"  // the app's storage keeps salt1
    func mix(_ text: String) -> String { "v3 \(text)+\(Secret.salt)" }
}

fileprivate func helper(_ x: Int) -> Int { x * 1000 }

func version() -> String { "v3" }
func compute(_ x: Int) -> Int { helper(x) + 1 }
func secretText() -> String { Secret().mix("abc") }
func makeHelperClosure() -> () -> Int { { helper(5) } }
func makeBox(_ value: Int) -> Box { Box(value: value) }
func makeItem(_ name: String) -> Item { Item(name: name) }
func makeSecret() -> Any { Secret() }
func makeItems() -> [Item] { [Item(name: "a"), Item(name: "b")] }
func tokenID() -> ObjectIdentifier { ObjectIdentifier(Store.token) }
func hitsSeen() -> Int { Store.hits }
func boxMetadata() -> UnsafeRawPointer { unsafeBitCast(Box.self as AnyClass, to: UnsafeRawPointer.self) }
func itemMetadata() -> UnsafeRawPointer { unsafeBitCast(Item.self as Any.Type, to: UnsafeRawPointer.self) }
func greeterOfItem() -> Greeter { Item(name: "w") }
