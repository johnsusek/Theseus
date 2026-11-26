import AppKit

/// A blank conversation's model, effort and permission mode menus, in one row above the prompt.
final class NewConversationView: NSView {
  let model = NSPopUpButton(frame: .zero, pullsDown: true)
  let effort = NSPopUpButton(frame: .zero, pullsDown: true)
  let mode = NSPopUpButton(frame: .zero, pullsDown: true)
  /// The items of a menu, asked for when it is about to open.
  var menuItems: (NSPopUpButton) -> [NSMenuItem] = { _ in [] }

  init() {
    super.init(frame: .zero)

    for (menu, label) in [(model, "Model"), (effort, "Effort"), (mode, "Permission Mode")] {
      menu.isBordered = false
      menu.font = .systemFont(ofSize: NSFont.systemFontSize)
      menu.toolTip = label
      menu.setAccessibilityLabel(label)
      menu.addItem(withTitle: "")
      (menu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
      NotificationCenter.default.addObserver(self, selector: #selector(fillMenu(_:)), name: NSPopUpButton.willPopUpNotification, object: menu)
    }

    let row = NSStackView(views: [model, effort, mode])
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("NewConversationView is built in code") }

  /// The titles of the current picks. A model without effort levels hides the effort menu.
  func show(model modelTitle: String, effort effortTitle: String, mode modeTitle: String) {
    model.menu?.items.first?.title = modelTitle
    effort.menu?.items.first?.title = effortTitle
    effort.isHidden = effortTitle.isEmpty
    mode.menu?.items.first?.title = modeTitle
  }

  /// A pull-down's first item is its title. The rest are built when the menu opens, so they are current.
  @objc private func fillMenu(_ note: Notification) {
    guard let button = note.object as? NSPopUpButton, let menu = button.menu else { return }

    while menu.numberOfItems > 1 { menu.removeItem(at: 1) }

    for item in menuItems(button) { menu.addItem(item) }
  }
}
