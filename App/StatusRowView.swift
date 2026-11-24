import AppKit

/// The row under the prompt: the agents badge and the changes chip.
/// It lays itself out by hand, so a narrow window clips the row instead of growing.
final class StatusRowView: NSView {
  let agents = StatusChip()
  let changes = StatusChip()

  var state = StatusRowState() {
    didSet {
      if state != oldValue { apply() }
    }
  }

  private static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  private static let spacing = 12.0
  private var isActive = false

  init() {
    super.init(frame: .zero)
    clipsToBounds = true

    agents.setAccessibilityLabel("Agents")
    changes.setAccessibilityLabel("Changes")

    for view in [agents, changes] { addSubview(view) }

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
    agents.isHidden = !state.showsAgents
    agents.text = NSAttributedString(string: "\(state.runningAgents)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.white])
    agents.fill = isActive ? .controlAccentColor : .systemGray
    agents.toolTip = state.agentsTooltip
    agents.setAccessibilityValue(state.agentsTooltip)

    changes.isHidden = state.changedFiles == 0
    changes.text = lineDeltaText(added: state.added, removed: state.removed, font: Self.digits, isActive: isActive)
    changes.toolTip = state.changesTooltip
    changes.setAccessibilityValue("\(state.changesTooltip), \(state.added) lines added, \(state.removed) removed")

    needsLayout = true
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    var x = 0.0

    for chip in [agents, changes] where !chip.isHidden {
      let width = chip.intrinsicContentSize.width
      chip.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
      x += width + Self.spacing
    }
  }
}
