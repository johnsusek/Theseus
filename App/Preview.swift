import AppKit

/// A conversation's preview, which `show_file` points at a file. Attached it is a pane of the conversation window, which is the default;
/// detached it is a window of its own. Its close button hides it.
@MainActor
final class Preview: NSObject, NSWindowDelegate, NSMenuItemValidation {
  private static let detachedKey = "PreviewDetached"
  private static let frameName = "Preview"

  let viewController = PreviewViewController()
  private unowned let conversation: ConversationController
  private var window: NSWindow?
  private var isShown = false
  private var isDetached: Bool { UserDefaults.standard.bool(forKey: Self.detachedKey) }

  init(conversation: ConversationController) { self.conversation = conversation }

  /// Points the preview at `url` and brings it on screen without taking focus from the prompt.
  func show(_ url: URL) {
    viewController.show(url)
    window?.title = url.lastPathComponent
    window?.representedURL = url
    isShown = true
    place()
  }

  private func place() {
    if isShown && !isDetached {
      window?.orderOut(nil)
      conversation.showPane(viewController, in: .preview)
    } else if isShown {
      conversation.hidePane(.preview)
      host()
      window?.orderFront(nil)
    } else {
      conversation.hidePane(.preview)
      window?.orderOut(nil)
    }

    viewController.placed(inPane: isShown && !isDetached)
  }

  /// Puts the view in the preview's own window, made on first use.
  private func host() {
    let window = window ?? makeWindow()
    guard let content = window.contentView, viewController.view.superview !== content else { return }

    viewController.removeFromParent()
    viewController.view.removeFromSuperview()
    viewController.view.frame = content.bounds
    viewController.view.autoresizingMask = [.width, .height]
    viewController.view.translatesAutoresizingMaskIntoConstraints = true
    content.addSubview(viewController.view)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)

    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentMinSize = NSSize(width: 320, height: 240)
    window.delegate = self
    window.center()
    window.setFrameUsingName(Self.frameName)
    window.title = viewController.url?.lastPathComponent ?? "Preview"
    window.representedURL = viewController.url
    self.window = window
    return window
  }

  /// The conversation is closing.
  func close() {
    viewController.stop()
    window?.close()
  }

  // MARK: Commands

  @objc func hidePreview(_ sender: Any?) {
    isShown = false
    place()
  }

  @objc func togglePreview(_ sender: Any?) {
    isShown.toggle()
    place()
  }

  @objc func togglePreviewDetached(_ sender: Any?) {
    UserDefaults.standard.set(!isDetached, forKey: Self.detachedKey)
    isShown = true
    place()
    if isDetached { window?.makeKeyAndOrderFront(nil) }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(togglePreview(_:)):
      menuItem.title = isShown ? "Hide Preview" : "Show Preview"
      return viewController.url != nil
    case #selector(togglePreviewDetached(_:)):
      menuItem.title = isDetached ? "Attach Preview" : "Detach Preview"
      return viewController.url != nil
    default:
      return true
    }
  }

  // MARK: Window

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hidePreview(sender)
    return false
  }

  func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

  func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
}
