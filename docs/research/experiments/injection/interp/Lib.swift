struct Greeter { func greet() -> String { "v1" } }
func topLevel() -> Int { 1 }
private func hidden() -> Int { 7 }
func callsHidden() -> Int { hidden() }
