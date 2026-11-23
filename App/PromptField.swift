import AppKit

/// The prompt: a text view that grows from one line to eight, and the Send or Stop button, in a glass capsule.
final class PromptField: NSView, NSTextViewDelegate {
  let textView = PromptTextView(usingTextLayoutManager: true)
  var onSend: () -> Void = {}
  var onStop: () -> Void = {}

  /// A turn is running, so an empty draft offers Stop where Send would be.
  var isBusy = false {
    didSet {
      if isBusy != oldValue { updateButton() }
    }
  }

  var draft: String {
    get { textView.string }
    set {
      textView.string = newValue
      textView.undoManager?.removeAllActions()
      textView.didChangeText()
    }
  }

  private static let font = NSFont.systemFont(ofSize: 14)
  private static let lineHeight = ceil(font.ascender - font.descender + font.leading)
  private static let oneLineHeight = 30.0
  private static let padding = 6.0
  private let scrollView = NSScrollView()
  private let button = NSButton()
  private lazy var height = heightAnchor.constraint(equalToConstant: Self.oneLineHeight + Self.padding * 2)
  private var isDraftEmpty: Bool { textView.string.allSatisfy(\.isWhitespace) }
  private var stops: Bool { isBusy && isDraftEmpty }

  init() {
    super.init(frame: .zero)
    let glass = NSGlassEffectView()
    let content = NSView()

    textView.delegate = self
    textView.font = Self.font
    textView.isRichText = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 0, height: (Self.oneLineHeight - Self.lineHeight) / 2)
    textView.isContinuousSpellCheckingEnabled = true
    textView.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
    textView.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
    textView.isAutomaticQuoteSubstitutionEnabled = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
    textView.isAutomaticDashSubstitutionEnabled = NSSpellChecker.isAutomaticDashSubstitutionEnabled
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.onSubmit = { [unowned self] in onSend() }
    textView.setAccessibilityLabel("Prompt")

    scrollView.documentView = textView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    button.isBordered = false
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(pressButton)

    glass.cornerRadius = 21
    glass.contentView = content
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)

    for view in [scrollView, button] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }

    NSLayoutConstraint.activate([
      height,
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),
      scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.padding),
      scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      scrollView.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),
      button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
      button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.padding),
      button.widthAnchor.constraint(equalToConstant: Self.oneLineHeight),
      button.heightAnchor.constraint(equalToConstant: Self.oneLineHeight)
    ])

    // The text rewraps when the field's width changes, which changes the height it needs.
    NotificationCenter.default.addObserver(self, selector: #selector(fitHeight), name: NSView.frameDidChangeNotification, object: textView)
    updateButton()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("PromptField is built in code") }

  /// A click in the capsule's padding lands in the text.
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(textView)
  }

  func textDidChange(_ notification: Notification) {
    fitHeight()
    updateButton()
  }

  /// Send is accent colored only in the main window, like every other control.
  func updateButton() {
    let label = stops ? "Stop Claude" : "Send"
    let symbol = stops ? "stop.circle.fill" : "arrow.up.circle.fill"
    var tint = NSColor.secondaryLabelColor

    if !stops, window?.isMainWindow == true { tint = .controlAccentColor }

    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
    button.contentTintColor = tint
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.isEnabled = stops || !isDraftEmpty
  }

  @objc private func pressButton() {
    if stops { return onStop() }

    onSend()
  }

  @objc private func fitHeight() {
    guard let layout = textView.textLayoutManager else { return assertionFailure("The prompt fell back to TextKit 1") }

    layout.ensureLayout(for: layout.documentRange)
    let inset = textView.textContainerInset.height * 2
    let text = min(max(layout.usageBoundsForTextContainer.height + inset, Self.oneLineHeight), Self.lineHeight * 8 + inset)
    let wanted = ceil(text) + Self.padding * 2

    if height.constant != wanted { height.constant = wanted }
  }
}
