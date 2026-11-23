import AppKit
import ClaudeEngine

/// The running turn's task list in a bordered card: done, in progress with a spinner, and not started.
final class TaskCardView: NSView, CardContent {
  private static let padding = 12.0
  private static let rowHeight = 17.0
  private static let rowSpacing = 7.0
  private var rows: [(icon: NSView, label: NSTextField)] = []

  override var isFlipped: Bool { true }

  init(tasks: [TaskItem]) {
    super.init(frame: .zero)

    for task in tasks {
      let isDone = task.status == .completed
      let label = NSTextField(labelWithString: task.status == .inProgress ? task.activeForm ?? task.subject : task.subject)
      let icon: NSView

      label.font = NSFont.systemFont(ofSize: 13)
      label.textColor = isDone ? .secondaryLabelColor : .labelColor
      label.lineBreakMode = .byTruncatingTail
      label.isSelectable = true

      if task.status == .inProgress {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.setAccessibilityLabel("In Progress")
        icon = spinner
      } else {
        let description = isDone ? "Done" : "Not Started"
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: isDone ? "checkmark.circle.fill" : "circle.dashed", accessibilityDescription: description)
        image.contentTintColor = .secondaryLabelColor
        image.toolTip = description
        icon = image
      }

      addSubview(icon)
      addSubview(label)
      rows.append((icon, label))
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Tasks")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TaskCardView is built in code") }

  func height(for width: CGFloat) -> CGFloat {
    Self.padding * 2 + CGFloat(rows.count) * Self.rowHeight + CGFloat(max(rows.count - 1, 0)) * Self.rowSpacing
  }

  override func layout() {
    super.layout()

    for (index, row) in rows.enumerated() {
      let top = Self.padding + CGFloat(index) * (Self.rowHeight + Self.rowSpacing)
      row.icon.frame = NSRect(x: Self.padding, y: top, width: 16, height: Self.rowHeight)
      row.label.frame = NSRect(x: Self.padding + 24, y: top, width: max(bounds.width - Self.padding * 2 - 24, 0), height: Self.rowHeight)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor.separatorColor.setStroke()
    border.stroke()
  }
}
