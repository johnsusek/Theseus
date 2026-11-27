import AppKit
import Quartz

/// The preview's view, the same in the conversation's pane and in its own window: a bar with the file's name, and the file.
/// Markdown is drawn the way the transcript draws it; anything else goes through Quick Look. It follows the file as it changes on disk.
final class PreviewViewController: NSViewController, NSTextViewDelegate {
  private(set) var url: URL?
  private let layoutDelegate = TranscriptLayoutDelegate()
  private let textView = NSTextView(usingTextLayoutManager: true)
  private let textScroll = NSScrollView()
  private lazy var quickLook = QLPreviewView(frame: .zero, style: .normal)!
  private let name = NSTextField(labelWithString: "")
  private let placement = barButton("macwindow.on.rectangle", "Detach Preview", #selector(Preview.togglePreviewDetached(_:)))
  private let body = ResizeEndingView()
  private var watch: DispatchSourceFileSystemObject?
  private var reloading: Task<Void, Never>?
  private var renderedWidth = 0.0
  private var observations: [NSObjectProtocol] = []

  private static let markdownExtensions: Set = ["md", "markdown", "mdown", "mkd"]

  private var isMarkdown: Bool { url.map { Self.markdownExtensions.contains($0.pathExtension.lowercased()) } ?? false }
  private var textWidth: Double { max(textScroll.contentSize.width - textView.textContainerInset.width * 2, 100) }

  override func loadView() {
    let close = barButton("xmark", "Hide Preview", #selector(Preview.hidePreview(_:)))
    let bar = NSStackView(views: [name, placement, close])
    let rule = NSBox()
    let column = NSStackView(views: [bar, rule, body])

    name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    name.setContentHuggingPriority(.defaultLow, for: .horizontal)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    bar.orientation = .horizontal
    bar.spacing = 8
    bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
    rule.boxType = .separator
    column.orientation = .vertical
    column.spacing = 0
    column.translatesAutoresizingMaskIntoConstraints = false

    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 24, height: 20)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.textLayoutManager?.delegate = layoutDelegate
    textView.setAccessibilityLabel("Preview")
    textView.delegate = self

    textScroll.documentView = textView
    textScroll.hasVerticalScroller = true
    textScroll.drawsBackground = true
    textScroll.backgroundColor = .textBackgroundColor
    body.onResizeEnd = { [weak self] in self?.rerenderIfWidthChanged() }

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

  /// Shows `url`, and follows it on disk.
  func show(_ url: URL) {
    loadViewIfNeeded()
    self.url = url
    name.stringValue = url.lastPathComponent
    name.toolTip = url.path

    let content = isMarkdown ? textScroll : quickLook

    if content.superview !== body {
      body.subviews.forEach { $0.removeFromSuperview() }
      content.frame = body.bounds
      content.autoresizingMask = [.width, .height]
      body.addSubview(content)
    }

    reload()
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

  override func viewDidLayout() {
    super.viewDidLayout()
    if !body.inLiveResize { rerenderIfWidthChanged() }
  }

  /// Code blocks draw gray in an inactive window, so the view follows its window's main state.
  override func viewDidAppear() {
    super.viewDidAppear()
    observations.forEach(NotificationCenter.default.removeObserver)
    guard let window = view.window else { return }

    observations = [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setActive(window.isMainWindow) } }
    }

    setActive(window.isMainWindow)
  }

  private func rerenderIfWidthChanged() {
    guard isMarkdown, textScroll.superview != nil, abs(textWidth - renderedWidth) > 1 else { return }

    reload()
  }

  private func reload() {
    guard let url else { return }

    guard isMarkdown else { return quickLook.previewItem = url as NSURL }

    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      renderedWidth = textWidth
      textView.textStorage?.setAttributedString(Markdown.paragraphs(source, style: MarkdownStyle(width: renderedWidth)).joined(terminated: false))
    } catch {
      textView.textStorage?.setAttributedString(NSAttributedString(string: "Could not read \(url.path): \(error.localizedDescription)", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.systemRed]))
    }
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

  /// Waits for a burst of writes to settle before reading the file again.
  private func fileChanged() {
    reloading?.cancel()
    reloading = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, !Task.isCancelled else { return }

      if isMarkdown {
        reload()
      } else {
        quickLook.refreshPreviewItem()
      }

      watchFile()
    }
  }

  /// A path link opens its file in the file's default app, resolved against the previewed file's folder.
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url, let target = FilePaths.target(ofLink: link, in: url.deletingLastPathComponent()) else { return false }
    guard FileManager.default.fileExists(atPath: target.path) else {
      NSSound.beep()
      return true
    }

    NSWorkspace.shared.open(target)
    return true
  }

  /// Each layout fragment draws in its own subview, so all of them redraw.
  private func setActive(_ isActive: Bool) {
    layoutDelegate.state.isActive = isActive

    func redraw(_ view: NSView) {
      view.needsDisplay = true
      view.subviews.forEach(redraw)
    }

    redraw(textView)
  }
}

/// Reports the end of a live resize, a window's or a split divider's, so markdown lays out again once at the new width.
private final class ResizeEndingView: NSView {
  var onResizeEnd: () -> Void = {}

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    onResizeEnd()
  }
}

/// A borderless symbol button whose action goes to the responder chain, where the window hands it to the preview.
@MainActor
private func barButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
  let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: action)

  button.isBordered = false
  button.toolTip = label
  button.setAccessibilityLabel(label)
  button.setContentHuggingPriority(.required, for: .horizontal)
  return button
}
