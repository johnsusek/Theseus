import AppKit

/// Where the Private Desktop's view shows. Attached, the default, it is a pane of the conversation window it was shown from, and moves to
/// another conversation shown it later; detached, it is a window of its own. Its close button hides it.
@MainActor
final class DesktopPane: NSObject, NSWindowDelegate, NSMenuItemValidation {
  private static let detachedKey = "PrivateDesktopDetached"
  private static let frameName = "PrivateDesktop"

  let viewController: DesktopViewController
  private weak var conversation: ConversationController?
  private var window: NSWindow?
  private var isShown = false
  private var isDetached: Bool { UserDefaults.standard.bool(forKey: Self.detachedKey) }

  init(desktop: PrivateDesktop) {
    viewController = DesktopViewController(desktop: desktop)
    super.init()
    viewController.picture.onRestore = { [weak self] in self?.show(in: self?.frontConversation) }
    keepCurrent(self) { pane in pane.window?.title = pane.viewController.heading }
  }

  /// Shows it in `conversation`'s pane, or in its own window when detached or when no conversation is in front.
  func show(in conversation: ConversationController?) {
    if let conversation, conversation !== self.conversation {
      self.conversation?.hidePane(.desktop)
      self.conversation = conversation
    }

    isShown = true
    place()
    if isDetached || self.conversation == nil { window?.makeKeyAndOrderFront(nil) }
  }

  private func place() {
    let attached = isShown && !isDetached && conversation != nil

    if attached {
      window?.orderOut(nil)
      conversation?.showPane(viewController, in: .desktop)
    } else if isShown {
      conversation?.hidePane(.desktop)
      host()
      window?.orderFront(nil)
    } else {
      conversation?.hidePane(.desktop)
      window?.orderOut(nil)
    }

    viewController.placed(inPane: attached)
  }

  /// Puts the view in its own window, made on first use.
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
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)

    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentMinSize = NSSize(width: 320, height: 240)
    window.delegate = self
    window.center()
    window.setFrameUsingName(Self.frameName)
    window.title = viewController.heading
    self.window = window
    return window
  }

  /// A conversation window is closing; the pane goes with it.
  func closed(_ closing: ConversationController) {
    guard closing === conversation else { return }

    conversation = nil
    if !isDetached { isShown = false }
  }

  /// The frontmost conversation window, which may be behind the detached window.
  private var frontConversation: ConversationController? { NSApp.orderedWindows.lazy.compactMap { $0.windowController as? ConversationController }.first }

  // MARK: Commands

  @objc func hidePrivateDesktop(_ sender: Any?) {
    isShown = false
    place()
  }

  /// View > Show Private Desktop, from a conversation window or the detached one.
  @objc func togglePrivateDesktop(_ sender: Any?) {
    if isShown { return hidePrivateDesktop(sender) }

    show(in: frontConversation)
  }

  /// View > Enter Picture in Picture: the system's floating window, which stays on top across apps and Spaces.
  @objc func togglePictureInPicture(_ sender: Any?) {
    viewController.togglePictureInPicture()
  }

  @objc func togglePrivateDesktopDetached(_ sender: Any?) {
    UserDefaults.standard.set(!isDetached, forKey: Self.detachedKey)
    show(in: frontConversation)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(togglePrivateDesktop(_:)):
      menuItem.title = isShown ? "Hide Private Desktop" : "Show Private Desktop"
    case #selector(togglePrivateDesktopDetached(_:)):
      menuItem.title = isDetached ? "Attach Private Desktop" : "Detach Private Desktop"
    case #selector(togglePictureInPicture(_:)):
      menuItem.title = viewController.isInPictureInPicture ? "Exit Picture in Picture" : "Enter Picture in Picture"
      return viewController.canTogglePictureInPicture
    default:
      break
    }

    return true
  }

  // MARK: Window

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hidePrivateDesktop(sender)
    return false
  }

  func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

  func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
}
