@testable import Host
@_dynamicReplacement(for: greet())
func greet_v2() -> String { "v2" }
