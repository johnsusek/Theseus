import AppKit
import WebKit

/// A conversation's browser: its tabs, which one shows, and where its view sits. Shown and attached it is a pane of the conversation
/// window; otherwise it lives in a window of its own, on screen only when shown, so pages keep a size and take input while nobody looks.
@MainActor
final class Browser: NSObject, NSMenuItemValidation {
  private static let detachedKey = "BrowserDetached"

  private(set) var tabs: [BrowserTab] = []
  private(set) var active: BrowserTab?
  let viewController = BrowserViewController()
  private lazy var windowController = BrowserWindowController(browser: self)
  private unowned let conversation: ConversationController
  private var tabCount = 0
  private(set) var isShown = false
  private var isPlaced = false
  private var isDetached: Bool { UserDefaults.standard.bool(forKey: Self.detachedKey) }

  init(conversation: ConversationController) {
    self.conversation = conversation
    super.init()
    viewController.browser = self
  }

  // MARK: Tabs

  /// A new tab in front. `configuration` comes from WebKit when a page opens a window.
  @discardableResult
  func openTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
    tabCount += 1

    let tab = BrowserTab(id: String(tabCount), browser: self, configuration: configuration)

    if !isPlaced { place() }

    tabs.append(tab)
    viewController.add(tab)
    select(tab)
    return tab
  }

  func select(_ tab: BrowserTab) {
    active = tab
    refresh()
  }

  func close(_ tab: BrowserTab) {
    guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

    tabs.remove(at: index)
    viewController.remove(tab)

    if active === tab { active = tabs.indices.contains(index) ? tabs[index] : tabs.last }

    refresh()
  }

  /// The tab a tool names, or the one in front.
  func tab(_ id: String?) throws -> BrowserTab {
    guard let id else {
      guard let active else { throw ToolFailure("The browser has no tab open; navigate or tabs_create opens one.") }
      return active
    }

    guard let tab = tabs.first(where: { $0.id == id }) else { throw ToolFailure("No tab has id \(id); tabs_context lists them.") }

    return tab
  }

  /// Loads what was typed or passed, in the tab in front or a new one.
  @discardableResult
  func open(_ address: String, in tab: BrowserTab? = nil) throws -> BrowserTab {
    let folder = conversation.browserFolder
    guard let url = BrowserAddress.url(from: address, in: folder) else { throw ToolFailure("\(address) is not an address.") }

    let tab = tab ?? active ?? openTab()

    tab.load(url, readAccess: folder)
    return tab
  }

  /// Brings up a page a transcript card names: the tab already on it, or the tab in front loaded with it.
  func reveal(_ address: String) {
    if let tab = tabs.first(where: { $0.url?.absoluteString == address }) {
      select(tab)
    } else if (try? open(address)) == nil {
      NSSound.beep()
    }

    show()
  }

  /// A tab's title, address or loading changed, or the tabs did.
  func refresh() {
    viewController.refresh()
    windowController.window?.title = active?.title ?? "Browser"
  }

  // MARK: Placement

  /// Brings the browser on screen where it was last kept, without taking key from the conversation.
  func show() {
    isShown = true
    place()
  }

  func hide() {
    isShown = false
    place()
  }

  private func place() {
    isPlaced = true

    if isShown && !isDetached {
      windowController.window?.orderOut(nil)
      conversation.showBrowserPane(viewController)
    } else {
      conversation.hideBrowserPane()
      windowController.host(viewController)

      if isShown { windowController.window?.orderFront(nil) } else { windowController.window?.orderOut(nil) }
    }

    viewController.refresh()
  }

  /// The conversation is closing.
  func close() {
    for tab in tabs { viewController.remove(tab) }

    tabs = []
    active = nil
    if isPlaced { windowController.close() }
  }

  // MARK: Commands

  @objc func toggleBrowser(_ sender: Any?) {
    if isShown { hide() } else { show() }
  }

  @objc func toggleBrowserDetached(_ sender: Any?) {
    UserDefaults.standard.set(!isDetached, forKey: Self.detachedKey)
    show()
    if isDetached { windowController.window?.makeKeyAndOrderFront(nil) }
  }

  @objc func openBrowserLocation(_ sender: Any?) {
    show()
    viewController.focusAddress()
  }

  @objc func newBrowserTab(_ sender: Any?) {
    openTab()
    openBrowserLocation(sender)
  }

  @objc func closeBrowserTab(_ sender: Any?) {
    if let active { close(active) }
  }

  @objc func browserBack(_ sender: Any?) { active?.webView.goBack() }

  @objc func browserForward(_ sender: Any?) { active?.webView.goForward() }

  @objc func reloadBrowserPage(_ sender: Any?) {
    guard let webView = active?.webView else { return }

    if webView.isLoading { webView.stopLoading() } else { webView.reload() }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(toggleBrowser(_:)):
      menuItem.title = isShown ? "Hide Browser" : "Show Browser"
      return true
    case #selector(toggleBrowserDetached(_:)):
      menuItem.title = isDetached ? "Attach Browser" : "Detach Browser"
      return true
    case #selector(browserBack(_:)):
      return active?.webView.canGoBack == true
    case #selector(browserForward(_:)):
      return active?.webView.canGoForward == true
    case #selector(reloadBrowserPage(_:)):
      menuItem.title = active?.webView.isLoading == true ? "Stop Loading" : "Reload Page"
      return active?.url != nil
    case #selector(closeBrowserTab(_:)):
      return active != nil
    default:
      return true
    }
  }
}
