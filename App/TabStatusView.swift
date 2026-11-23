import AppKit

/// What the conversation is doing, shown on its tab: a spinner while Claude works, an orange dot when it waits on the user.
final class TabStatusView: NSView {
  enum Status {
    case idle, running, needsInput
  }

  var status = Status.idle {
    didSet {
      guard status != oldValue else { return }

      dot.isHidden = status != .needsInput

      if status == .running {
        spinner.startAnimation(nil)
      } else {
        spinner.stopAnimation(nil)
      }
    }
  }

  private let spinner = NSProgressIndicator()
  private let dot = NSImageView()

  override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    spinner.style = .spinning
    spinner.controlSize = .mini
    spinner.isDisplayedWhenStopped = false
    spinner.toolTip = "Running"
    spinner.setAccessibilityLabel("Running")
    dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Needs Input")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular))
    dot.contentTintColor = .systemOrange
    dot.toolTip = "Needs Input"
    dot.isHidden = true

    for view in [spinner, dot] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
      NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: centerXAnchor), view.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TabStatusView is built in code") }
}
