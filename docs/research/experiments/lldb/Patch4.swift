@testable import Host
@_dynamicReplacement(for: greet())
func greet_v4() -> String { "v4" }
