import AppKit

/// A view in the transcript whose colors follow whether its window is main.
@MainActor
protocol ActiveAppearing: NSView {
  var isActive: Bool { get set }
}

/// A card's content: it says how tall it is at the column's width.
@MainActor
protocol CardContent: NSView {
  func height(for width: CGFloat) -> CGFloat
}

/// A real view in the text. A card fills the column's width and sets its own height; a mark has a fixed size on the text's line.
final class ViewAttachment: NSTextAttachment {
  private let makeView: @MainActor () -> NSView
  private let size: NSSize?

  /// `size` fixes the view's size, a little under the baseline. Without it the view is a card.
  init(size: NSSize? = nil, makeView: @escaping @MainActor () -> NSView) {
    self.makeView = makeView
    self.size = size
    super.init(data: nil, ofType: nil)
    // An attachment with no image draws a document icon under its view.
    image = NSImage(size: NSSize(width: 1, height: 1))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ViewAttachment is built in code") }

  /// Without a registered provider class for its file type, an attachment reports no view unless told otherwise.
  override var usesTextAttachmentView: Bool { true }

  override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
    let provider = Provider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
    provider.makeView = makeView
    provider.size = size
    provider.tracksTextAttachmentViewBounds = true
    return provider
  }

  /// AppKit asks for the view and its bounds on the main thread, during layout, through methods it does not mark as such.
  private final class Provider: NSTextAttachmentViewProvider {
    var makeView: @MainActor () -> NSView = { NSView() }
    var size: NSSize?

    override func loadView() {
      let make = makeView
      view = MainActor.assumeIsolated { Unchecked(value: make()) }.value
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
      if let size { return CGRect(x: 0, y: -3, width: size.width, height: size.height) }

      let width = proposedLineFragment.width - position.x
      let card = Unchecked(value: view)
      return CGRect(x: 0, y: 0, width: width, height: MainActor.assumeIsolated { (card.value as? any CardContent)?.height(for: width) ?? 0 })
    }
  }
}

/// Carries a value AppKit hands over on the main thread across an isolation check the compiler cannot see through.
private struct Unchecked<Value>: @unchecked Sendable {
  let value: Value
}

/// The moving ellipsis on a running tool call, or the red mark on a failed one.
final class StatusMarkView: NSImageView, ActiveAppearing {
  private let tint: NSColor

  var isActive: Bool {
    didSet { contentTintColor = isActive ? tint : .secondaryLabelColor }
  }

  init(_ mark: StatusMark, isActive: Bool) {
    let isRunning = mark == .running
    let label = isRunning ? "Running" : "Failed"
    tint = isRunning ? .systemOrange : .systemRed
    self.isActive = isActive
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: isRunning ? "ellipsis" : "exclamationmark.circle.fill", accessibilityDescription: label)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    imageScaling = .scaleNone
    contentTintColor = isActive ? tint : .secondaryLabelColor
    toolTip = label

    if isRunning { addSymbolEffect(.variableColor.iterative, options: .repeating) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("StatusMarkView is built in code") }
}
