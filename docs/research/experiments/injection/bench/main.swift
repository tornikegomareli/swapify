import Foundation
var a = Acc()
let n = 100_000_000
let t0 = DispatchTime.now().uptimeNanoseconds
for i in 0..<n { step(&a, i) }
let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
print(String(format: "%@ %.3fs (%.2f ns/iter) v=%d", CommandLine.arguments[0].split(separator: "/").last!.description, dt, dt * 1e9 / Double(n), a.v))
