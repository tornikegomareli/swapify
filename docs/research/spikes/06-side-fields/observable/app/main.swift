import Foundation
import Observation
setbuf(stdout, nil)

let model = Model()
model.a = 7
print("before patch:  ", model.describe())
guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else { fatalError(String(cString: dlerror())) }
for root in ["$s3App5ModelC8describeSSyFTX", "$s3App5ModelC4stepyyFTX", "$s3App5ModelCACycfcTX"] {
    precondition(swp_repoint("/patch.dylib", root), "no root \(root)")
}
precondition(swp_copy_word("/patch.dylib", "$s3App5ModelC22_$observationRegistrar33_89A9CEFC44BC8C77E2CEDEA29AE873F0LL11Observation0mD0VvpWvd"))
let wvd = "$s3App5ModelC22_$observationRegistrar33_89A9CEFC44BC8C77E2CEDEA29AE873F0LL11Observation0mD0VvpWvd"
print("registrar offset, app:", swp_word(nil, wvd), "patch:", swp_word("/patch.dylib", wvd))
print("after patch:   ", model.describe())
// Track what describe() reads, as SwiftUI tracks a body, then mutate through the new property.
var fired = false
withObservationTracking { _ = model.describe() } onChange: { fired = true }
model.step()
print("after a step:  ", model.describe(), "| observation fired:", fired)
let fresh = Model()
fresh.step()
print("new object:    ", fresh.describe())
