import AppKit

/// The draft. Return submits; Shift-Return and Option-Return insert a newline.
final class PromptTextView: NSTextView {
  var onSubmit: () -> Void = {}
  /// Find searches the transcript, not the draft.
  weak var finder: NSTextView?

  var placeholder = "" {
    didSet {
      setAccessibilityPlaceholderValue(placeholder)
      needsDisplay = true
    }
  }

  /// Option-Return arrives as `insertNewlineIgnoringFieldEditor`, which the text view already handles.
  override func insertNewline(_ sender: Any?) {
    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return super.insertNewline(sender) }

    onSubmit()
  }

  override func performTextFinderAction(_ sender: Any?) {
    finder?.performTextFinderAction(sender)
  }

  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(performTextFinderAction(_:)) else { return super.validateMenuItem(menuItem) }

    return finder?.validateMenuItem(menuItem) ?? false
  }

  /// The text view adds its insertion indicator when it takes focus; without effects it skips the dictation glyph beside the caret.
  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    (subview as? NSTextInsertionIndicator)?.automaticModeOptions = []
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard textStorage?.length == 0, let font else { return }

    let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
    placeholder.draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
  }
}
