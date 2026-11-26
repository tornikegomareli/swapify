import Foundation
setbuf(stdout, nil)

let first = Counter()
first.a = 7
let special = Special()
special.extra = 10
let base: Counter = special
print("before patch:      ", first.describe(), "|", base.describe())

guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else { fatalError(String(cString: dlerror())) }
for root in ["$s3App7CounterC8describeSSyFTX", "$s3App7CounterC4stepyyFTX", "$s3App7CounterCACycfcTX",
             "$s3App7SpecialC8describeSSyFTX"] {
    precondition(swp_repoint("/patch.dylib", root), "no root \(root)")
}

print("after patch:       ", first.describe())
print("subclass, old call:", base.describe())
first.step()
base.step()
base.step()
print("after steps:       ", first.describe(), "|", base.describe())
let fresh = Special()
fresh.step()
print("new subclass:      ", fresh.describe())
do {
    let third = Counter()
    third.step()
    print("third, before release: boxes alive:", swp_side_boxes_alive())
}
print("third released, boxes alive:", swp_side_boxes_alive())
