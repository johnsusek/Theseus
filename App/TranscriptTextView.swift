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

  /// The character offset where the paragraph at `point` starts.
  private func paragraphOffset(at point: NSPoint) -> Int? {
    guard let content = textContentStorage, let hit = fragment(at: point) else { return nil }

    return content.offset(from: content.documentRange.location, to: hit.fragment.rangeInElement.location)
  }
}
