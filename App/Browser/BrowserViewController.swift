import AppKit
import WebKit

/// The browser's view, the same in the conversation's pane and in its own window: a tab strip when there are several tabs,
/// the address bar, and the page in front. Every tab's web view stays in the view, hidden behind the one in front, so it keeps its size.
final class BrowserViewController: NSViewController, NSTextFieldDelegate {
  weak var browser: Browser?
  private let strip = BrowserTabStrip()
  private let back = barButton("chevron.left", "Back", #selector(Browser.browserBack(_:)))
  private let forward = barButton("chevron.right", "Forward", #selector(Browser.browserForward(_:)))
  private let reload = barButton("arrow.clockwise", "Reload Page", #selector(Browser.reloadBrowserPage(_:)))
  private let placement = barButton("macwindow.on.rectangle", "Detach Browser", #selector(Browser.toggleBrowserDetached(_:)))
  private let address = NSTextField()
  private let pages = NSView()

  override func loadView() {
    let bar = NSStackView(views: [back, forward, reload, address, placement])
    let rule = NSBox()
    let column = NSStackView(views: [strip, bar, rule, pages])

    bar.orientation = .horizontal
    bar.spacing = 6
    bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    rule.boxType = .separator
    column.orientation = .vertical
    column.spacing = 0
    column.alignment = .leading
    column.translatesAutoresizingMaskIntoConstraints = false

    address.placeholderString = "Address"
    address.bezelStyle = .roundedBezel
    address.usesSingleLineMode = true
    address.lineBreakMode = .byTruncatingTail
    address.cell?.isScrollable = true
    address.cell?.sendsActionOnEndEditing = false
    address.target = self
    address.action = #selector(openAddress(_:))
    address.delegate = self
    address.setAccessibilityLabel("Address")
    address.setContentHuggingPriority(.defaultLow, for: .horizontal)
    address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    strip.onSelect = { [weak self] id in self?.browser?.tabs.first { $0.id == id }.map { self?.browser?.select($0) } }
    strip.onClose = { [weak self] id in self?.browser?.tabs.first { $0.id == id }.map { self?.browser?.close($0) } }

    view = NSView()
    view.addSubview(column)

    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
      view.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
    ] + [strip, bar, rule, pages].map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) })
  }

  func add(_ tab: BrowserTab) {
    loadViewIfNeeded()
    tab.webView.translatesAutoresizingMaskIntoConstraints = false
    pages.addSubview(tab.webView)

    NSLayoutConstraint.activate([
      tab.webView.topAnchor.constraint(equalTo: pages.topAnchor), tab.webView.bottomAnchor.constraint(equalTo: pages.bottomAnchor),
      tab.webView.leadingAnchor.constraint(equalTo: pages.leadingAnchor), tab.webView.trailingAnchor.constraint(equalTo: pages.trailingAnchor)
    ])
  }

  func remove(_ tab: BrowserTab) { tab.webView.removeFromSuperview() }

  /// Shows the tab in front and what it can do. An address being typed is left alone.
  func refresh() {
    guard isViewLoaded, let browser else { return }

    let webView = browser.active?.webView
    let isLoading = webView?.isLoading == true
    let isInPane = view.window is ConversationWindow

    for tab in browser.tabs { tab.webView.isHidden = tab !== browser.active }

    strip.isHidden = browser.tabs.count < 2
    strip.show(browser.tabs.map { (id: $0.id, title: $0.title) }, active: browser.active?.id)
    back.isEnabled = webView?.canGoBack == true
    forward.isEnabled = webView?.canGoForward == true
    reload.isEnabled = webView?.url != nil
    show(isLoading ? "xmark" : "arrow.clockwise", isLoading ? "Stop Loading" : "Reload Page", on: reload)
    show(isInPane ? "macwindow.on.rectangle" : "sidebar.right", isInPane ? "Detach Browser" : "Attach Browser", on: placement)

    if address.currentEditor() == nil { address.stringValue = webView?.url.map(shownAddress) ?? "" }
  }

  private func show(_ symbol: String, _ label: String, on button: NSButton) {
    guard button.toolTip != label else { return }

    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }

  /// A page with nothing loaded yet reports about:blank, which nobody typed.
  private func shownAddress(_ url: URL) -> String { url.absoluteString == "about:blank" ? "" : url.absoluteString }

  func focusAddress() {
    loadViewIfNeeded()
    view.window?.makeFirstResponder(address)
  }

  @objc private func openAddress(_ sender: Any?) {
    guard let browser, !address.stringValue.allSatisfy(\.isWhitespace) else { return }

    do {
      let tab = try browser.open(address.stringValue)
      view.window?.makeFirstResponder(tab.webView)
    } catch {
      NSSound.beep()
    }
  }

  /// Esc puts the page's address back and returns to the page.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }

    address.abortEditing()
    refresh()
    if let webView = browser?.active?.webView { view.window?.makeFirstResponder(webView) }
    return true
  }
}

