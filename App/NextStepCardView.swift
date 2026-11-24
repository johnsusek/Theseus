import AppKit

/// The last turn's recap from the model's `wrap_up` call, with its question, where each button sends its title as the reply.
/// The buttons have no key equivalents, since Return belongs to the prompt field.
final class NextStepCardView: NSView, CardContent {
  private static let padding = 12.0
  private static let spacing = 8.0
  private let recap: NSTextField
  private let ask: NSTextField?
  /// The recommended answer last, in the default button's place.
  private let buttons: [NSButton]
  private let reply: (String) -> Void

  /// Off while another process has the session open.
  var canReply: Bool {
    didSet {
      for button in buttons { button.isEnabled = canReply }
    }
  }

  override var isFlipped: Bool { true }

  init(step: NextStep, canReply: Bool, reply: @escaping (String) -> Void) {
    recap = NSTextField(wrappingLabelWithString: step.recap)
    ask = step.ask.map { NSTextField(wrappingLabelWithString: $0) }
    buttons = step.ask != nil ? step.actions.reversed().map { NSButton(title: $0, target: nil, action: nil) } : []
    self.reply = reply
    self.canReply = canReply
    super.init(frame: .zero)

    recap.font = NSFont.systemFont(ofSize: 13)
    recap.textColor = .secondaryLabelColor
    recap.isSelectable = true
    ask?.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    ask?.isSelectable = true

    for button in buttons {
      button.target = self
      button.action = #selector(pressed(_:))
      button.isEnabled = canReply
    }

    for view in [recap, ask].compactMap({ $0 }) + buttons { addSubview(view) }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Next Step")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("NextStepCardView is built in code") }

  @objc private func pressed(_ sender: NSButton) { reply(sender.title) }

  private func textHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
    ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
  }

  func height(for width: CGFloat) -> CGFloat {
    let inner = width - Self.padding * 2
    var height = Self.padding + textHeight(recap, width: inner) + Self.padding

    if let ask { height += Self.spacing + textHeight(ask, width: inner) }

    if let button = buttons.first { height += Self.spacing + button.fittingSize.height }

    return height
  }

  override func layout() {
    super.layout()
    let inner = bounds.width - Self.padding * 2
    var top = Self.padding

    recap.frame = NSRect(x: Self.padding, y: top, width: inner, height: textHeight(recap, width: inner))
    top = recap.frame.maxY + Self.spacing

    if let ask {
      ask.frame = NSRect(x: Self.padding, y: top, width: inner, height: textHeight(ask, width: inner))
      top = ask.frame.maxY + Self.spacing
    }

    var right = bounds.width - Self.padding

    for button in buttons.reversed() {
      let size = button.fittingSize
      button.frame = NSRect(origin: NSPoint(x: right - size.width, y: top), size: size)
      right -= size.width + 8
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor.separatorColor.setStroke()
    border.stroke()
  }
}
