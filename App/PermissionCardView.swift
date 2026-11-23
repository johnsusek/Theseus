import AppKit

/// What a card keeps while the text view rebuilds its view, which it does whenever the card scrolls far out of sight.
@MainActor
final class PermissionCardState {
  var always = false
}

/// A permission request in the transcript: what the tool would do, a checkbox to stop asking, and the two answers.
/// Its buttons have no key equivalents: Return belongs to the prompt field, and the Session menu carries the shortcuts.
final class PermissionCardView: NSView, CardContent, ActiveAppearing {
  private static let padding = 12.0
  private static let spacing = 10.0
  private static let titleHeight = 18.0
  private let icon = NSImageView()
  private let title: NSTextField
  private let bodyScroll = CardScrollView()
  private let bodyText = NSTextView(usingTextLayoutManager: true)
  private let checkbox: NSButton?
  private let deny: NSButton
  private let allow: NSButton
  private let bodyLimit: CGFloat
  private let state: PermissionCardState
  private let layoutDelegate: TranscriptLayoutDelegate
  private let answer: (Bool) -> Void

  var isActive: Bool {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  /// `body` scrolls inside the card once it is taller than `bodyLimit`.
  init(prompt: PermissionPrompt, body: NSAttributedString, bodyLimit: CGFloat, layoutDelegate: TranscriptLayoutDelegate, state: PermissionCardState, isActive: Bool, answer: @escaping (Bool) -> Void) {
    title = NSTextField(labelWithString: prompt.title)
    checkbox = prompt.checkbox.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    deny = NSButton(title: prompt.denyTitle, target: nil, action: nil)
    allow = NSButton(title: prompt.allowTitle, target: nil, action: nil)
    self.bodyLimit = bodyLimit
    self.layoutDelegate = layoutDelegate
    self.state = state
    self.isActive = isActive
    self.answer = answer
    super.init(frame: .zero)

    icon.image = NSImage(systemSymbolName: prompt.symbol, accessibilityDescription: nil)
    icon.contentTintColor = .labelColor
    title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingMiddle
    title.isSelectable = true

    bodyText.isEditable = false
    bodyText.drawsBackground = false
    bodyText.isVerticallyResizable = true
    bodyText.isHorizontallyResizable = false
    bodyText.autoresizingMask = [.width]
    bodyText.textContainerInset = .zero
    bodyText.textContainer?.widthTracksTextView = true
    bodyText.textContainer?.lineFragmentPadding = 0
    bodyText.textLayoutManager?.delegate = layoutDelegate
    bodyText.textStorage?.setAttributedString(body)
    bodyText.setAccessibilityLabel("Request Details")
    bodyScroll.documentView = bodyText
    bodyScroll.drawsBackground = false
    bodyScroll.hasVerticalScroller = true
    bodyScroll.autohidesScrollers = true
    bodyScroll.isHidden = body.length == 0

    checkbox?.target = self
    checkbox?.action = #selector(toggleAlways)
    checkbox?.state = state.always ? .on : .off
    checkbox?.lineBreakMode = .byTruncatingTail
    deny.target = self
    deny.action = #selector(pressDeny)
    deny.toolTip = "\(prompt.denyTitle) (Command-D)"
    allow.target = self
    allow.action = #selector(pressAllow)
    allow.toolTip = "\(prompt.allowTitle) (Command-Return)"

    for view in [icon, title, bodyScroll, deny, allow] + [checkbox].compactMap({ $0 }) { addSubview(view) }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Permission Request: \(prompt.title)")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("PermissionCardView is built in code") }

  func height(for width: CGFloat) -> CGFloat {
    let body = bodyScroll.isHidden ? 0 : bodyHeight(for: width - Self.padding * 2) + Self.spacing
    return Self.padding + Self.titleHeight + Self.spacing + body + allow.fittingSize.height + Self.padding
  }

  private func bodyHeight(for width: CGFloat) -> CGFloat {
    guard let layout = bodyText.textLayoutManager else { return bodyLimit }

    if bodyText.frame.width != width { bodyText.setFrameSize(NSSize(width: width, height: bodyText.frame.height)) }

    layout.ensureLayout(for: layout.documentRange)
    return min(ceil(layout.usageBoundsForTextContainer.height), bodyLimit)
  }

  override func layout() {
    super.layout()
    let inner = bounds.width - Self.padding * 2
    let allowSize = allow.fittingSize
    let denySize = deny.fittingSize
    let buttonsTop = bounds.height - Self.padding - allowSize.height
    let denyLeft = bounds.width - Self.padding - allowSize.width - 8 - denySize.width

    icon.frame = NSRect(x: Self.padding, y: Self.padding + 1, width: 16, height: 16)
    title.frame = NSRect(x: Self.padding + 22, y: Self.padding, width: max(inner - 22, 0), height: Self.titleHeight)
    allow.frame = NSRect(origin: NSPoint(x: bounds.width - Self.padding - allowSize.width, y: buttonsTop), size: allowSize)
    deny.frame = NSRect(origin: NSPoint(x: denyLeft, y: buttonsTop), size: denySize)

    if !bodyScroll.isHidden {
      let top = Self.padding + Self.titleHeight + Self.spacing
      bodyScroll.frame = NSRect(x: Self.padding, y: top, width: inner, height: max(buttonsTop - Self.spacing - top, 0))
    }

    if let checkbox {
      let size = checkbox.fittingSize
      checkbox.frame = NSRect(x: Self.padding, y: buttonsTop + (allowSize.height - size.height) / 2, width: min(size.width, max(denyLeft - 12 - Self.padding, 0)), height: size.height)
    }
  }

  /// An orange wash and border, gray in an inactive window.
  override func draw(_ dirtyRect: NSRect) {
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    let tint = isActive ? NSColor.systemOrange : NSColor.secondaryLabelColor

    tint.withAlphaComponent(0.06).setFill()
    outline.fill()
    tint.withAlphaComponent(0.5).setStroke()
    outline.stroke()
  }

  @objc private func toggleAlways() {
    state.always = checkbox?.state == .on
  }

  @objc private func pressAllow() {
    answer(true)
  }

  @objc private func pressDeny() {
    answer(false)
  }
}

/// A card's scrolling body. While its text fits, the wheel scrolls the transcript around it instead of stopping dead over the card.
private final class CardScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    if (documentView?.frame.height ?? 0) <= contentSize.height + 0.5 { return nextResponder?.scrollWheel(with: event) ?? () }

    super.scrollWheel(with: event)
  }
}
