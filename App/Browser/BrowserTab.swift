import AppKit
import WebKit

/// One page of a conversation's browser: its web view, how its loads end, and the dialogs the page raises.
@MainActor
final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate {
  /// The content world the page scripts answer in, apart from the page's own scripts.
  static let world = WKContentWorld.world(name: "Theseus")
  private static let contentScript = script("page-content")
  private static let captureScript = script("page-main")

  let id: String
  let webView: WKWebView
  private unowned let browser: Browser
  private var observations: [NSKeyValueObservation] = []
  /// Why the last load failed, until the next one starts.
  private var loadFailure: String?
  /// The load of the page that says so, which is not a new load to wait for.
  private var failurePage: WKNavigation?
  /// Tool calls driving the page now. A dialog the page raises meanwhile is dismissed and reported, since nobody may be there to answer it.
  var driving = 0
  private var dismissedDialogs: [String] = []

  var url: URL? { webView.url }
  var title: String { webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.host() ?? "New Tab" }

  /// `configuration` is the one WebKit hands over for a window the page opens; nil makes the browser's own.
  init(id: String, browser: Browser, configuration: WKWebViewConfiguration? = nil) {
    self.id = id
    self.browser = browser
    webView = WKWebView(frame: .zero, configuration: configuration ?? Self.configuration())
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.isInspectable = true
    webView.setAccessibilityLabel("Page")

    let changed: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in MainActor.assumeIsolated { self?.browser.refresh() } }

    observations = [
      webView.observe(\.title, changeHandler: changed), webView.observe(\.url, changeHandler: changed), webView.observe(\.isLoading, changeHandler: changed),
      webView.observe(\.canGoBack, changeHandler: changed), webView.observe(\.canGoForward, changeHandler: changed)
    ]
  }

  /// The capture of console messages and requests goes in the page's world before its scripts run; the script that reads and drives the page in its own.
  private static func configuration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()

    // Without a Safari version some sites serve their fallback for unknown browsers.
    configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
    configuration.userContentController.addUserScript(WKUserScript(source: captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    configuration.userContentController.addUserScript(WKUserScript(source: contentScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    return configuration
  }

  private static func script(_ name: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else {
      fatalError("\(name).js is missing from the app bundle; scripts/update-page-scripts.sh copies it in")
    }

    return source
  }

  // MARK: Loading

  /// A file page may read `folder`, so its scripts and images load.
  func load(_ url: URL, readAccess folder: URL) {
    if url.isFileURL {
      let isInside = url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
      webView.loadFileURL(url, allowingReadAccessTo: isInside ? folder : url.deletingLastPathComponent())
    } else {
      webView.load(URLRequest(url: url))
    }
  }

  /// Returns when the page has finished loading. A load that failed throws its reason.
  func loaded(timeout: Duration = .seconds(30)) async throws {
    let deadline = ContinuousClock.now + timeout

    // The web view reports a load a moment after it is asked for one.
    try await Task.sleep(for: .milliseconds(80))

    while webView.isLoading {
      guard ContinuousClock.now < deadline else { throw ToolFailure("\(webView.url?.absoluteString ?? "The page") was still loading after \(timeout.components.seconds) s.") }

      try await Task.sleep(for: .milliseconds(40))
    }

    if let loadFailure { throw ToolFailure(loadFailure) }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    if navigation !== failurePage { loadFailure = nil }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }

  /// The page says why it did not load, in place of a blank one.
  private func failed(_ error: any Error) {
    let error = error as NSError
    // A load another one replaced, or one that became a download.
    guard error.code != NSURLErrorCancelled, !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }

    let address = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? webView.url?.absoluteString ?? ""
    let escaped = { (text: String) in text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }

    loadFailure = "\(address) did not load: \(error.localizedDescription)"
    failurePage = webView.loadHTMLString("""
      <!doctype html><meta name="color-scheme" content="light dark"><title>Page Not Loaded</title>
      <body style="font: 13px -apple-system; margin: 22vh auto 0; max-width: 420px; padding: 0 24px; text-align: center">
      <h1 style="font-size: 20px; font-weight: 600">Page Not Loaded</h1><p>\(escaped(error.localizedDescription))</p><p style="opacity: 0.6; word-break: break-all">\(escaped(address))</p>
      """, baseURL: URL(string: address))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loadFailure = "The page's process quit, so the page was loaded again."
    webView.reload()
  }

  // MARK: Windows and dialogs

  /// A window the page opens becomes a tab.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    browser.openTab(configuration: configuration).webView
  }

  func webViewDidClose(_ webView: WKWebView) { browser.close(self) }

  /// The window to put a sheet on: only when someone can see it and no tool call is waiting on the page.
  private var sheetWindow: NSWindow? { driving == 0 && webView.window?.isVisible == true ? webView.window : nil }

  private func dialog(_ message: String, cancel: Bool) -> NSAlert {
    let alert = NSAlert()

    alert.messageText = webView.url?.host() ?? "This Page"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    if cancel { alert.addButton(withTitle: "Cancel") }
    return alert
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
    guard let window = sheetWindow else { return dismissedDialogs.append("an alert saying \"\(message)\"") }

    await dialog(message, cancel: false).beginSheetModal(for: window)
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
    guard let window = sheetWindow else {
      dismissedDialogs.append("a confirmation asking \"\(message)\", which was canceled")
      return false
    }

    return await dialog(message, cancel: true).beginSheetModal(for: window) == .alertFirstButtonReturn
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
    guard let window = sheetWindow else {
      dismissedDialogs.append("a prompt asking \"\(prompt)\", which was canceled")
      return nil
    }

    let alert = dialog(prompt, cancel: true)
    let field = NSTextField(string: defaultText ?? "")

    field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
  }

  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
    guard let window = sheetWindow else {
      dismissedDialogs.append("a file chooser, which was canceled")
      return nil
    }

    let panel = NSOpenPanel()

    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
  }

  /// What the page raised while a tool call drove it, for that call's reply.
  func takeDialogNotes() -> [String] {
    defer { dismissedDialogs = [] }
    return dismissedDialogs.map { "The page showed \($0)." }
  }
}
