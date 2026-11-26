import AppKit

/// The Sidebar Configuration panel: every `SidebarStyle` setting, applied to every window's sidebar as it changes.
final class SidebarConfigurationController: NSWindowController {
  private var targets: [ControlTarget] = []
  private var reads: [() -> Void] = []
  private let settings = SidebarSettings.shared

  init() {
    let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
    panel.title = "Sidebar Configuration"
    panel.isFloatingPanel = true
    super.init(window: panel)

    let grid = NSGridView(views: [
      [label("Grouping:"), pick(\.grouping)],
      [label("Order:"), pick(\.order)],
      [label("Title:"), row(lines(\.titleLines, 1...2), check("Bold", \.boldTitle))],
      [label("Show:"), check("Last prompt", \.showsPrompt)],
      [NSGridCell.emptyContentView, row(check("Last response", \.showsResponse), lines(\.responseLines, 1...5))],
      [NSGridCell.emptyContentView, check("Activity while running", \.showsActivity)],
      [NSGridCell.emptyContentView, row(check("Date", \.showsDate), pick(\.dateStyle))],
      [NSGridCell.emptyContentView, check("Unread dot", \.showsUnread)],
      [NSGridCell.emptyContentView, check("Worktree symbol", \.showsWorktree)],
      [NSGridCell.emptyContentView, check("Task progress", \.showsTasks)],
      [NSGridCell.emptyContentView, check("Archived sessions", \.showsArchived)],
      [NSGridCell.emptyContentView, check("Compact mode", \.compact)],
      [label("Presets:"), row(preset("Mail", .mail), preset("Nova", .nova))]
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.rowAlignment = .firstBaseline
    grid.column(at: 0).xPlacement = .trailing
    grid.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
    ])
    panel.contentView = content
    panel.setFrameAutosaveName("SidebarConfiguration")
    keepCurrent(self) { controller in controller.reads.forEach { $0() } }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SidebarConfigurationController is built in code") }

  /// Wires `control` to write the style when used, and to show it again whenever the style changes, a preset included.
  private func bind(_ control: NSControl, read: @escaping () -> Void, write: @escaping () -> Void) {
    let target = ControlTarget(write)
    control.target = target
    control.action = #selector(ControlTarget.act(_:))
    targets.append(target)
    reads.append(read)
  }

  private func check(_ title: String, _ path: WritableKeyPath<SidebarStyle, Bool>) -> NSButton {
    let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
    bind(button, read: { [unowned self] in button.state = settings.style[keyPath: path] ? .on : .off }, write: { [unowned self] in settings.style[keyPath: path] = button.state == .on })
    return button
  }

  private func pick<Choice: SidebarChoice>(_ path: WritableKeyPath<SidebarStyle, Choice>) -> NSPopUpButton {
    let popup = NSPopUpButton()
    popup.addItems(withTitles: Choice.allCases.map(\.title))
    bind(popup, read: { [unowned self] in popup.selectItem(at: settings.style[keyPath: path].rawValue) }, write: { [unowned self] in
      guard let choice = Choice(rawValue: popup.indexOfSelectedItem) else { return }

      settings.style[keyPath: path] = choice
    })
    return popup
  }

  /// A pop-up of line counts: "1 Line", "2 Lines".
  private func lines(_ path: WritableKeyPath<SidebarStyle, Int>, _ counts: ClosedRange<Int>) -> NSPopUpButton {
    let popup = NSPopUpButton()
    popup.addItems(withTitles: counts.map { $0 == 1 ? "1 Line" : "\($0) Lines" })
    bind(popup, read: { [unowned self] in popup.selectItem(at: settings.style[keyPath: path] - counts.lowerBound) }, write: { [unowned self] in
      settings.style[keyPath: path] = popup.indexOfSelectedItem + counts.lowerBound
    })
    return popup
  }

  private func preset(_ title: String, _ style: SidebarStyle) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    bind(button, read: {}, write: { [unowned self] in settings.style = style })
    return button
  }

  private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

  private func row(_ views: NSView...) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.alignment = .firstBaseline
    stack.spacing = 8
    return stack
  }
}

/// The target of one panel control, running its write when it is used.
@MainActor
private final class ControlTarget: NSObject {
  private let write: () -> Void

  init(_ write: @escaping () -> Void) {
    self.write = write
  }

  @objc func act(_ sender: Any?) { write() }
}
