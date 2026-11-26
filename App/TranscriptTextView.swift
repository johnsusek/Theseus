import AppKit

/// The transcript's text. A click on a tool sentence opens or closes it, a right-click offers Copy for what is under it,
/// and Copy leaves out the characters that stand in for attached views.
final class TranscriptTextView: NSTextView {
  var onToggle: (String) -> Void = { _ in }
  /// The items for a right-click at a character offset. Empty gets the standard text menu.
  var contextItems: (Int) -> [NSMenuItem] = { _ in [] }
  /// The character offset of the paragraph under the pointer, or nil once it leaves the text.
  var onHover: (Int?) -> Void = { _ in }

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

  private lazy var pointerArea = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if !trackingAreas.contains(pointerArea) { addTrackingArea(pointerArea) }
  }

  /// The I-beam shows only over selectable text, and never over a tool sentence, since a click there toggles it.
  override func resetCursorRects() {}

  override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }

  override func mouseExited(with event: NSEvent) { onHover(nil) }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    onHover(paragraphOffset(at: point))
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

  /// Cards and code blocks' buttons are views inside the text, which the text's accessibility element leaves out, so they join its children.
  override func accessibilityChildren() -> [Any]? {
    func cards(in view: NSView) -> [NSView] { view.subviews.flatMap { $0 is any CardContent || $0 is CodeButtonsView ? [$0] : cards(in: $0) } }

    return (super.accessibilityChildren() ?? []) + NSAccessibility.unignoredChildren(from: cards(in: self))
  }

  /// A tool sentence on screen opens and closes with a click, so VoiceOver and other assistive apps get an action for each.
  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    guard let storage = textStorage, let content = textContentStorage, let viewport = textLayoutManager?.textViewportLayoutController.viewportRange else { return super.accessibilityCustomActions() }

    let start = content.offset(from: content.documentRange.location, to: viewport.location)
    let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
    var actions: [NSAccessibilityCustomAction] = []
    toggleActions = [:]

    storage.enumerateAttribute(.toggle, in: NSRange(location: start, length: max(end - start, 0))) { value, range, _ in
      guard let id = value as? String else { return }

      let sentence = (storage.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
      let name = "Show or Hide “\(sentence.prefix(80))”"
      toggleActions[name] = id
      actions.append(NSAccessibilityCustomAction(name: name, target: self, selector: #selector(performToggle(_:))))
    }

    return (super.accessibilityCustomActions() ?? []) + actions
  }

  /// The toggle id behind each custom action's name, from the last time assistive apps asked for them.
  private var toggleActions: [String: String] = [:]

  @objc private func performToggle(_ action: NSAccessibilityCustomAction) -> Bool {
    guard let id = toggleActions[action.name] else { return false }

    onToggle(id)
    return true
  }

  /// Return or Enter opens or closes the tool sentence the selection is in, as a click on it would.
  override func keyDown(with event: NSEvent) {
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    let location = selectedRange().location

    if isReturn, event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty, let storage = textStorage, location < storage.length, let id = storage.attribute(.toggle, at: location, effectiveRange: nil) as? String {
      return onToggle(id)
    }

    super.keyDown(with: event)
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

  /// Plain and rich text only: RTFD would carry the attachments' placeholder files.
  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.rtf, .string] }

  /// Copy and drags go through here rather than the one-type variant, so both types are written here, from the cleaned selection.
  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    let text = copiedSelection()
    pboard.declareTypes(types.filter { $0 == .rtf || $0 == .string }, owner: nil)

    if types.contains(.rtf), let rtf = text.rtf(from: NSRange(location: 0, length: text.length)) { pboard.setData(rtf, forType: .rtf) }

    return pboard.setString(text.string, forType: .string)
  }

  override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    writeSelection(to: pboard, types: [type])
  }

  /// The selection without the characters that stand in for views, and with line separators as newlines.
  /// A code block's buttons follow a tab at the end of its first line, and table rows wrap with line separators.
  func copiedSelection() -> NSAttributedString {
    let text = NSMutableAttributedString()
    let storage = attributedString()

    for (index, range) in selectedRanges.map(\.rangeValue).enumerated() where range.length > 0 {
      if index > 0, text.length > 0 { text.append(NSAttributedString(string: "\n")) }

      text.append(storage.attributedSubstring(from: range))
    }

    text.removeAttribute(.attachment, range: NSRange(location: 0, length: text.length))

    // A table row reads as its cells, each whole, rather than as its wrapped lines.
    text.enumerateAttribute(.copyText, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, _ in
      guard let value = value as? String, let copy = value.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).last else { return }

      let line = (text.string as NSString).substring(with: range).hasSuffix("\n") ? NSRange(location: range.location, length: range.length - 1) : range
      text.replaceCharacters(in: line, with: String(copy))
    }

    for (target, replacement) in [("\t\u{FFFC}", ""), ("\u{FFFC}", ""), ("\u{2028}", "\n")] {
      text.mutableString.replaceOccurrences(of: target, with: replacement, options: [], range: NSRange(location: 0, length: text.length))
    }

    return text
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
