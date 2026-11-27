import AppKit
import Quartz
import WebKit

/// The preview's view, the same in the conversation's pane and in its own window: a bar with the file's name, and the file.
/// Markdown is drawn the way GitHub draws it; anything else goes through Quick Look. It follows the file as it changes on disk.
final class PreviewViewController: NSViewController, WKNavigationDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
  private(set) var url: URL?
  private let pages = MarkdownSchemeHandler()
  private lazy var webView = markdownView()
  private lazy var quickLook = QLPreviewView(frame: .zero, style: .normal)!
  private let name = NSTextField(labelWithString: "")
  private let search = NSSearchField()
  private let placement = barButton("macwindow.on.rectangle", "Detach Preview", #selector(Preview.togglePreviewDetached(_:)))
  private let body = NSView()
  private var watch: DispatchSourceFileSystemObject?
  private var reloading: Task<Void, Never>?

  private static let markdownExtensions: Set = ["md", "markdown", "mdown", "mkd"]

  private var isMarkdown: Bool { url.map { Self.markdownExtensions.contains($0.pathExtension.lowercased()) } ?? false }

  override func loadView() {
    let close = barButton("xmark", "Hide Preview", #selector(Preview.hidePreview(_:)))
    let bar = NSStackView(views: [name, search, placement, close])
    let rule = NSBox()
    let column = NSStackView(views: [bar, rule, body])

    name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    name.setContentHuggingPriority(.defaultLow, for: .horizontal)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    search.controlSize = .small
    search.placeholderString = "Find"
    search.sendsWholeSearchString = true
    search.isHidden = true
    search.delegate = self
    search.target = self
    search.action = #selector(findNext(_:))
    search.widthAnchor.constraint(equalToConstant: 160).isActive = true
    bar.orientation = .horizontal
    bar.spacing = 8
    bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
    rule.boxType = .separator
    column.orientation = .vertical
    column.spacing = 0
    column.translatesAutoresizingMaskIntoConstraints = false

    view = NSView()
    view.addSubview(column)

    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
      view.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
    ] + [bar, rule, body].map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) })
  }

  /// The page's own scripts are off; GitHub's additions run in the app's script world.
  private func markdownView() -> WKWebView {
    let configuration = WKWebViewConfiguration()

    configuration.setURLSchemeHandler(pages, forURLScheme: MarkdownPage.scheme)
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    MarkdownPage.scripts.forEach(configuration.userContentController.addUserScript)

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.setAccessibilityLabel("Preview")
    return webView
  }

  /// Shows `url`, and follows it on disk.
  func show(_ url: URL) {
    loadViewIfNeeded()
    self.url = url
    name.stringValue = url.lastPathComponent
    name.toolTip = url.path

    let content = isMarkdown ? webView : quickLook

    if content.superview !== body {
      body.subviews.forEach { $0.removeFromSuperview() }
      content.frame = body.bounds
      content.autoresizingMask = [.width, .height]
      body.addSubview(content)
    }

    if isMarkdown {
      pages.document = url
      webView.load(URLRequest(url: MarkdownPage.address(of: url)))
    } else {
      endFind()
      quickLook.previewItem = url as NSURL
    }

    watchFile()
  }

  /// Says where the view sits, on the bar's placement button.
  func placed(inPane: Bool) {
    loadViewIfNeeded()

    let label = inPane ? "Detach Preview" : "Attach Preview"

    placement.image = NSImage(systemSymbolName: inPane ? "macwindow.on.rectangle" : "sidebar.right", accessibilityDescription: label)
    placement.toolTip = label
    placement.setAccessibilityLabel(label)
  }

  func stop() {
    watch?.cancel()
    watch = nil
    reloading?.cancel()
  }

  /// Watches the file's descriptor. A save that replaces the file, as many editors do, ends the watch, so every event starts a new one.
  private func watchFile() {
    watch?.cancel()
    watch = nil
    guard let url else { return }

    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fileChanged() } }
    source.setCancelHandler { Darwin.close(descriptor) }
    source.resume()
    watch = source
  }

  /// Waits for a burst of writes to settle before reading the file again. Markdown swaps the article in place, so the scroll position stays.
  private func fileChanged() {
    reloading?.cancel()
    reloading = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, !Task.isCancelled, let url else { return }

      if !isMarkdown {
        quickLook.refreshPreviewItem()
      } else if webView.isLoading {
        webView.reload()
      } else {
        let body = (try? String(contentsOf: url, encoding: .utf8)).map(MarkdownPage.body) ?? "Could not read \(url.path)"
        _ = try? await webView.callAsyncJavaScript("update(html)", arguments: ["html": body], contentWorld: .defaultClient)
      }

      watchFile()
    }
  }

  /// In-page anchors scroll; a path link opens its file in the file's default app, resolved against the previewed file's folder; a web link opens in the browser.
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let link = action.request.url else { return .cancel }
    guard action.navigationType == .linkActivated else { return link.scheme == MarkdownPage.scheme ? .allow : .cancel }

    let string = link.scheme == MarkdownPage.scheme ? link.path(percentEncoded: false) : link.absoluteString
    guard let url, let target = FilePaths.target(ofLink: string, in: url.deletingLastPathComponent()) else {
      NSWorkspace.shared.open(link)
      return .cancel
    }

    if target == url.standardizedFileURL { return .allow }

    if FileManager.default.fileExists(atPath: target.path) {
      NSWorkspace.shared.open(target)
    } else {
      NSSound.beep()
    }

    return .cancel
  }

  /// WKWebView has no find bar of its own, so the menu's find items drive a field in the preview's bar.
  override func performTextFinderAction(_ sender: Any?) {
    guard isMarkdown, let action = (sender as? NSMenuItem).flatMap({ NSTextFinder.Action(rawValue: $0.tag) }) else { return }

    switch action {
    case .showFindInterface:
      search.isHidden = false
      view.window?.makeFirstResponder(search)
    case .nextMatch: find(backwards: false)
    case .previousMatch: find(backwards: true)
    case .hideFindInterface: endFind()
    default: break
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(performTextFinderAction(_:)) else { return true }
    guard isMarkdown, let action = NSTextFinder.Action(rawValue: menuItem.tag) else { return false }

    return [.showFindInterface, .nextMatch, .previousMatch, .hideFindInterface].contains(action)
  }

  @objc private func findNext(_ sender: Any?) { find(backwards: false) }

  private func find(backwards: Bool) {
    guard !search.stringValue.isEmpty else { return }

    let configuration = WKFindConfiguration()
    configuration.backwards = backwards

    webView.find(search.stringValue, configuration: configuration) { result in
      if !result.matchFound { NSSound.beep() }
    }
  }

  private func endFind() {
    guard !search.isHidden else { return }

    search.isHidden = true
    view.window?.makeFirstResponder(webView)
  }

  /// Escape in the find field hides it.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }

    endFind()
    return true
  }
}

/// A borderless symbol button whose action goes to the responder chain, where the window hands it to the preview.
/// A borderless symbol button for a pane's bar, sent up the responder chain.
@MainActor
func barButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
  let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: action)

  button.isBordered = false
  button.toolTip = label
  button.setAccessibilityLabel(label)
  button.setContentHuggingPriority(.required, for: .horizontal)
  return button
}
