import AppKit
import ClaudeEngine

/// The conversation as one read-only text view, so selection and Find span all of it.
/// Committed text is only ever appended; the streaming tail after it is rewritten in place.
final class TranscriptView: NSView {
  let textView = NSTextView(usingTextLayoutManager: true)

  /// Space kept clear under the last line, for the prompt field floating over the bottom edge.
  var bottomInset = 0.0 {
    didSet {
      guard bottomInset != oldValue else { return }

      scrollView.contentInsets.bottom = bottomInset

      if isPinned { scrollToBottom() }
    }
  }

  private static let font = NSFont.systemFont(ofSize: 14)
  private static let reply: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
  private static let tool: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
  private static let prompt: [NSAttributedString.Key: Any] = {
    let style = NSMutableParagraphStyle()
    style.alignment = .right
    return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
  }()

  private let scrollView = NSScrollView()
  private var renderedMessages = 0
  private var committedLength = 0
  private var tail = ""
  /// The view follows new text while it sits at the bottom; scrolling up lets go.
  private var isPinned = true
  private var isScrollingToBottom = false
  private var clipSize = NSSize.zero

  private var isAtBottom: Bool { scrollView.contentView.bounds.maxY >= textView.frame.maxY + scrollView.contentInsets.bottom - 4 }

  init() {
    super.init(frame: .zero)
    textView.isEditable = false
    textView.drawsBackground = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.setAccessibilityLabel("Transcript")

    scrollView.documentView = textView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.autoresizingMask = [.width, .height]
    scrollView.contentView.postsBoundsChangedNotifications = true
    addSubview(scrollView)

    NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    NotificationCenter.default.addObserver(self, selector: #selector(documentResized), name: NSView.frameDidChangeNotification, object: textView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TranscriptView is built in code") }

  /// The text sits in a centered column at most 720 pt wide, at least 20 pt from the edges.
  override func layout() {
    super.layout()
    let inset = NSSize(width: max(20, floor((bounds.width - 720) / 2)), height: 20)

    if textView.textContainerInset != inset { textView.textContainerInset = inset }
  }

  /// Appends what `transcript` gained since the last call, then the reply being written.
  func show(_ transcript: Transcript, streaming: StreamingMessage) {
    let fresh = NSMutableAttributedString()

    func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }

      let separator = committedLength + fresh.length > 0 ? "\n\n" : ""
      fresh.append(NSAttributedString(string: separator + trimmed, attributes: attributes))
    }

    for message in transcript.messages[renderedMessages...] {
      switch message.kind {
      case .user(let user) where message.raw["isReplay"]?.bool == true:
        add(user.content.text, Self.prompt)
      case .assistant(let assistant):
        for block in assistant.message.content {
          switch block {
          case .text(let text):
            add(text, Self.reply)
          case .toolUse(_, let name, let input):
            let detail = input["description"]?.string ?? input["command"]?.string ?? input["file_path"]?.string
            add([name, detail].compactMap { $0 }.joined(separator: ": "), Self.tool)
          default:
            break
          }
        }
      default:
        break
      }
    }

    let committed = fresh.length
    renderedMessages = transcript.messages.count

    for case .text(let text) in streaming.blocks { add(text, Self.reply) }

    let freshTail = fresh.attributedSubstring(from: NSRange(location: committed, length: fresh.length - committed)).string
    guard committed > 0 || freshTail != tail else { return }
    guard let content = textView.textContentStorage, let storage = content.textStorage else { return assertionFailure("The transcript fell back to TextKit 1") }

    content.performEditingTransaction {
      storage.replaceCharacters(in: NSRange(location: committedLength, length: storage.length - committedLength), with: fresh)
    }

    committedLength += committed
    tail = freshTail

    guard isPinned else { return }

    layoutSubtreeIfNeeded()
    scrollToBottom()
  }

  private func scrollToBottom() {
    let clip = scrollView.contentView
    let bottom = max(textView.frame.maxY + scrollView.contentInsets.bottom - clip.bounds.height, 0)
    guard abs(clip.bounds.minY - bottom) > 0.5 else { return }

    isScrollingToBottom = true
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
    scrollView.reflectScrolledClipView(clip)
    isScrollingToBottom = false
  }

  /// A resize keeps the pin; any other move of the clip is a scroll, which sets it.
  @objc private func clipChanged() {
    let size = scrollView.contentView.bounds.size

    if size != clipSize {
      clipSize = size

      if isPinned { scrollToBottom() }
    } else if !isScrollingToBottom {
      isPinned = isAtBottom
    }
  }

  /// TextKit 2 settles the document's height during layout, after the edit that changed it.
  @objc private func documentResized() {
    if isPinned { scrollToBottom() }
  }
}
