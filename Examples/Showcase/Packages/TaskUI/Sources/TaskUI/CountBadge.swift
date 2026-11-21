import SwiftUI

public struct CountBadge: View {
    let remaining: Int

    public init(remaining: Int) {
        self.remaining = remaining
    }

    public var body: some View {
        Text("\(remaining) open")
            .font(.subheadline.bold())
            .padding(8)
    }
}
