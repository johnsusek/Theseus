import AppKit

/// The task list in a bordered card: done, in progress with a spinner, waiting on agents, and not started.
/// A waiting step says under it how many of its agents still run.
final class TaskCardView: NSView, CardContent {
  private static let padding = 12.0
  private static let rowHeight = 17.0
  private static let noteHeight = 15.0
  private static let rowSpacing = 7.0
  private var rows: [(icon: NSView, label: NSTextField, note: NSTextField?)] = []

  override var isFlipped: Bool { true }

  init(steps: [PlanStep]) {
    super.init(frame: .zero)

    for step in steps {
      let label = NSTextField(labelWithString: step.title)
      let icon: NSView
      var note: NSTextField?

      label.font = NSFont.systemFont(ofSize: 13)
      label.textColor = step.state == .running || step.state == .waiting ? .labelColor : .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      label.isSelectable = true

      if step.state == .running {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.setAccessibilityLabel("In Progress")
        icon = spinner
      } else {
        let symbols: [PlanStep.State: (String, String)] = [.done: ("checkmark.circle.fill", "Done"), .waiting: ("ellipsis.circle", "Waiting"), .pending: ("circle.dashed", "Not Started")]
        let (symbol, description) = symbols[step.state] ?? ("circle.dashed", "Not Started")
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image.contentTintColor = .secondaryLabelColor
        image.toolTip = description
        icon = image
      }

      if let text = step.note {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        addSubview(field)
        note = field
      }

      addSubview(icon)
      addSubview(label)
      rows.append((icon, label, note))
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Tasks")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TaskCardView is built in code") }

  func height(for width: CGFloat) -> CGFloat {
    Self.padding * 2 + rows.reduce(0) { $0 + Self.rowHeight + ($1.note == nil ? 0 : Self.noteHeight) } + CGFloat(max(rows.count - 1, 0)) * Self.rowSpacing
  }

  override func layout() {
    super.layout()

    var top = Self.padding
    let width = max(bounds.width - Self.padding * 2 - 24, 0)

    for row in rows {
      row.icon.frame = NSRect(x: Self.padding, y: top, width: 16, height: Self.rowHeight)
      row.label.frame = NSRect(x: Self.padding + 24, y: top, width: width, height: Self.rowHeight)
      top += Self.rowHeight

      if let note = row.note {
        note.frame = NSRect(x: Self.padding + 24, y: top, width: width, height: Self.noteHeight)
        top += Self.noteHeight
      }

      top += Self.rowSpacing
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor.separatorColor.setStroke()
    border.stroke()
  }
}
