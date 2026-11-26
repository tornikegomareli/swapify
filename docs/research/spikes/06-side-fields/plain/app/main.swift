import Foundation

let first = Counter()
first.a = 7
print("before patch:          ", first.describe())

guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else { fatalError(String(cString: dlerror())) }
for root in ["$s3App7CounterC8describeSSyFTX", "$s3App7CounterC4stepyyFTX", "$s3App7CounterCACycfcTX"] {
    precondition(swp_repoint("/patch.dylib", root), "no root \(root)")
}

print("old object after patch:", first.describe())
first.step()
first.step()
print("old object, two steps: ", first.describe())
let second = Counter()
print("new object:            ", second.describe())
second.step()
print("new object, one step:  ", second.describe(), "| old:", first.describe())
do {
    let third = Counter()
    third.step()
    print("third, before release: ", third.describe(), "| boxes alive:", swp_side_boxes_alive())
}
print("third released, boxes alive:", swp_side_boxes_alive())
