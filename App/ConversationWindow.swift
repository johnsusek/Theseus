import AppKit

final class ConversationWindow: NSWindow {
  /// The tab bar's + button.
  override func newWindowForTab(_ sender: Any?) {
    (windowController as? ConversationController)?.newConversation(sender)
  }

  /// Tab groups report membership changes but not tab bar visibility, and the titles depend on it.
  override func toggleTabBar(_ sender: Any?) {
    super.toggleTabBar(sender)

    for window in tabGroup?.windows ?? [self] { (window.windowController as? ConversationController)?.retitle() }
  }
}
