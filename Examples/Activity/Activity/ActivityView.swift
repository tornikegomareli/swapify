import Charts
import SwiftUI

struct ActivityView: View {
    let week: Week
    @State private var range: WeekRange = .week

    var body: some View {
        ScrollView {
            Text("Activity")
        }
    }
}
