import AppKit

/// The last turn's recap from the model's `wrap_up` call, with its question, where each button sends its title as the reply,
/// and a close button that folds the card into a question row.
/// The buttons have no key equivalents, since Return belongs to the prompt field.
final class NextStepCardView: NSView, CardContent {
  private static let padding = 14.0
  private static let spacing = 10.0
  private let recap: NSTextField
  private let ask: NSTextField?
  /// The recommended answer first, in the accent color.
  private let buttons: [NSButton]
  private let closeButton = NSButton()
  private let reply: (String) -> Void
  private let close: () -> Void

  /// Off while another process has the session open.
  var canReply: Bool {
    didSet { updateButtons() }
  }

  override var isFlipped: Bool { true }

  /// The text stops short of the close button.
  private var textWidth: CGFloat { bounds.width - Self.padding * 2 - 24 }

  init(step: NextStep, canReply: Bool, reply: @escaping (String) -> Void, close: @escaping () -> Void) {
    recap = NSTextField(wrappingLabelWithString: step.recap)
    ask = step.ask.map { NSTextField(wrappingLabelWithString: $0) }
    buttons = step.ask != nil ? step.actions.map { NSButton(title: $0, target: nil, action: nil) } : []
    self.reply = reply
    self.close = close
    self.canReply = canReply
    super.init(frame: .zero)

    recap.font = NSFont.systemFont(ofSize: 13)
    recap.textColor = .secondaryLabelColor
    recap.isSelectable = true
    ask?.font = NSFont.systemFont(ofSize: 13)
    ask?.isSelectable = true
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
    closeButton.isBordered = false
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(closed)

    for button in buttons {
      button.target = self
      button.action = #selector(pressed(_:))
    }

    updateButtons()

    for view in [recap, ask, closeButton].compactMap({ $0 }) + buttons { addSubview(view) }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Next Step")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("NextStepCardView is built in code") }

  /// A tinted button keeps its tint when disabled and only fades its title, so the tint goes with the reply.
  private func updateButtons() {
    for button in buttons { button.isEnabled = canReply }

    buttons.first?.bezelColor = canReply ? .controlAccentColor : nil
  }

  @objc private func pressed(_ sender: NSButton) { reply(sender.title) }

  @objc private func closed() { close() }

  private func textHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
    ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
  }

  func height(for width: CGFloat) -> CGFloat {
    let inner = width - Self.padding * 2 - 24
    var height = Self.padding + textHeight(recap, width: inner) + Self.padding

    if let ask { height += Self.spacing + textHeight(ask, width: inner) }

    if let button = buttons.first { height += Self.spacing + button.fittingSize.height }

    return height
  }

  override func layout() {
    super.layout()
    var top = Self.padding

    recap.frame = NSRect(x: Self.padding, y: top, width: textWidth, height: textHeight(recap, width: textWidth))
    top = recap.frame.maxY + Self.spacing
    closeButton.frame = NSRect(x: bounds.width - Self.padding - 16, y: Self.padding, width: 16, height: 16)

    if let ask {
      ask.frame = NSRect(x: Self.padding, y: top, width: textWidth, height: textHeight(ask, width: textWidth))
      top = ask.frame.maxY + Self.spacing
    }

    var left = Self.padding - 6

    // A push button's bezel sits 6 pt inside its frame, so the first one is pulled out to line up with the text.
    for button in buttons {
      let size = button.fittingSize
      button.frame = NSRect(origin: NSPoint(x: left, y: top), size: size)
      left += size.width
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
    NSColor.separatorColor.setStroke()
    border.stroke()
  }
}
