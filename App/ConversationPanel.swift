import AppKit

/// A utility panel is the one AppKit window with the small title bar. Unlike a stock panel it can be the main window,
/// so it gets the active look and its own Window menu entry.
final class ConversationPanel: NSPanel {
  override var canBecomeMain: Bool { true }

  /// A panel with a close button closes on Esc and on Command-Period; a conversation should not.
  override func cancelOperation(_ sender: Any?) {}

  /// Tab groups report membership changes but not tab bar visibility, and the titles depend on it.
  override func toggleTabBar(_ sender: Any?) {
    super.toggleTabBar(sender)

    for window in tabGroup?.windows ?? [self] { (window.windowController as? ConversationController)?.retitle() }
  }
}
