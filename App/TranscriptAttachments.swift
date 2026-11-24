import AppKit
import ImageIO

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

  /// AppKit can archive the transcript's text. A copy that is unarchived has no view to make, so it decodes to nothing.
  required init?(coder: NSCoder) { nil }

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

/// The moving ellipsis on a running tool call or turn.
final class StatusMarkView: NSImageView, ActiveAppearing {
  var isActive: Bool {
    didSet { contentTintColor = isActive ? .systemOrange : .secondaryLabelColor }
  }

  init(isActive: Bool) {
    self.isActive = isActive
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Running")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    imageScaling = .scaleNone
    contentTintColor = isActive ? .systemOrange : .secondaryLabelColor
    toolTip = "Running"

    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { addSymbolEffect(.variableColor.iterative, options: .repeating) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("StatusMarkView is built in code") }
}

/// The running turn's timer, which counts up by itself so the transcript's text does not change every second.
/// Heading a group, it draws the group's chevron after its text, which changes width.
final class ClockView: NSTextField {
  static let font = TranscriptStyle.digits
  /// Room for "10h 59m" and a chevron, so the view keeps its size as the time grows.
  static let size = NSSize(width: ceil(NSAttributedString(string: "10h 59m  ", attributes: [.font: font]).size().width) + 14, height: 17)

  private let since: Date
  private let chevron: Bool?
  private var ticker: Task<Void, Never>?

  init(since: Date, chevron: Bool?) {
    self.since = since
    self.chevron = chevron
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    textColor = .secondaryLabelColor
    setAccessibilityLabel("Elapsed")
    tick()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ClockView is built in code") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    ticker?.cancel()
    ticker = window == nil ? nil : everySecond(self) { $0.tick() }
  }

  /// A click goes to the transcript, which opens or closes the group.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func tick() {
    let text = NSMutableAttributedString(string: elapsedText(max(Int(Date.now.timeIntervalSince(since)), 0)), attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])

    if let chevron {
      text.append(NSAttributedString(string: "  ", attributes: [.font: Self.font]))
      text.append(TranscriptStyle.symbol(chevron ? "chevron.down" : "chevron.right", pointSize: 9, weight: .semibold))
    }

    attributedStringValue = text
  }
}

/// An image a tool call returned, cropped to fill a small rounded frame.
final class ThumbnailView: NSView {
  private static let images = NSCache<NSString, CGImage>()

  init(_ thumbnail: Thumbnail) {
    super.init(frame: NSRect(origin: .zero, size: TranscriptStyle.thumbnailSize))
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    layer?.contentsGravity = .resizeAspectFill
    layer?.contents = Self.image(thumbnail)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ThumbnailView is built in code") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() { layer?.borderColor = NSColor.separatorColor.cgColor }

  /// A click goes to the transcript, which opens or closes the row.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Decoded once per image, at a size for the frame.
  private static func image(_ thumbnail: Thumbnail) -> CGImage? {
    if let image = images.object(forKey: thumbnail.id as NSString) { return image }

    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
    guard let source = CGImageSourceCreateWithData(thumbnail.data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      log.error("Could not decode the image of \(thumbnail.id, privacy: .public)")
      return nil
    }

    images.setObject(image, forKey: thumbnail.id as NSString)
    return image
  }
}
