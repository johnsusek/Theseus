import AppKit

/// A borderless button that draws its own text: the agents badge on a capsule, the changes chip as bare colored counts.
final class StatusChip: NSButton {
  static let height = 20.0

  /// Fills a capsule behind the text.
  var fill: NSColor? {
    didSet { needsDisplay = true }
  }

  var text = NSAttributedString() {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }

  private var capsule: NSBezierPath { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2) }

  /// A capsule is at least a circle, with 6 pt beside its text.
  override var intrinsicContentSize: NSSize {
    let width = ceil(text.size().width)
    return NSSize(width: fill == nil ? width : max(width + 12, Self.height), height: Self.height)
  }

  override var wantsUpdateLayer: Bool { false }
  override var focusRingMaskBounds: NSRect { bounds }

  init() {
    super.init(frame: .zero)
    isBordered = false
    title = ""
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("StatusChip is built in code") }

  override func draw(_ dirtyRect: NSRect) {
    let size = text.size()

    if let fill {
      (isHighlighted ? fill.shadow(withLevel: 0.2) ?? fill : fill).setFill()
      capsule.fill()
    } else if isHighlighted {
      NSGraphicsContext.current?.cgContext.setAlpha(0.6)
    }

    text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
  }

  override func drawFocusRingMask() {
    capsule.fill()
  }
}

/// Calls `tick` once a second for as long as `owner` lives, until the task is cancelled.
@MainActor
func everySecond<Owner: AnyObject & Sendable>(_ owner: Owner, _ tick: @escaping @MainActor (Owner) -> Void) -> Task<Void, Never> {
  Task { [weak owner] in
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      guard let owner, !Task.isCancelled else { return }

      tick(owner)
    }
  }
}
