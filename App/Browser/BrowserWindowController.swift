import AppKit

/// The browser's own window. It holds the browser's view whenever the conversation's pane does not, and is on screen only while the
/// browser is shown detached; its close button hides the browser and keeps the tabs.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
  private static let frameName = "Browser"
  private unowned let browser: Browser

  init(browser: Browser) {
    self.browser = browser
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)

    window.title = "Browser"
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentMinSize = NSSize(width: 320, height: 240)
    window.delegate = self
    window.center()
    window.setFrameUsingName(Self.frameName)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("BrowserWindowController is built in code") }

  /// Takes the browser's view from wherever it was.
  func host(_ controller: NSViewController) {
    guard let content = window?.contentView, controller.view.superview !== content else { return }

    controller.removeFromParent()
    controller.view.removeFromSuperview()
    controller.view.frame = content.bounds
    controller.view.autoresizingMask = [.width, .height]
    controller.view.translatesAutoresizingMaskIntoConstraints = true
    content.addSubview(controller.view)
  }

  /// Browser commands from the menu bar and the bar's buttons reach the browser from this window.
  override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
    browser.responds(to: action) ? browser : super.supplementalTarget(forAction: action, sender: sender)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    browser.hide()
    return false
  }

  func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

  func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
}
