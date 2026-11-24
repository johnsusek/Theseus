import AppKit
import Quartz

/// A conversation's preview window, which `show_file` points at a file. Markdown is drawn the way the transcript draws it;
/// anything else goes through Quick Look. It follows the file as it changes on disk.
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  private(set) var url: URL?
  private let layoutDelegate = TranscriptLayoutDelegate()
  private let textView = NSTextView(usingTextLayoutManager: true)
  private let textScroll = NSScrollView()
  private lazy var quickLook = QLPreviewView(frame: .zero, style: .normal)!
  private var watch: DispatchSourceFileSystemObject?
  private var reloading: Task<Void, Never>?

  private static let frameName = "Preview"
  private static let markdownExtensions: Set = ["md", "markdown", "mdown", "mkd"]

  private var isMarkdown: Bool { url.map { Self.markdownExtensions.contains($0.pathExtension.lowercased()) } ?? false }

  init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)

    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentMinSize = NSSize(width: 320, height: 240)
    window.delegate = self
    window.center()
    window.setFrameUsingName(Self.frameName)

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
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("PreviewWindowController is built in code") }

  /// Points the window at `url` and brings it forward without taking focus from the prompt.
  func show(_ url: URL) {
    self.url = url
    window?.title = url.lastPathComponent
    window?.representedURL = url
    window?.contentView = isMarkdown ? textScroll : quickLook
    reload()
    watchFile()
    window?.orderFront(nil)
  }

  private func reload() {
    guard let url else { return }

    guard isMarkdown else { return quickLook.previewItem = url as NSURL }

    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      let width = max(textScroll.contentSize.width - textView.textContainerInset.width * 2, 100)
      textView.textStorage?.setAttributedString(Markdown.paragraphs(source, style: MarkdownStyle(width: width)).joined(terminated: false))
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

  func windowDidEndLiveResize(_ notification: Notification) {
    if isMarkdown { reload() }
  }

  func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

  func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

  func windowDidBecomeMain(_ notification: Notification) { setActive(true) }

  func windowDidResignMain(_ notification: Notification) { setActive(false) }

  func windowWillClose(_ notification: Notification) {
    watch?.cancel()
    watch = nil
    reloading?.cancel()
  }

  /// Code blocks draw gray in an inactive window. Each layout fragment draws in its own subview, so all of them redraw.
  private func setActive(_ isActive: Bool) {
    layoutDelegate.state.isActive = isActive

    func redraw(_ view: NSView) {
      view.needsDisplay = true
      view.subviews.forEach(redraw)
    }

    redraw(textView)
  }
}
