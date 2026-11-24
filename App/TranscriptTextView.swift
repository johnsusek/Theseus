import AppKit

/// The transcript's text. A click on a tool sentence opens or closes it, a right-click offers Copy for what is under it,
/// and Copy leaves out the characters that stand in for attached views.
final class TranscriptTextView: NSTextView {
  var onToggle: (String) -> Void = { _ in }
  /// The items for a right-click at a character offset. Empty gets the standard text menu.
  var contextItems: (Int) -> [NSMenuItem] = { _ in [] }

  /// The tracking loop inside `super` returns at mouse up. A click that neither moved nor selected anything is a toggle,
  /// so dragging across a tool sentence still selects it.
  override func mouseDown(with event: NSEvent) {
    let start = convert(event.locationInWindow, from: nil)
    let isPlain = event.clickCount == 1 && event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty
    let toggle = isPlain ? toggleId(at: start) : nil

    super.mouseDown(with: event)
    guard let toggle, let window, selectedRange().length == 0 else { return }

    let end = convert(window.mouseLocationOutsideOfEventStream, from: nil)

    if hypot(end.x - start.x, end.y - start.y) < 3 { onToggle(toggle) }
  }

  private lazy var pointerArea = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if !trackingAreas.contains(pointerArea) { addTrackingArea(pointerArea) }
  }

  /// The I-beam shows only over selectable text, and never over a tool sentence, since a click there toggles it.
  override func resetCursorRects() {}

  override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let hit = superview.flatMap { hitTest(convert(point, to: $0)) }
    var isText = false

    if hit === self, attributes(at: point)?[.link] != nil {
      return NSCursor.pointingHand.set()
    } else if hit === self {
      isText = toggleId(at: point) == nil && attributes(at: point).map { $0[.attachment] == nil } == true
    } else if let field = hit as? NSTextField {
      isText = field.isSelectable
    } else if let view = hit as? NSTextView {
      isText = view.isSelectable
    }

    (isText ? NSCursor.iBeam : NSCursor.arrow).set()
  }

  /// Cards are views inside the text, which the text's accessibility element leaves out, so their controls join its children.
  override func accessibilityChildren() -> [Any]? {
    func cards(in view: NSView) -> [NSView] { view.subviews.flatMap { $0 is any CardContent ? [$0] : cards(in: $0) } }

    return (super.accessibilityChildren() ?? []) + NSAccessibility.unignoredChildren(from: cards(in: self))
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)

    // A right-click inside the selection acts on the selection.
    if selectedRange().length > 0, NSLocationInRange(characterIndexForInsertion(at: point), selectedRange()) { return super.menu(for: event) }

    guard let offset = paragraphOffset(at: point) else { return super.menu(for: event) }

    let items = contextItems(offset)
    guard !items.isEmpty else { return super.menu(for: event) }

    let menu = NSMenu()
    menu.items = items
    return menu
  }

  override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard type == .string else { return super.writeSelection(to: pboard, type: type) }

    let text = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
    return pboard.setString(text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string)
  }

  private func fragment(at point: NSPoint) -> (fragment: NSTextLayoutFragment, local: CGPoint)? {
    let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    guard let fragment = textLayoutManager?.textLayoutFragment(for: inContainer) else { return nil }

    return (fragment, CGPoint(x: inContainer.x - fragment.layoutFragmentFrame.minX, y: inContainer.y - fragment.layoutFragmentFrame.minY))
  }

  /// The toggle id of the paragraph whose text is under `point`.
  func toggleId(at point: NSPoint) -> String? {
    guard let hit = fragment(at: point), hit.fragment.textLineFragments.contains(where: { $0.typographicBounds.contains(hit.local) }) else { return nil }
    guard let text = (hit.fragment.textElement as? NSTextParagraph)?.attributedString, text.length > 0 else { return nil }

    return text.attribute(.toggle, at: 0, effectiveRange: nil) as? String
  }

  /// The attributes of the character under `point`, when it is over a line's glyphs rather than its margins or an empty line.
  private func attributes(at point: NSPoint) -> [NSAttributedString.Key: Any]? {
    guard let hit = fragment(at: point), let line = hit.fragment.textLineFragments.first(where: { $0.typographicBounds.contains(hit.local) }) else { return nil }

    let index = line.characterIndex(for: CGPoint(x: hit.local.x - line.typographicBounds.minX, y: hit.local.y - line.typographicBounds.minY))
    guard index >= 0, index < line.attributedString.length else { return nil }

    return line.attributedString.attributes(at: index, effectiveRange: nil)
  }

  /// The character offset where the paragraph at `point` starts.
  private func paragraphOffset(at point: NSPoint) -> Int? {
    guard let content = textContentStorage, let hit = fragment(at: point) else { return nil }

    return content.offset(from: content.documentRange.location, to: hit.fragment.rangeInElement.location)
  }
}
