import AppKit
import WebKit

/// Mouse and key input for a tab's page. The events go straight to the web view, which works in a window that is hidden or not key
/// and with focus elsewhere, and the page receives them as trusted input.
extension BrowserTab {
  /// A page point in CSS px as a point in the window, for an event.
  private func windowPoint(_ point: CGPoint) throws -> NSPoint {
    let inView = NSPoint(x: point.x * webView.pageZoom, y: point.y * webView.pageZoom)
    guard webView.bounds.contains(inView) else {
      throw ToolFailure("(\(Int(point.x)), \(Int(point.y))) is outside the page's \(Int(webView.bounds.width / webView.pageZoom)) x \(Int(webView.bounds.height / webView.pageZoom)) view; scroll it into view first.")
    }

    return webView.convert(inView, to: nil)
  }

  private func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, clicks: Int, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else {
      throw ToolFailure("The click could not be made.")
    }

    return event
  }

  /// Clicks the left button `clicks` times at a page point: 2 is a double click, 3 a triple.
  func sendClick(at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
    let location = try windowPoint(point)

    for count in 1...clicks {
      webView.mouseDown(with: try mouseEvent(.leftMouseDown, at: location, clicks: count, modifiers: modifiers))
      webView.mouseUp(with: try mouseEvent(.leftMouseUp, at: location, clicks: count, modifiers: modifiers))
    }
  }

  /// Presses at `start`, moves to `end` in steps a page's drag handlers can follow, and lets go.
  func sendDrag(from start: CGPoint, to end: CGPoint) async throws {
    let from = try windowPoint(start)
    let to = try windowPoint(end)
    let steps = 12

    webView.mouseDown(with: try mouseEvent(.leftMouseDown, at: from, clicks: 1, modifiers: []))

    for step in 1...steps {
      let progress = Double(step) / Double(steps)

      try await Task.sleep(for: .milliseconds(16))
      webView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress), clicks: 1, modifiers: []))
    }

    webView.mouseUp(with: try mouseEvent(.leftMouseUp, at: to, clicks: 1, modifiers: []))
  }

  /// Presses and releases one key at whatever the page has focused.
  func send(_ stroke: KeyStroke) throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: stroke.modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0, context: nil, characters: stroke.characters, charactersIgnoringModifiers: stroke.characters, isARepeat: false, keyCode: stroke.code) else {
        throw ToolFailure("The key press could not be made.")
      }

      if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
    }
  }

  /// The editing command a key equivalent stands for. A menu key equivalent never reaches a web view that is not first responder,
  /// so whoever sends the press sends this to the web view too.
  static func editingCommand(for stroke: KeyStroke) -> Selector? {
    guard stroke.modifiers.contains(.command) else { return nil }

    return editing[stroke.modifiers.contains(.shift) ? stroke.characters.uppercased() : stroke.characters]
  }

  private static let editing: [String: Selector] = ["a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)), "x": #selector(NSText.cut(_:)), "z": Selector(("undo:")), "Z": Selector(("redo:"))]

  /// Replaces what the focused field holds with `text` as one edit, which the page receives as trusted input.
  func replaceFocusedText(with text: String) {
    webView.selectAll(nil)

    if text.isEmpty {
      webView.deleteBackward(nil)
    } else {
      webView.insertText(text)
    }
  }
}
