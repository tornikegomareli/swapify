import Foundation
public func greet() -> String { "v1" }
setvbuf(stdout, nil, _IONBF, 0)
print("pid", getpid())
for _ in 0..<120 { print(greet()); usleep(250_000) }
