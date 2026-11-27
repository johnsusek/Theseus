import AppKit

/// The browser's tabs as a row of accessory-bar buttons, the one in front pressed in, with a button to close it and one to add a tab.
final class BrowserTabStrip: NSView {
  var onSelect: ((String) -> Void)?
  var onClose: ((String) -> Void)?
  private let row = NSStackView()
  private var shown: [(id: String, title: String)] = []
  private var activeId: String?

  init() {
    super.init(frame: .zero)
    row.orientation = .horizontal
    row.spacing = 4
    row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("BrowserTabStrip is built in code") }

  func show(_ tabs: [(id: String, title: String)], active: String?) {
    guard tabs.map(\.id) != shown.map(\.id) || tabs.map(\.title) != shown.map(\.title) || active != activeId else { return }

    shown = tabs
    activeId = active
    row.setViews(tabs.flatMap { tab in buttons(for: tab, isActive: tab.id == active) } + [symbolButton("plus", "New Tab", #selector(Browser.newBrowserTab(_:)), target: nil)], in: .leading)
  }

  private func buttons(for tab: (id: String, title: String), isActive: Bool) -> [NSView] {
    let button = NSButton(title: tab.title, target: self, action: #selector(select(_:)))

    button.bezelStyle = .accessoryBar
    button.setButtonType(.pushOnPushOff)
    button.state = isActive ? .on : .off
    button.lineBreakMode = .byTruncatingTail
    button.identifier = NSUserInterfaceItemIdentifier(tab.id)
    button.toolTip = tab.title
    button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.menu = NSMenu()
    button.menu?.addItem(withTitle: "Close Tab", action: #selector(close(_:)), keyEquivalent: "").target = self
    button.menu?.items.first?.representedObject = tab.id

    guard isActive else { return [button] }

    let close = symbolButton("xmark", "Close Tab", #selector(close(_:)), target: self)

    close.identifier = NSUserInterfaceItemIdentifier(tab.id)
    return [button, close]
  }

  private func symbolButton(_ symbol: String, _ label: String, _ action: Selector, target: AnyObject?) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: target, action: action)

    button.isBordered = false
    button.controlSize = .small
    button.toolTip = label
    button.setAccessibilityLabel(label)
    return button
  }

  @objc private func select(_ sender: NSButton) {
    // Pressing the tab in front would pop it out.
    sender.state = .on
    if let id = sender.identifier?.rawValue { onSelect?(id) }
  }

  @objc private func close(_ sender: Any?) {
    let id = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSButton)?.identifier?.rawValue

    if let id { onClose?(id) }
  }
}
