import UIKit

/// A custom view that builds its subviews in init.
final class BadgeView: UIView {
    private let label = UILabel()

    var count: Int {
        didSet { update() }
    }

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func update() {
        label.text = "Count: \(count)"
    }
}
