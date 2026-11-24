import AppKit

/// The row under the prompt. Left: the agents badge and the changes chip.
/// Right: the model and permission mode menus and how full the context is.
/// It lays itself out by hand, so a narrow window clips the row instead of growing.
final class StatusRowView: NSView {
  let agents = StatusChip()
  let changes = StatusChip()
  let model = NSPopUpButton(frame: .zero, pullsDown: true)
  let mode = NSPopUpButton(frame: .zero, pullsDown: true)
  /// The items of the model or the mode menu, asked for when it is about to open.
  var menuItems: (NSPopUpButton) -> [NSMenuItem] = { _ in [] }

  var state = StatusRowState() {
    didSet {
      if state != oldValue { apply() }
    }
  }

  private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
  private static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  private static let spacing = 12.0
  private let context = NSProgressIndicator()
  private var isActive = false

  init() {
    super.init(frame: .zero)
    clipsToBounds = true

    agents.setAccessibilityLabel("Agents")
    changes.setAccessibilityLabel("Changes")

    for (menu, tip) in [(model, "Model and Effort"), (mode, "Permission Mode")] {
      menu.isBordered = false
      menu.font = Self.font
      menu.toolTip = tip
      menu.addItem(withTitle: "")
      (menu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
      NotificationCenter.default.addObserver(self, selector: #selector(fillMenu(_:)), name: NSPopUpButton.willPopUpNotification, object: menu)
    }

    context.style = .spinning
    context.controlSize = .small
    context.isIndeterminate = false
    context.minValue = 0
    context.maxValue = 1
    context.setAccessibilityLabel("Context")

    for view in [agents, changes, model, mode, context] { addSubview(view) }

    apply()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("StatusRowView is built in code") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowActiveChanged()
  }

  /// Only the main window's badge and line counts have color.
  func windowActiveChanged() {
    isActive = window?.isMainWindow ?? false
    apply()
  }

  private func apply() {
    let title = NSMutableAttributedString(string: state.model, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])

    if !state.effort.isEmpty { title.append(NSAttributedString(string: " " + state.effort, attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])) }

    agents.isHidden = !state.showsAgents
    agents.text = NSAttributedString(string: "\(state.runningAgents)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.white])
    agents.fill = isActive ? .controlAccentColor : .systemGray
    agents.toolTip = state.agentsTooltip
    agents.setAccessibilityValue(state.agentsTooltip)

    changes.isHidden = state.changedFiles == 0
    changes.text = lineDeltaText(added: state.added, removed: state.removed, font: Self.digits, isActive: isActive)
    changes.toolTip = state.changesTooltip
    changes.setAccessibilityValue("\(state.changesTooltip), \(state.added) lines added, \(state.removed) removed")

    model.isHidden = !state.hasSession
    model.menu?.items.first?.attributedTitle = title
    mode.isHidden = !state.hasSession
    mode.menu?.items.first?.title = state.mode

    context.isHidden = state.contextMax == 0
    context.doubleValue = state.contextFraction
    context.toolTip = state.contextTooltip()
    needsLayout = true
    needsDisplay = true
  }

  /// A pull-down's first item is its title. The rest are built when the menu opens, so they are current.
  @objc private func fillMenu(_ note: Notification) {
    guard let button = note.object as? NSPopUpButton, let menu = button.menu else { return }

    while menu.numberOfItems > 1 { menu.removeItem(at: 1) }

    for item in menuItems(button) { menu.addItem(item) }
  }

  override func layout() {
    super.layout()
    // What shows of each item on the right, so the gaps are between text and not between frames.
    let right = [menuItem(model), menuItem(mode), (view: context as NSView, size: NSSize(width: 16, height: 16), shown: 0..<16.0)].filter { !$0.view.isHidden }
    let rightWidth = right.reduce(0) { $0 + $1.shown.upperBound - $1.shown.lowerBound } + Self.spacing * Double(max(right.count - 1, 0))
    var x = 0.0

    for chip in [agents, changes] where !chip.isHidden {
      let size = chip.intrinsicContentSize
      chip.frame = NSRect(x: x, y: 0, width: size.width, height: bounds.height)
      x += size.width + Self.spacing
    }

    // The right side keeps its place until the left side needs the room, then it slides out under the clip.
    x = max(bounds.width - rightWidth, x)

    for item in right {
      item.view.frame = centered(x: x - item.shown.lowerBound, item.size)
      x += item.shown.upperBound - item.shown.lowerBound + Self.spacing
    }
  }

  /// A menu at its fitting size, and the part of that width its title covers: a borderless pop-up button pads its title unevenly.
  private func menuItem(_ menu: NSPopUpButton) -> (view: NSView, size: NSSize, shown: Range<CGFloat>) {
    let size = menu.fittingSize
    let title = menu.cell?.titleRect(forBounds: NSRect(origin: .zero, size: size)) ?? NSRect(origin: .zero, size: size)
    return (menu, size, title.minX..<max(title.maxX, title.minX))
  }

  private func centered(x: CGFloat, _ size: NSSize) -> NSRect {
    NSRect(x: x.rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: ceil(size.width), height: size.height)
  }
}
