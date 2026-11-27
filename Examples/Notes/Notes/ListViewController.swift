import UIKit

/// The list, built in code in viewDidLoad, as most programmatic UIKit screens are.
final class ListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var notes = ["Buy milk", "Call the bank", "Book flights"]
    private var added = 0
    private var table: UITableView!
    private var badge: BadgeView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notes"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in
            self?.add()
        })

        let badge = BadgeView(count: added)
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "note")

        let stack = UIStackView(arrangedSubviews: [badge, table])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.table = table
        self.badge = badge
    }

    private func add() {
        added += 1
        notes.append("Note \(notes.count + 1)")
        badge.count = added
        table.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { notes.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "note", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = notes[indexPath.row]
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        navigationController?.pushViewController(DetailViewController(note: notes[indexPath.row]), animated: false)
    }
}
