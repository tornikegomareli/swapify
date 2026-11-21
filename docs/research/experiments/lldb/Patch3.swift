@testable import Host
@_dynamicReplacement(for: greet())
func greet_v3() -> String { "v3" }
