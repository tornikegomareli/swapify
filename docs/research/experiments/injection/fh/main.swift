import Foundation
@_silgen_name("rebind_one") func rebind_one(_ name: UnsafePointer<CChar>, _ repl: UnsafeMutableRawPointer) -> Int32
func report(_ tag: String) { print("[\(tag)] greet=\(Greeter().greet()) counter=\(Counter().value()) base=\(Base().label()) witness=\((Greeter() as P).p()) generic=\(genericCall(Greeter()))"); fflush(stdout) }
report("start")
let symbols = ["$s3App7GreeterV5greetSSyF", "$s3App7CounterC5valueSiyF", "$s3App4BaseC5labelSSyF", "$s3App7GreeterV1pSSyF"]
let main = dlopen(nil, RTLD_NOW)
for path in CommandLine.arguments.dropFirst() {
    guard let h = dlopen(path, RTLD_NOW) else { print("dlopen failed: \(String(cString: dlerror()))"); continue }
    for s in symbols { if let p = dlsym(h, s) { _ = rebind_one(s, p) } }
    report("after GOT rebind")
    // Minimal vtable patch: overwrite the slot in the OLD class metadata that holds the old impl.
    let oldImpl = dlsym(main, "$s3App4BaseC5labelSSyF")!, newImpl = dlsym(h, "$s3App4BaseC5labelSSyF")!
    let meta = unsafeBitCast(Base.self as AnyClass, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
    for i in 0..<64 where meta[i] == oldImpl { meta[i] = newImpl; print("[vtable] patched slot \(i)") }
    report("after vtable patch")
}
