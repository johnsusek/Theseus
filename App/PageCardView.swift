import AppKit

/// A page the browser opened: the picture of it its call returned, over its title and site, with a button that brings the page up in the browser.
final class PageCardView: NSView, CardContent {
  private static let widest = 420.0
  private static let footer = 54.0
  private static let padding = 14.0
  private let picture = NSView()
  private let title: NSTextField
  private let place: NSTextField
  private let button = NSButton(title: "Open", target: nil, action: nil)
  private let open: () -> Void
  /// The picture's height over its width, at most 3:5 so a tall page shows its top.
  private var shape = 0.0

  override var isFlipped: Bool { true }

  init(page: PageCard, open: @escaping () -> Void) {
    title = NSTextField(labelWithString: page.title)
    place = NSTextField(labelWithString: page.place)
    self.open = open
    super.init(frame: .zero)

    title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    place.font = NSFont.systemFont(ofSize: 11)
    place.textColor = .secondaryLabelColor
    place.lineBreakMode = .byTruncatingMiddle
    place.toolTip = page.address
    button.target = self
    button.action = #selector(pressed)
    button.setAccessibilityLabel("Open \(page.title) in the Browser")
    picture.wantsLayer = true
    picture.layer?.cornerRadius = 11.5
    picture.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    picture.layer?.masksToBounds = true

    if let data = page.thumbnail?.data, let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil), image.width > 0 {
      shape = min(Double(image.height) / Double(image.width), 0.6)
      picture.layer?.contents = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int(Double(image.width) * shape)))
    }

    for view in [picture, title, place, button] { addSubview(view) }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Page: \(page.title)")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("PageCardView is built in code") }

  @objc private func pressed() { open() }

  private func cardWidth(in width: CGFloat) -> CGFloat { min(width, Self.widest) }

  func height(for width: CGFloat) -> CGFloat { (cardWidth(in: width) * shape).rounded() + Self.footer }

  override func layout() {
    super.layout()

    let width = cardWidth(in: bounds.width)
    let top = (width * shape).rounded()
    let size = button.fittingSize
    let textWidth = width - Self.padding * 2 - size.width - 4

    picture.frame = NSRect(x: 0.5, y: 0.5, width: width - 1, height: max(0, top - 0.5))
    title.frame = NSRect(x: Self.padding, y: top + 10, width: textWidth, height: 17)
    place.frame = NSRect(x: Self.padding, y: top + 28, width: textWidth, height: 14)
    button.frame = NSRect(origin: NSPoint(x: width - Self.padding + 6 - size.width, y: top + (Self.footer - size.height) / 2), size: size)
  }

  override func draw(_ dirtyRect: NSRect) {
    let width = cardWidth(in: bounds.width)
    let top = (width * shape).rounded()

    NSColor.separatorColor.setStroke()
    NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: bounds.height - 1), xRadius: 12, yRadius: 12).stroke()

    if shape > 0 { NSBezierPath.strokeLine(from: NSPoint(x: 0.5, y: top + 0.5), to: NSPoint(x: width - 0.5, y: top + 0.5)) }
  }
}
