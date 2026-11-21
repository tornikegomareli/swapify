import Foundation
func report(_ tag: String) {
    let s = makeShape()
    print("[\(tag)] size=\(MemoryLayout.size(ofValue: s)) greet=\(Greeter().greet()) shape=\(s) shapeType=\(type(of: s)) counter=\(Counter().value()) base=\(Base().label()) global=\(globalComputed)")
}
if getenv("SKIP_START") == nil { report("start") }
for path in CommandLine.arguments.dropFirst() {
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard dlopen(path, RTLD_NOW) != nil else {
        print("dlopen failed: \(String(cString: dlerror()))"); continue
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    report("after \((path as NSString).lastPathComponent) dlopen=\(String(format: "%.2f", ms))ms")
}
