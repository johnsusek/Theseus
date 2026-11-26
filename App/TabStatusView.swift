import AppKit

/// What the conversation is doing, shown on its tab: a green dot while Claude works, an orange dot when it waits on the user.
final class TabStatusView: NSView {
  enum Status {
    case idle, running, needsInput
  }

  var status = Status.idle {
    didSet {
      guard status != oldValue else { return }

      dot.isHidden = status == .idle
      dot.contentTintColor = status == .running ? .systemGreen : .systemOrange
      dot.toolTip = status == .running ? "Running" : "Needs Input"
      dot.setAccessibilityLabel(dot.toolTip)
    }
  }

  private let dot = NSImageView()

  override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular))
    dot.isHidden = true
    dot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dot)
    NSLayoutConstraint.activate([dot.centerXAnchor.constraint(equalTo: centerXAnchor), dot.centerYAnchor.constraint(equalTo: centerYAnchor)])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TabStatusView is built in code") }
}
