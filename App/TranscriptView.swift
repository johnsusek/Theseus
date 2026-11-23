import AppKit
import ClaudeEngine

/// The conversation as one read-only text view, so selection and Find span all of it.
/// The text is a list of elements; an update replaces only the ranges of the elements that changed.
final class TranscriptView: NSView {
  let textView = TranscriptTextView(usingTextLayoutManager: true)
  /// Answers a permission request from its card or from the Session menu.
  var onDecision: (PermissionRequest, PermissionDecision) -> Void = { _, _ in }

  /// Space kept clear under the last line, for the prompt field floating over the bottom edge.
  var bottomInset = 0.0 {
    didSet {
      guard bottomInset != oldValue else { return }

      scrollView.contentInsets.bottom = bottomInset

      if isPinned { scrollToBottom() }
    }
  }

  /// A verbose transcript expands every tool call and shows thinking.
  var isVerbose: Bool {
    get { builder.isVerbose }
    set {
      builder.isVerbose = newValue
      update(keepsPosition: true)
    }
  }

  var hasPendingRequest: Bool { !requests.isEmpty }

  private let scrollView = NSScrollView()
  private let layoutDelegate = TranscriptLayoutDelegate()
  private var builder = TranscriptBuilder()
  private var renderer = TranscriptRenderer()
  private var input = TranscriptInput()
  private var projectName = ""
  /// Unanswered requests, oldest first.
  private var requests: [PermissionRequest] = []
  private var cardStates: [String: PermissionCardState] = [:]
  private var rendered: [(element: TranscriptElement, length: Int)] = []
  /// The view follows new text while it sits at the bottom; scrolling up lets go.
  private var isPinned = true
  private var isScrollingToBottom = false
  private var clipSize = NSSize.zero

  private var isActive: Bool { layoutDelegate.state.isActive }
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
    textView.textLayoutManager?.delegate = layoutDelegate
    textView.setAccessibilityLabel("Transcript")
    textView.onToggle = { [unowned self] id in
      builder.toggle(id)
      update(keepsPosition: true)
    }
    textView.contextItems = { [unowned self] offset in contextItems(at: offset) }

    renderer.card = { [unowned self] element in card(for: element) }
    renderer.mark = { [unowned self] mark in
      ViewAttachment(size: NSSize(width: 18, height: 14)) { [state = layoutDelegate.state] in StatusMarkView(mark, isActive: state.isActive) }
    }

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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowActiveChanged()
  }

  /// The text sits in a centered column at most 720 pt wide, at least 20 pt from the edges.
  override func layout() {
    super.layout()
    let inset = NSSize(width: max(20, floor((bounds.width - 720) / 2)), height: 20)

    if textView.textContainerInset != inset { textView.textContainerInset = inset }

    fitBubbles()
  }

  /// Shows the conversation as it is now. `requests` are the unanswered permission prompts, oldest first.
  func show(_ input: TranscriptInput, requests: [PermissionRequest], projectName: String) {
    let known = Set(self.requests.map(\.requestId))
    let arrived = requests.first { !known.contains($0.requestId) }

    self.input = input
    self.requests = requests
    self.projectName = projectName
    cardStates = cardStates.filter { state in requests.contains { $0.requestId == state.key } }
    update(keepsPosition: false)

    if let arrived, isPinned { reveal("permission/\(arrived.requestId)") }
  }

  /// Session > Allow and Deny answer the oldest request as its card's buttons would.
  func answerOldestRequest(allow: Bool) {
    guard let request = requests.first else { return }

    answer(request, allow: allow)
  }

  /// Colored marks are for the main window: diff tints, line counts, running and failed marks, and the cards' orange.
  func windowActiveChanged() {
    let isActive = window?.isMainWindow ?? false
    guard isActive != layoutDelegate.state.isActive, let content = textView.textContentStorage, let storage = content.textStorage else { return }

    layoutDelegate.state.isActive = isActive
    content.performEditingTransaction { tint(storage, in: NSRange(location: 0, length: storage.length)) }
    refresh(textView)
  }

  /// Fragments draw into views of their own, which redraw only when told to.
  private func refresh(_ view: NSView) {
    (view as? any ActiveAppearing)?.isActive = isActive
    view.needsDisplay = true

    for child in view.subviews { refresh(child) }
  }

  private func tint(_ storage: NSTextStorage, in range: NSRange) {
    storage.enumerateAttribute(.activeTint, in: range) { value, subrange, _ in
      guard let color = value as? NSColor else { return }

      storage.addAttribute(.foregroundColor, value: isActive ? color : NSColor.secondaryLabelColor, range: subrange)
    }
  }

  // MARK: Text

  /// Rebuilds the elements and replaces the text of those that changed. Text above a change is not touched, so a selection there stays.
  /// `keepsPosition` is for a change the user made by clicking, which should not move what is under the pointer.
  private func update(keepsPosition: Bool) {
    let fresh = builder.elements(for: input)
    let edits = elementEdits(from: rendered.map(\.element), to: fresh)
    guard !edits.isEmpty else { return }
    guard let content = textView.textContentStorage, let storage = content.textStorage else { return assertionFailure("The transcript fell back to TextKit 1") }

    let starts = rendered.reduce(into: [0]) { starts, entry in starts.append(starts[starts.count - 1] + entry.length) }

    // Letting go of the bottom first keeps the resize that follows from scrolling the clicked row away.
    if keepsPosition { isPinned = false }

    content.performEditingTransaction {
      for edit in edits {
        let range = NSRange(location: starts[edit.old.lowerBound], length: starts[edit.old.upperBound] - starts[edit.old.lowerBound])
        let pieces = edit.new.map { renderer.attributedString(for: fresh[$0], terminated: $0 < fresh.count - 1) }
        let text = NSMutableAttributedString()

        for piece in pieces { text.append(piece) }

        // An element that only grew or changed its end keeps the text they share, as a streaming reply does on every delta.
        let isSameElement = edit.old.count == 1 && edit.new.count == 1 && rendered[edit.old.lowerBound].element.id == fresh[edit.new.lowerBound].id
        let shared = isSameElement ? commonPrefixLength(storage.attributedSubstring(from: range), text) : 0

        storage.replaceCharacters(in: NSRange(location: range.location + shared, length: range.length - shared), with: text.attributedSubstring(from: NSRange(location: shared, length: text.length - shared)))
        rendered.replaceSubrange(edit.old, with: zip(edit.new, pieces).map { (fresh[$0], $1.length) })
      }

      if !isActive { tint(storage, in: NSRange(location: 0, length: storage.length)) }
    }

    layoutSubtreeIfNeeded()

    if keepsPosition {
      isPinned = isAtBottom
    } else if isPinned {
      scrollToBottom()
    }
  }

  /// A bubble starts where its widest line ends at the column's edge, which moves when the column's width does.
  private func fitBubbles() {
    let width = textView.bounds.width - textView.textContainerInset.width * 2
    guard width > 0, width != renderer.columnWidth, let content = textView.textContentStorage, let storage = content.textStorage else { return }

    renderer.columnWidth = width

    content.performEditingTransaction {
      storage.enumerateAttribute(.bubbleWidth, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        guard let textWidth = value as? CGFloat else { return }

        let indent = TranscriptStyle.bubbleIndent(textWidth: textWidth, columnWidth: width)

        storage.enumerateAttribute(.paragraphStyle, in: range) { style, subrange, _ in
          guard let style = (style as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle, style.headIndent != indent else { return }

          style.headIndent = indent
          style.firstLineHeadIndent = indent
          storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
      }
    }
  }

  private func range(of id: String) -> NSRange? {
    var location = 0

    for entry in rendered {
      if entry.element.id == id { return NSRange(location: location, length: entry.length) }

      location += entry.length
    }

    return nil
  }

  private func element(at offset: Int) -> TranscriptElement? {
    var end = 0

    for entry in rendered {
      end += entry.length

      if offset < end { return entry.element }
    }

    return rendered.last?.element
  }

  // MARK: Cards

  private func card(for element: TranscriptElement) -> NSTextAttachment {
    switch element.kind {
    case .tasks(let tasks):
      return ViewAttachment { TaskCardView(tasks: tasks) }
    case .permission(let requestId):
      guard let request = requests.first(where: { $0.requestId == requestId }) else { return NSTextAttachment() }

      let prompt = PermissionPrompt(request, projectName: projectName)
      let body = renderer.permissionBody(prompt.body)
      let state = cardStates[requestId] ?? PermissionCardState()
      cardStates[requestId] = state

      return ViewAttachment { [unowned self] in
        // A plan is read in full before it is approved, so it gets more room than a command or a diff.
        PermissionCardView(prompt: prompt, body: body, bodyLimit: prompt.isPlan ? 360 : 150, layoutDelegate: layoutDelegate, state: state, isActive: isActive) { [unowned self] allow in answer(request, allow: allow) }
      }
    default:
      return NSTextAttachment()
    }
  }

  private func answer(_ request: PermissionRequest, allow: Bool) {
    onDecision(request, permissionDecision(for: request, allow: allow, always: cardStates[request.requestId]?.always ?? false))
  }

  // MARK: Context menu

  private func contextItems(at offset: Int) -> [NSMenuItem] {
    var source: CopySource?

    switch element(at: offset)?.kind {
    case .prompt(let text), .notice(_, _, let text): source = CopySource(title: "Copy Prompt", text: text)
    case .reply(let text): source = CopySource(title: "Copy Reply", text: text)
    case .tool(let row): source = row.copy
    default: break
    }

    guard let source else { return [] }

    let item = NSMenuItem(title: source.title, action: #selector(copySource(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = source.text
    return [item]
  }

  @objc private func copySource(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: Scrolling

  /// Scrolls an element into view when the pinned bottom does not already show it.
  private func reveal(_ id: String) {
    guard let range = range(of: id), let layout = textView.textLayoutManager, let content = textView.textContentStorage else { return }
    guard let start = content.location(content.documentRange.location, offsetBy: range.location), let end = content.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end) else { return }

    var frame = CGRect.null
    layout.ensureLayout(for: textRange)
    layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
      frame = frame.union(segment)
      return true
    }

    guard !frame.isNull else { return }

    let inView = frame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)

    if inView.minY < scrollView.contentView.bounds.minY { textView.scroll(NSPoint(x: 0, y: inView.minY - 8)) }
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
