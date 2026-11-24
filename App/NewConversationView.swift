import AppKit

/// A blank conversation's model, effort and permission mode, centered where the transcript will be.
final class NewConversationView: NSView {
  let model = NSPopUpButton()
  let effort = NSPopUpButton()
  let mode = NSPopUpButton()
  /// A menu's items, built when it is about to open, and the value of the current one.
  var menuItems: (NSPopUpButton) -> (items: [NSMenuItem], current: String?) = { _ in ([], nil) }
  private lazy var grid = NSGridView(views: [("Model:", model), ("Effort:", effort), ("Mode:", mode)].map { [NSTextField(labelWithString: $0.0), $0.1] })

  init() {
    super.init(frame: .zero)

    for (button, label) in [(model, "Model"), (effort, "Effort"), (mode, "Permission Mode")] {
      button.setAccessibilityLabel(label)
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
      NotificationCenter.default.addObserver(self, selector: #selector(fillMenu(_:)), name: NSPopUpButton.willPopUpNotification, object: button)
    }

    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 10
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.translatesAutoresizingMaskIntoConstraints = false
    addSubview(grid)

    NSLayoutConstraint.activate([
      grid.topAnchor.constraint(equalTo: topAnchor),
      grid.bottomAnchor.constraint(equalTo: bottomAnchor),
      grid.leadingAnchor.constraint(equalTo: leadingAnchor),
      grid.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("NewConversationView is built in code") }

  /// The titles of the current picks. A model without effort levels hides the effort row.
  func show(model modelTitle: String, effort effortTitle: String, mode modeTitle: String) {
    for (button, title) in [(model, modelTitle), (effort, effortTitle), (mode, modeTitle)] where button.titleOfSelectedItem != title {
      button.removeAllItems()
      button.addItem(withTitle: title)
    }

    grid.row(at: 1).isHidden = effortTitle.isEmpty
  }

  /// The menu holds only the current title until it opens, then every choice with the current one selected.
  @objc private func fillMenu(_ note: Notification) {
    guard let button = note.object as? NSPopUpButton, let menu = button.menu else { return }

    let (items, current) = menuItems(button)
    guard !items.isEmpty else { return }

    menu.removeAllItems()

    for item in items { menu.addItem(item) }

    button.select(items.first { $0.representedObject as? String == current })
  }
}
